// SkyBrief — autorouter NOTAM access.
//
// NOAA publishes METAR/TAF/SIGMET with no key, but there is no free NOTAM API.
// The only serious one is api.autorouter.aero (Eurocontrol EAD/INO): OAuth2
// client credentials against an account whose API access was granted by a
// support ticket. Everything in this file is plain JavaScript so the request
// building and the row handling are testable under `node --test`.
//
// Two rules drive the shape of this file:
//   1. The secret never appears on a command line. `ps` and the shell history
//      are both readable; the credentials and the bearer token travel on curl's
//      stdin through `-K -` instead.
//   2. The endpoint is rate-limited to 20 live tokens and rejects pointless
//      ones, so a token is only requested when the current one is nearly dead.

var TOKEN_URL = "https://api.autorouter.aero/v1.0/oauth2/token"
var NOTAM_URL = "https://api.autorouter.aero/v1.0/notam"

// Renew this many seconds before expiry: the API refuses a re-request while a
// token is still valid, and a token that dies mid-flight is worse than one
// renewed early.
var TOKEN_REFRESH_MARGIN_SEC = 300

// The EAD "no end of validity" sentinel, as returned in the documented
// example response (and the default of the /notam endvalidity query). The
// 32-bit unsigned value is accepted too: EAD has shipped both.
var PERMANENT_SENTINELS = [2147483647, 4294967295]

// iteme is free text and can run to a few hundred words. The panel folds it at
// three lines, and a bounded string keeps one NOTAM from dominating the cache.
var NOTAM_TEXT_LIMIT = 4000

function curlQuote(value) {
  return '"' + String(value === null || value === undefined ? "" : value)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/[\r\n]/g, " ") + '"'
}

// curl configuration for the OAuth2 token request. The caller pipes this to
// `curl -K -` on stdin, so neither the client id nor the secret reaches argv.
function tokenRequestConfig(user, password) {
  var lines = [
    'url = ' + curlQuote(TOKEN_URL),
    'request = "POST"',
    'data-urlencode = ' + curlQuote("grant_type=client_credentials"),
    'data-urlencode = ' + curlQuote("client_id=" + String(user === null || user === undefined ? "" : user)),
    'data-urlencode = ' + curlQuote("client_secret=" + String(password === null || password === undefined ? "" : password))
  ]
  return lines.join("\n") + "\n"
}

function parseTokenResponse(raw) {
  var text = String(raw === null || raw === undefined ? "" : raw).trim()
  if (!text) return { token: null, expiresInSec: null, error: "empty response" }

  var json = null
  try {
    json = JSON.parse(text)
  } catch (e) {
    return { token: null, expiresInSec: null, error: "malformed response" }
  }
  if (!json || typeof json !== "object") return { token: null, expiresInSec: null, error: "malformed response" }

  // The observed failure shape is {"error":"invalid_client",
  // "error_description":"The client credentials are invalid"}. Both keys are
  // carried into `error` so the panel can show what the server actually said.
  if (json.error) {
    var message = String(json.error)
    if (json.error_description) message += ": " + String(json.error_description)
    return { token: null, expiresInSec: null, error: message }
  }

  var token = json.access_token === null || json.access_token === undefined ? null : String(json.access_token)
  if (!token) return { token: null, expiresInSec: null, error: "no access_token in response" }

  var expires = Number(json.expires_in)
  return {
    token: token,
    expiresInSec: isFinite(expires) && expires > 0 ? expires : null,
    error: null
  }
}

// A token is only usable while it has more than the refresh margin left; below
// that the next request would race its expiry.
function tokenIsUsable(state, nowMs) {
  if (!state || typeof state !== "object") return false
  var token = state.token ? String(state.token) : ""
  if (!token) return false

  var expiresAt = Number(state.expiresAtMs)
  if (!isFinite(expiresAt)) return false

  var now = Number(nowMs)
  if (!isFinite(now)) return false

  return (expiresAt - now) / 1000 > TOKEN_REFRESH_MARGIN_SEC
}

// curl configuration for a NOTAM query. `itemas` must be a JSON array of
// two-letter + two-alphanumeric item A identifiers; the server enforces that
// shape and rejects a bare code with
//   The string should match pattern: ^\[\s*(?:"[A-Z]{2}[A-Z0-9]{2}"...)\]$
// so it is serialised as JSON, then percent-encoded for the query string.
// Aerodrome ICAO codes and FIR identifiers are both item A values.
function notamRequestConfig(token, icaos, limit) {
  var codes = []
  if (Array.isArray(icaos)) {
    for (var i = 0; i < icaos.length; i++) {
      var code = icaos[i] === null || icaos[i] === undefined ? "" : String(icaos[i]).trim().toUpperCase()
      if (code && codes.indexOf(code) === -1) codes.push(code)
    }
  }

  var count = Number(limit)
  if (!isFinite(count) || count < 1) count = 40
  // The server clamps to 100; asking for more would be silently truncated.
  count = Math.min(100, Math.round(count))

  var itemas = encodeURIComponent(JSON.stringify(codes))
  var url = NOTAM_URL + "?itemas=" + itemas + "&limit=" + count

  return 'url = ' + curlQuote(url) + "\n" +
    'header = ' + curlQuote("Authorization: Bearer " + String(token === null || token === undefined ? "" : token)) + "\n"
}

// Tolerant by design: an auth failure returns an error object rather than
// {total, rows}, and that must be reported rather than silently rendering as
// "no NOTAMs in force". `error` is null when the body parsed as a result set.
function parseNotamResponse(raw) {
  var text = String(raw === null || raw === undefined ? "" : raw).trim()
  if (!text) return { total: 0, rows: [], error: "empty response" }

  var json = null
  try {
    json = JSON.parse(text)
  } catch (e) {
    return { total: 0, rows: [], error: "malformed response" }
  }
  if (!json || typeof json !== "object") return { total: 0, rows: [], error: "malformed response" }

  // The observed failure shape is {"error": "...", "code": "...", ...}.
  if (json.error !== undefined && json.error !== null && json.error !== "") {
    var message = String(json.error)
    if (json.code) message += " (" + String(json.code) + ")"
    return { total: 0, rows: [], error: message }
  }

  if (!Array.isArray(json.rows)) return { total: 0, rows: [], error: "unexpected response shape" }

  var total = Number(json.total)
  return {
    total: isFinite(total) ? total : json.rows.length,
    rows: json.rows,
    error: null
  }
}

function padNumber(value, width) {
  var text = String(value === null || value === undefined ? "" : value).replace(/[^0-9]/g, "")
  while (text.length < width) text = "0" + text
  return text
}

function formatValidity(value, timeFormat) {
  var ms = Number(value)
  if (!isFinite(ms) || ms <= 0) return "—"
  var date = new Date(ms < 1e12 ? ms * 1000 : ms)
  if (!isFinite(date.getTime())) return "—"

  var day = padNumber(date.getUTCDate(), 2)
  var month = padNumber(date.getUTCMonth() + 1, 2)
  var hour = padNumber(date.getUTCHours(), 2)
  var minute = padNumber(date.getUTCMinutes(), 2)

  if (String(timeFormat) === "local") {
    var offset = -date.getTimezoneOffset()
    var local = new Date(date.getTime() + offset * 60000)
    return padNumber(local.getUTCDate(), 2) + "/" + padNumber(local.getUTCMonth() + 1, 2) + " " +
      padNumber(local.getUTCHours(), 2) + ":" + padNumber(local.getUTCMinutes(), 2)
  }

  return day + "/" + month + " " + hour + ":" + minute + "Z"
}

// Normalise one row of the documented response shape into what the panel draws:
// the NOTAM id (rebuilt as series+number/year, e.g. P0825/17), its validity,
// the item A codes it applies to, and its text.
function formatNotamRow(row, timeFormat) {
  if (!row || typeof row !== "object") return null

  var series = row.series === null || row.series === undefined ? "" : String(row.series).trim().toUpperCase()
  var number = padNumber(row.number, 4)
  var year = padNumber(row.year, 2)
  var id = series ? series + number + "/" + year
    : (row.number === null || row.number === undefined ? "" : String(row.number))

  var endRaw = row.endvalidity === null || row.endvalidity === undefined ? null : Number(row.endvalidity)
  var permanent = endRaw === null || !isFinite(endRaw) || PERMANENT_SENTINELS.indexOf(endRaw) !== -1

  var itema = []
  if (Array.isArray(row.itema)) {
    for (var i = 0; i < row.itema.length; i++) {
      var code = row.itema[i] === null || row.itema[i] === undefined ? "" : String(row.itema[i]).trim().toUpperCase()
      if (code && itema.indexOf(code) === -1) itema.push(code)
    }
  }

  var text = row.iteme === null || row.iteme === undefined ? "" : String(row.iteme)
  text = text.replace(/\s+/g, " ").trim()
  if (text.length > NOTAM_TEXT_LIMIT) text = text.slice(0, NOTAM_TEXT_LIMIT) + "…"

  var type = row.type === null || row.type === undefined ? "" : String(row.type).trim().toUpperCase()
  var fir = row.fir === null || row.fir === undefined ? "" : String(row.fir).trim().toUpperCase()

  return {
    id: id,
    validFrom: formatValidity(row.startvalidity, timeFormat),
    validTo: permanent ? "permanent" : formatValidity(endRaw, timeFormat),
    validFromMs: isFinite(Number(row.startvalidity)) ? Number(row.startvalidity) * 1000 : null,
    validToMs: permanent ? null : (isFinite(endRaw) ? endRaw * 1000 : null),
    text: text,
    icao: itema.join(" "),
    itema: itema,
    fir: fir,
    type: type,
    purpose: row.purpose === null || row.purpose === undefined ? "" : String(row.purpose),
    scope: row.scope === null || row.scope === undefined ? "" : String(row.scope),
    lower: row.lower === null || row.lower === undefined ? "" : String(row.lower),
    upper: row.upper === null || row.upper === undefined ? "" : String(row.upper),
    permanent: permanent
  }
}

function notamGroup(entry, nowMs) {
  if (entry.permanent || entry.validToMs === null) return 1
  if (entry.validFromMs !== null && entry.validFromMs > nowMs) return 2
  return 0
}

// Currently-in-force NOTAMs first, then the permanent ones, then those still to
// come; within a group the soonest to expire comes first, so the most urgent
// line is always the top one.
function sortNotamRows(rows, nowMs) {
  var list = Array.isArray(rows) ? rows.slice() : []
  var now = Number(nowMs)
  if (!isFinite(now)) now = Date.now()

  list.sort(function (a, b) {
    var groupA = notamGroup(a, now)
    var groupB = notamGroup(b, now)
    if (groupA !== groupB) return groupA - groupB

    var endA = a.permanent ? Number.MAX_SAFE_INTEGER : (a.validToMs === null ? Number.MAX_SAFE_INTEGER : a.validToMs)
    var endB = b.permanent ? Number.MAX_SAFE_INTEGER : (b.validToMs === null ? Number.MAX_SAFE_INTEGER : b.validToMs)
    if (endA !== endB) return endA - endB

    return String(a.id).localeCompare(String(b.id))
  })
  return list
}

// Split the answer into the aerodrome's NOTAMs and the FIR's. A NOTAM that
// names both item A values is filed under the aerodrome only — seeing the same
// line twice is noise, not information.
function filterNotamRows(rows, options) {
  var out = { forStation: [], forFir: [] }
  var icao = options && options.icao ? String(options.icao).trim().toUpperCase() : ""
  var fir = options && options.fir ? String(options.fir).trim().toUpperCase() : ""

  if (!Array.isArray(rows)) return out

  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row) continue
    var itema = Array.isArray(row.itema) ? row.itema : []
    var matchesStation = icao !== "" && itema.indexOf(icao) !== -1
    var matchesFir = fir !== "" && (itema.indexOf(fir) !== -1 || String(row.fir || "").toUpperCase() === fir)

    if (matchesStation) out.forStation.push(row)
    else if (matchesFir) out.forFir.push(row)
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    TOKEN_URL: TOKEN_URL,
    NOTAM_URL: NOTAM_URL,
    TOKEN_REFRESH_MARGIN_SEC: TOKEN_REFRESH_MARGIN_SEC,
    PERMANENT_SENTINELS: PERMANENT_SENTINELS,
    tokenRequestConfig: tokenRequestConfig,
    parseTokenResponse: parseTokenResponse,
    tokenIsUsable: tokenIsUsable,
    notamRequestConfig: notamRequestConfig,
    parseNotamResponse: parseNotamResponse,
    formatNotamRow: formatNotamRow,
    sortNotamRows: sortNotamRows,
    filterNotamRows: filterNotamRows
  }
}

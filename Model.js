// SkyBrief — METAR/TAF parsing, flight-category classification and plain-language
// decoding. Pure JavaScript on purpose: no QML types in here, so the whole file
// runs under `node --test` and the rules below are testable without a shell.
//
// The single most important rule in this file: never trust the API's `visib`
// field. It is lossy — aviationweather.gov reports `"0.4"` for a 650 m METAR
// and `"6+"` for every ICAO `9999` — so flight category is derived from the
// raw report text through parseVisibilityMeters(). Getting that wrong flips
// LIFR to MVFR and back.

var METERS_PER_SM = 1609.344
var UNLIMITED_METERS = 10000
var UNLIMITED_SM = 6

// Severity order: the index is the rank, lower is more restrictive.
var CATEGORY_ORDER = { LIFR: 0, IFR: 1, MVFR: 2, VFR: 3 }

// Covers that form a ceiling. FEW and SCT are layers, not ceilings.
var CEILING_COVERS = { BKN: true, OVC: true, VV: true }

var WIND_RE = /^(\d{3}|VRB)(\d{2,3})(?:G(\d{2,3}))?(KT|MPS|KMH)$/
var VARIABLE_WIND_RE = /^(\d{3})V(\d{3})$/
var DIRECTIONAL_VIS_RE = /^(\d{4})(N|NE|E|SE|S|SW|W|NW)$/
var CLOUD_RE = /^(FEW|SCT|BKN|OVC|VV)(\d{3})(CB|TCU)?$/
var VALIDITY_RE = /^(\d{2})(\d{2})\/(\d{2})(\d{2})$/
var FM_RE = /^FM(\d{2})(\d{2})(\d{2})$/
var PROB_RE = /^PROB(\d{2})$/
var TIMESTAMP_RE = /^\d{6}Z$/

// Weather groups: optional intensity, optional vicinity/recent marker, zero or
// more descriptors, then zero or more phenomena. Anchored so cloud groups, wind,
// QNH and timestamps can never match. VCSH (vicinity + a descriptor, no
// phenomenon) and a lone TS are both valid METAR, hence the optional tails —
// isWeatherToken() rejects the empty match explicitly.
var DESCRIPTOR_PATTERN = "(?:MI|PR|BC|DR|BL|SH|TS|FZ)"
var PHENOMENON_PATTERN = "(?:DZ|RA|SN|SG|IC|PL|GR|GS|UP|BR|FG|FU|VA|DU|SA|HZ|PY|PO|SQ|FC|SS|DS)"
var WEATHER_RE = new RegExp("^([+-])?(RE)?(" + DESCRIPTOR_PATTERN + "*)((?:" + PHENOMENON_PATTERN + ")+)?$")
var WEATHER_RE_VC = new RegExp("^([+-])?(VC)(" + DESCRIPTOR_PATTERN + "*)((?:" + PHENOMENON_PATTERN + ")+)?$")

var INTENSITY_WORDS = { "-": "light", "+": "heavy" }
var DESCRIPTOR_WORDS = {
  MI: "shallow", PR: "partial", BC: "patches of", DR: "low drifting",
  BL: "blowing", SH: "showers of", TS: "thunderstorm with", FZ: "freezing"
}
var PHENOMENON_WORDS = {
  DZ: "drizzle", RA: "rain", SN: "snow", SG: "snow grains",
  IC: "ice crystals", PL: "ice pellets", GR: "hail", GS: "small hail",
  UP: "unknown precipitation", BR: "mist", FG: "fog", FU: "smoke",
  VA: "volcanic ash", DU: "widespread dust", SA: "sand", HZ: "haze",
  PY: "spray", PO: "dust whirls", SQ: "squalls", FC: "funnel cloud",
  SS: "sandstorm", DS: "duststorm"
}
var COVER_WORDS = {
  FEW: "few clouds", SCT: "scattered clouds", BKN: "broken cloud",
  OVC: "overcast", VV: "vertical visibility", NSC: "no significant cloud",
  SKC: "sky clear", CLR: "sky clear", NCD: "no cloud detected"
}

function pad2(value) {
  var n = Math.abs(Math.round(Number(value) || 0))
  return (n < 10 ? "0" : "") + n
}

function pad3(value) {
  var n = Math.abs(Math.round(Number(value) || 0))
  if (n < 10) return "00" + n
  if (n < 100) return "0" + n
  return String(n)
}

function numberOrNull(value) {
  if (value === null || value === undefined || value === "") return null
  var n = Number(value)
  return isFinite(n) ? n : null
}

// API timestamps are epoch seconds; the model keeps epoch milliseconds.
function toMillis(value) {
  var n = numberOrNull(value)
  if (n === null) return null
  return n < 1e12 ? n * 1000 : n
}

// ---------------------------------------------------------------------------
// Stations

// The personal list is capped: the popup is a glance, and a list long enough to
// need scrolling stops being one. Every code also rides the one METAR request,
// so the cap keeps that request bounded too.
var MAX_QUICK_STATIONS = 10

// Comma / space / newline separated ICAO codes, upper-cased, malformed
// entries dropped. A 2-letter fragment like "EB" is a mistake, not a station.
// `limit` truncates the result; it defaults to the personal-list cap.
function parseStationList(raw, limit) {
  var text = String(raw === null || raw === undefined ? "" : raw)
  var tokens = text.split(/[\s,]+/)
  var max = numberOrNull(limit)
  if (max === null || max <= 0) max = MAX_QUICK_STATIONS

  var out = []
  for (var i = 0; i < tokens.length; i++) {
    var code = tokens[i].trim().toUpperCase()
    if (!/^[A-Z0-9]{4}$/.test(code)) continue
    if (out.indexOf(code) !== -1) continue
    out.push(code)
    if (out.length >= max) break
  }
  return out
}

// Append a code to the personal list. Returns the new list plus why it was
// refused, so the caller can say which of the two cases it hit rather than
// silently doing nothing — a full list and an already-listed code need
// different sentences.
function addQuickStation(raw, code, limit) {
  var icao = String(code === null || code === undefined ? "" : code).trim().toUpperCase()
  var stations = parseStationList(raw, limit)
  if (!/^[A-Z0-9]{4}$/.test(icao)) return { stations: stations, added: false, reason: "invalid" }
  if (stations.indexOf(icao) !== -1) return { stations: stations, added: false, reason: "duplicate" }
  if (stations.length >= MAX_QUICK_STATIONS) return { stations: stations, added: false, reason: "full" }
  stations.push(icao)
  return { stations: stations, added: true, reason: "" }
}

// Drop a code. The list comes back in the same order, one shorter.
function removeQuickStation(raw, code) {
  var icao = String(code === null || code === undefined ? "" : code).trim().toUpperCase()
  var list = parseStationList(raw)
  var out = []
  for (var i = 0; i < list.length; i++) if (list[i] !== icao) out.push(list[i])
  return out
}

// ---------------------------------------------------------------------------
// Visibility

// Match one visibility group. Returns {meters, raw} or null.
function matchVisibilityToken(token) {
  if (token === "CAVOK") return { meters: UNLIMITED_METERS, raw: "CAVOK" }

  var m = /^(\d{4})$/.exec(token)
  if (m) {
    var meters = Number(m[1])
    return { meters: meters === 9999 ? UNLIMITED_METERS : meters, raw: token }
  }

  // Directional minimum visibility ("1200SW"): handled by the scanner, which
  // knows it is a fallback rather than the prevailing visibility.
  m = /^([MP])?(\d+)\/(\d+)SM$/.exec(token)
  if (m) {
    var milesFraction = Number(m[2]) / Number(m[3])
    return { meters: m[1] === "P" ? UNLIMITED_METERS : milesFraction * METERS_PER_SM, raw: token }
  }

  m = /^([MP])?(\d+)SM$/.exec(token)
  if (m) {
    return {
      meters: m[1] === "P" ? UNLIMITED_METERS : Number(m[2]) * METERS_PER_SM,
      raw: token
    }
  }

  return null
}

// Extract the prevailing visibility from a raw report. Scanning starts after
// the wind group (or after the timestamp when there is no wind group) so an
// earlier 4-digit token can never be mistaken for visibility.
function parseVisibilityMeters(rawOb) {
  var out = { meters: null, raw: "" }
  var text = String(rawOb === null || rawOb === undefined ? "" : rawOb).trim().toUpperCase()
  if (!text) return out

  var tokens = text.split(/\s+/)
  var windIndex = -1
  var timeIndex = -1
  for (var i = 0; i < tokens.length; i++) {
    if (windIndex < 0 && WIND_RE.test(tokens[i])) windIndex = i
    if (timeIndex < 0 && TIMESTAMP_RE.test(tokens[i])) timeIndex = i
  }

  var start = 1
  if (windIndex >= 0) start = windIndex + 1
  else if (timeIndex >= 0) start = timeIndex + 1

  // A directional group is the sector minimum, never the prevailing
  // visibility, so it is only a fallback for the "1200SW" standalone form.
  var directional = null

  for (var j = start; j < tokens.length; j++) {
    var token = tokens[j]
    // Variable wind direction sits between the wind group and visibility.
    if (VARIABLE_WIND_RE.test(token)) continue
    if (DIRECTIONAL_VIS_RE.test(token)) {
      if (directional === null) directional = { meters: Number(token.substr(0, 4)), raw: token }
      continue
    }
    var match = matchVisibilityToken(token)
    if (match) return match
    // "1 1/2SM" arrives as two tokens; recombine before giving up on this one.
    if (/^\d+$/.test(token) && j + 1 < tokens.length) {
      var combined = /^([MP])?(\d+)\/(\d+)SM$/.exec(tokens[j + 1])
      if (combined) {
        var whole = Number(token) + Number(combined[2]) / Number(combined[3])
        return { meters: whole * METERS_PER_SM, raw: token + " " + tokens[j + 1] }
      }
    }
  }
  return directional || out
}

// ---------------------------------------------------------------------------
// Wind, clouds, weather tokens

function parseWindFromRaw(rawOb) {
  var wind = { dir: null, speedKt: null, gustKt: null, variable: null, variableDir: false }
  var tokens = String(rawOb === null || rawOb === undefined ? "" : rawOb).trim().toUpperCase().split(/\s+/)
  for (var i = 0; i < tokens.length; i++) {
    var token = tokens[i]
    var m = WIND_RE.exec(token)
    if (m) {
      wind.dir = m[1] === "VRB" ? null : Number(m[1])
      wind.variableDir = m[1] === "VRB"
      wind.speedKt = Number(m[2])
      wind.gustKt = m[3] ? Number(m[3]) : null
      // Direction may be given as a variable sector after the wind group.
      for (var k = i + 1; k < tokens.length; k++) {
        var v = VARIABLE_WIND_RE.exec(tokens[k])
        if (v) { wind.variable = [Number(v[1]), Number(v[2])]; break }
        if (!VARIABLE_WIND_RE.test(tokens[k])) break
      }
      return wind
    }
  }
  return wind
}

// Cloud cover codes the decoder knows. A value outside this set never reaches
// the display layer: the API response is remote input, and an unknown or
// markup-shaped `cover` has no meaning to show.
var KNOWN_COVER_CODES = {
  FEW: true, SCT: true, BKN: true, OVC: true, VV: true,
  NSC: true, SKC: true, CLR: true, NCD: true,
  // Codes the API is documented to emit for an automatic or missing report.
  NIL: true, CAVOK: true, NOSIG: true
}

function isKnownCoverCode(cover) {
  var key = String(cover === null || cover === undefined ? "" : cover).trim().toUpperCase()
  return KNOWN_COVER_CODES[key] === true
}

function parseCloudsFromJson(clouds) {
  var out = []
  if (!Array.isArray(clouds)) return out
  for (var i = 0; i < clouds.length; i++) {
    var c = clouds[i]
    if (!c || typeof c !== "object") continue
    var cover = String(c.cover === null || c.cover === undefined ? "" : c.cover).trim().toUpperCase()
    // An unrecognised cover is dropped rather than passed through: it would
    // otherwise be spelled out verbatim in the decoded reading, which is the
    // path that once carried endpoint-controlled text into the UI.
    if (!isKnownCoverCode(cover)) continue
    var base = numberOrNull(c.base)
    if (base === null) base = numberOrNull(c.baseFt)
    out.push({ cover: cover, baseFt: base })
  }
  return out
}

function parseCloudsFromText(tokens) {
  var out = []
  for (var i = 0; i < tokens.length; i++) {
    var m = CLOUD_RE.exec(tokens[i])
    if (m) {
      out.push({ cover: m[1], baseFt: Number(m[2]) * 100 })
      continue
    }
    if (tokens[i] === "NSC" || tokens[i] === "SKC" || tokens[i] === "CLR" || tokens[i] === "NCD")
      out.push({ cover: tokens[i], baseFt: null })
  }
  return out
}

// Lowest BKN/OVC/VV layer, falling back to vertical visibility. FEW and SCT
// layers do not constitute a ceiling.
function ceilingFromClouds(clouds, vertVis) {
  var lowest = null
  if (Array.isArray(clouds)) {
    for (var i = 0; i < clouds.length; i++) {
      var c = clouds[i]
      if (!c) continue
      var cover = String(c.cover === null || c.cover === undefined ? "" : c.cover).toUpperCase()
      if (!CEILING_COVERS[cover]) continue
      var base = numberOrNull(c.baseFt)
      if (base === null) base = numberOrNull(c.base)
      if (base === null) continue
      if (lowest === null || base < lowest) lowest = base
    }
  }
  var vv = numberOrNull(vertVis)
  if (vv !== null && (lowest === null || vv < lowest)) lowest = vv
  return lowest
}

function isWeatherToken(token) {
  if (token === "NSW") return true
  var m = WEATHER_RE_VC.exec(token) || WEATHER_RE.exec(token)
  if (!m) return false
  // Both tails are optional so VCSH and a lone TS match; a match that consumed
  // nothing but an intensity or RE marker ("+", "RE") is not a weather group.
  return (m[2] !== undefined && m[2] !== null) || (m[3] && m[3].length > 0) || (m[4] && m[4].length > 0)
}

function weatherTokens(rawOb) {
  var tokens = String(rawOb === null || rawOb === undefined ? "" : rawOb).trim().toUpperCase().split(/\s+/)
  var out = []
  for (var i = 0; i < tokens.length; i++) {
    if (tokens[i] && isWeatherToken(tokens[i])) out.push(tokens[i])
  }
  return out
}

// ---------------------------------------------------------------------------
// Flight category

function ceilingCategory(ceilingFt) {
  if (ceilingFt === null || ceilingFt === undefined) return null
  if (ceilingFt < 500) return "LIFR"
  if (ceilingFt < 1000) return "IFR"
  if (ceilingFt <= 3000) return "MVFR"
  return "VFR"
}

function visibilityCategory(meters) {
  if (meters === null || meters === undefined) return null
  if (meters < 1 * METERS_PER_SM) return "LIFR"
  if (meters < 3 * METERS_PER_SM) return "IFR"
  if (meters <= 5 * METERS_PER_SM) return "MVFR"
  return "VFR"
}

// Rank of a category; -1 when unknown. Service.qml compares this against the
// alert threshold.
function categorySeverity(category) {
  var key = String(category === null || category === undefined ? "" : category).toUpperCase()
  return CATEGORY_ORDER[key] === undefined ? -1 : CATEGORY_ORDER[key]
}

// The API supplies fltCat for most stations; when it is absent (or not one of
// the four categories) the ceiling and the visibility from the raw text decide,
// and the more restrictive of the two wins.
function classifyFlightCategory(metar) {
  if (!metar) return ""
  var provided = String(metar.fltCat === null || metar.fltCat === undefined ? "" : metar.fltCat).toUpperCase()
  if (CATEGORY_ORDER[provided] !== undefined) return provided

  var ceiling = numberOrNull(metar.ceilingFt)
  if (ceiling === null) ceiling = ceilingFromClouds(metar.clouds, metar.vertVis)

  var meters = null
  if (metar.visibility && numberOrNull(metar.visibility.meters) !== null)
    meters = numberOrNull(metar.visibility.meters)
  else if (numberOrNull(metar.visibMeters) !== null)
    meters = numberOrNull(metar.visibMeters)

  var byCeiling = ceilingCategory(ceiling)
  var byVisibility = visibilityCategory(meters)

  if (byCeiling === null && byVisibility === null) return ""
  if (byCeiling === null) return byVisibility
  if (byVisibility === null) return byCeiling
  return CATEGORY_ORDER[byCeiling] <= CATEGORY_ORDER[byVisibility] ? byCeiling : byVisibility
}

function categoryColorRole(category) {
  var key = String(category === null || category === undefined ? "" : category).toUpperCase()
  if (CATEGORY_ORDER[key] === undefined) return "none"
  return key.toLowerCase()
}

// ---------------------------------------------------------------------------
// METAR

function parseMetar(json) {
  if (!json || typeof json !== "object") return null
  var raw = String(json.rawOb === null || json.rawOb === undefined ? "" : json.rawOb).trim()
  var icaoId = String(json.icaoId === null || json.icaoId === undefined ? "" : json.icaoId).toUpperCase()
  if (!raw && !icaoId) return null

  var clouds = parseCloudsFromJson(json.clouds)
  var vertVis = numberOrNull(json.vertVis)
  var visibility = parseVisibilityMeters(raw)

  var parsed = {
    icaoId: icaoId,
    name: String(json.name === null || json.name === undefined ? "" : json.name),
    obsTime: toMillis(json.obsTime),
    reportTime: String(json.reportTime === null || json.reportTime === undefined ? "" : json.reportTime),
    raw: raw,
    tempC: numberOrNull(json.temp),
    dewpC: numberOrNull(json.dewp),
    wind: parseWindFromRaw(raw),
    visibility: visibility,
    ceilingFt: ceilingFromClouds(clouds, vertVis),
    clouds: clouds,
    qnhHpa: numberOrNull(json.altim),
    weather: weatherTokens(raw),
    category: "",
    stale: false
  }
  parsed.category = classifyFlightCategory(parsed)
  return parsed
}

// An observation older than maxAgeMinutes stops being presented as current.
function markStale(parsed, maxAgeMinutes, nowMs) {
  if (!parsed || typeof parsed !== "object") return parsed
  var maxAge = numberOrNull(maxAgeMinutes)
  var now = numberOrNull(nowMs)
  if (parsed.obsTime === null || maxAge === null || now === null) {
    parsed.stale = false
    return parsed
  }
  parsed.stale = (now - parsed.obsTime) > maxAge * 60000
  return parsed
}

function formatObsTime(ms, timeFormat) {
  var value = numberOrNull(ms)
  if (value === null) return "—"
  var d = new Date(value)
  if (String(timeFormat) === "local") {
    var offset = -d.getTimezoneOffset()
    var sign = offset < 0 ? "-" : "+"
    var absMinutes = Math.abs(offset)
    var suffix = "UTC" + sign + Math.floor(absMinutes / 60)
    if (absMinutes % 60 !== 0) suffix += ":" + pad2(absMinutes % 60)
    return pad2(d.getHours()) + ":" + pad2(d.getMinutes()) + " (" + suffix + ")"
  }
  return pad2(d.getUTCHours()) + ":" + pad2(d.getUTCMinutes()) + "Z"
}

// ---------------------------------------------------------------------------
// Formatting. Wind stays in knots and cloud base in feet whatever `units`
// says: those are aviation units, not a display preference. `units` only
// moves temperature, visibility and altimeter.

function formatWind(parsed, units) {
  var wind = parsed && parsed.wind ? parsed.wind : {}
  var speed = numberOrNull(wind.speedKt)
  if (speed === null) return "—"
  if (speed === 0) return "calm"

  var direction = "—"
  if (numberOrNull(wind.dir) !== null) direction = pad3(wind.dir) + "°"
  else if (wind.variableDir) direction = "VRB"

  var text = direction + " " + Math.round(speed) + " kt"
  var gust = numberOrNull(wind.gustKt)
  if (gust !== null) text += " gusting " + Math.round(gust)
  return text
}

function formatVisibility(visibility, units) {
  if (!visibility) return "—"
  var meters = numberOrNull(visibility.meters)
  if (meters === null) return visibility.raw ? String(visibility.raw) : "—"

  if (String(units) === "imperial") {
    var sm = meters / METERS_PER_SM
    if (sm >= UNLIMITED_SM) return UNLIMITED_SM + "+ sm"
    return (sm < 1 ? sm.toFixed(2) : sm.toFixed(1)) + " sm"
  }

  if (meters >= UNLIMITED_METERS) return "10 km or more"
  if (meters >= 1000) return (meters / 1000).toFixed(1) + " km"
  return Math.round(meters) + " m"
}

function formatAltimeter(hpa, units) {
  var value = numberOrNull(hpa)
  if (value === null) return "—"
  if (String(units) === "imperial") return (value * 0.0295299830714).toFixed(2) + " inHg"
  return Math.round(value) + " hPa"
}

function formatTemp(celsius, units) {
  var value = numberOrNull(celsius)
  if (value === null) return "—"
  if (String(units) === "imperial") return Math.round(value * 9 / 5 + 32) + " °F"
  return Math.round(value) + " °C"
}

// ---------------------------------------------------------------------------
// Decoding

function decodeWeatherToken(token) {
  var text = String(token === null || token === undefined ? "" : token).toUpperCase()
  if (!text) return ""
  if (text === "NSW") return "no significant weather"

  // Group 2 is VC or RE, group 3 the descriptors, group 4 the phenomena; both
  // tails can legitimately be empty (VCSH, a lone TS).
  var m = WEATHER_RE_VC.exec(text) || WEATHER_RE.exec(text)
  if (!m || (!m[3] && !m[4])) return text

  var words = []
  if (INTENSITY_WORDS[m[1]]) words.push(INTENSITY_WORDS[m[1]])
  if (m[2] === "VC") words.push("in the vicinity")
  else if (m[2] === "RE") words.push("recent")

  var descriptors = m[3] || ""
  for (var i = 0; i < descriptors.length; i += 2) {
    var d = DESCRIPTOR_WORDS[descriptors.substr(i, 2)]
    if (d) words.push(d)
  }

  var phenomena = []
  var codes = m[4] || ""
  for (var j = 0; j < codes.length; j += 2) {
    var p = PHENOMENON_WORDS[codes.substr(j, 2)]
    if (p) phenomena.push(p)
  }
  if (phenomena.length) words.push(phenomena.join(" and "))

  return words.length ? words.join(" ") : text
}

// The word for a cover code, or an empty string when the code is not one we
// know. Returning the input verbatim — as this once did — passed remote text
// straight through to the display.
function decodeCover(cover) {
  var key = String(cover === null || cover === undefined ? "" : cover).trim().toUpperCase()
  if (!isKnownCoverCode(key)) return ""
  return COVER_WORDS[key] || key
}

function decodeClouds(clouds) {
  if (!Array.isArray(clouds) || !clouds.length) return ""
  var parts = []
  for (var i = 0; i < clouds.length; i++) {
    var c = clouds[i]
    if (!c) continue
    var word = decodeCover(c.cover)
    if (word === "") continue
    var base = numberOrNull(c.baseFt)
    if (base === null) parts.push(word)
    else parts.push(word + " at " + Math.round(base) + " ft")
  }
  return parts.join(", ")
}

// Plain-language METAR. `units` defaults to metric; the panel passes the
// user's setting through.
function decodeMetar(parsed, units) {
  if (!parsed) return ""
  var useUnits = units === undefined || units === null ? "metric" : units
  var sentences = []

  var wind = parsed.wind || {}
  var speed = numberOrNull(wind.speedKt)
  if (speed === null) sentences.push("wind not reported")
  else if (speed === 0) sentences.push("calm")
  else {
    var direction = numberOrNull(wind.dir) !== null
      ? pad3(wind.dir) + "°"
      : (wind.variableDir ? "variable" : "unknown direction")
    var windText = "wind " + direction + " at " + Math.round(speed) + " kt"
    var gust = numberOrNull(wind.gustKt)
    if (gust !== null) windText += ", gusting " + Math.round(gust)
    if (Array.isArray(wind.variable) && wind.variable.length === 2)
      windText += ", varying between " + pad3(wind.variable[0]) + "° and " + pad3(wind.variable[1]) + "°"
    sentences.push(windText)
  }

  if (parsed.visibility && numberOrNull(parsed.visibility.meters) !== null) {
    var v = formatVisibility(parsed.visibility, useUnits)
    sentences.push("visibility " + (parsed.visibility.raw === "CAVOK" ? "CAVOK, " + v : v))
  }

  var weather = Array.isArray(parsed.weather) ? parsed.weather : []
  if (weather.length) {
    var phrases = []
    for (var i = 0; i < weather.length; i++) phrases.push(decodeWeatherToken(weather[i]))
    sentences.push(phrases.join(", "))
  }

  var cloudText = decodeClouds(parsed.clouds)
  if (cloudText) sentences.push(cloudText)

  var temp = numberOrNull(parsed.tempC)
  var dewp = numberOrNull(parsed.dewpC)
  if (temp !== null || dewp !== null)
    sentences.push("temperature " + formatTemp(temp, useUnits) + ", dew point " + formatTemp(dewp, useUnits))

  if (numberOrNull(parsed.qnhHpa) !== null)
    sentences.push("QNH " + formatAltimeter(parsed.qnhHpa, useUnits))

  var raw = String(parsed.raw || "")
  if (/\bNOSIG\b/.test(raw)) sentences.push("no significant change expected")
  else if (/\bBECMG\b/.test(raw)) sentences.push("conditions becoming")
  else if (/\bTEMPO\b/.test(raw)) sentences.push("temporary fluctuations")

  if (!sentences.length) return ""
  var text = sentences.join(", ")
  return text.charAt(0).toUpperCase() + text.slice(1) + "."
}

// ---------------------------------------------------------------------------
// TAF

// Turn a day-of-month + hour (TAF groups carry no month) into epoch ms,
// anchored on the reference time and rolling into the next month when the
// group's day has already passed.
function resolveDayHour(day, hour, minute, referenceMs) {
  var reference = numberOrNull(referenceMs)
  if (reference === null) return null
  var ref = new Date(reference)
  var candidate = Date.UTC(ref.getUTCFullYear(), ref.getUTCMonth(), day, hour, minute, 0, 0)
  for (var attempt = 0; attempt < 3 && candidate < reference - 12 * 3600000; attempt++) {
    var shifted = new Date(candidate)
    candidate = Date.UTC(shifted.getUTCFullYear(), shifted.getUTCMonth() + 1, day, hour, minute, 0, 0)
  }
  return candidate
}

// The conditions a group's own tokens state, and which elements it states at
// all. A change group carries only the elements that change, so "which elements
// are here" is as much a part of the group as their values — see
// resolveTafConditions for what the omissions mean.
function conditionsFromTokens(tokens) {
  var wind = { wdir: null, wspd: null, wgst: null }
  var visibility = { meters: null, raw: "" }
  var weather = []
  var stated = { wind: false, visibility: false, clouds: false, weather: false }

  for (var i = 0; i < tokens.length; i++) {
    var token = tokens[i]
    if (token === "CAVOK") {
      // CAVOK is one statement about three elements at once: 10 km or more of
      // visibility, no cloud below 5000 ft, no significant weather.
      visibility = { meters: UNLIMITED_METERS, raw: "CAVOK" }
      stated.visibility = true
      stated.clouds = true
      stated.weather = true
      continue
    }
    var m = WIND_RE.exec(token)
    if (m) {
      wind.wdir = m[1] === "VRB" ? "VRB" : Number(m[1])
      wind.wspd = Number(m[2])
      wind.wgst = m[3] ? Number(m[3]) : null
      stated.wind = true
      continue
    }
    if (visibility.meters === null) {
      var v = matchVisibilityToken(token)
      if (v) { visibility = v; stated.visibility = true; continue }
    }
    if (isWeatherToken(token)) {
      // NSW is a stated value — "nothing significant" — not an omission, so it
      // clears the weather carried over instead of leaving it standing.
      stated.weather = true
      if (token !== "NSW") weather.push(token)
    }
  }

  // NSC/SKC/CLR/NCD come back as layers and state the sky as firmly as a BKN
  // layer does.
  var clouds = parseCloudsFromText(tokens)
  if (clouds.length) stated.clouds = true

  return {
    wind: wind,
    visibility: visibility,
    clouds: clouds,
    weather: weather,
    stated: stated,
    category: classifyFlightCategory({ clouds: clouds, visibility: visibility })
  }
}

// What a group leaves out, filled in from the group in force before it. The
// AIM says it plainly: of the change groups, "with the exception of a FM group
// the new time period will include only those elements which are expected to
// change", and of a BECMG, "only the changing forecast meteorological
// conditions are included in BECMG groups. The omitted conditions are carried
// over from the previous time group."
//
// `complete` marks the groups that restate everything — the initial group and
// every FM group, which the AIM names as the exception — so they replace the
// carried state instead of inheriting from it.
function mergeConditions(own, carried, complete) {
  if (complete || !carried) return own

  var wind = own.stated.wind ? own.wind : carried.wind
  var visibility = own.stated.visibility ? own.visibility : carried.visibility
  var clouds = own.stated.clouds ? own.clouds : carried.clouds
  var weather = own.stated.weather ? own.weather : carried.weather

  return {
    wind: wind,
    visibility: visibility,
    clouds: clouds,
    weather: weather,
    stated: own.stated,
    category: classifyFlightCategory({ clouds: clouds, visibility: visibility })
  }
}

// Classify every group against the conditions in force, not against its own
// tokens alone. A BECMG carrying only a wind change governs for its whole
// window with the visibility and sky of the group before it; read on its own
// tokens it has no visibility, which classifies as no category, and the frise
// paints hours of an ordinary forecast grey.
//
// Overlays inherit too, from the prevailing group in force where they open: a
// TEMPO states what fluctuates, not a fresh sky.
function resolveTafConditions(groups) {
  // Document order is time order for the prevailing events, so one pass is
  // enough: each group inherits from the one before it.
  var carried = null
  var prevailing = []
  for (var i = 0; i < groups.length; i++) {
    var group = groups[i]
    if (isOverlayPeriod(group)) {
      var parent = carried
      for (var p = 0; p < prevailing.length; p++) {
        if (prevailing[p].timeFrom <= group.timeFrom && prevailing[p].timeTo > group.timeFrom)
          parent = prevailing[p].conditions
      }
      group.conditions = mergeConditions(group.conditions, parent, false)
    } else {
      var complete = prevailing.length === 0 || group.change === "FM"
      carried = mergeConditions(group.conditions, carried, complete)
      group.conditions = carried
      prevailing.push(group)
    }
  }
  return groups
}

// Parse a TAF into its change groups. Change groups are what the frise is
// built from: base + FM + BECMG prevail, TEMPO/INTER/PROB are overlays.
function parseTaf(json) {
  if (!json || typeof json !== "object") return null
  var raw = String(json.rawTAF === null || json.rawTAF === undefined ? "" : json.rawTAF).trim()
  if (!raw) return null

  var icaoId = String(json.icaoId === null || json.icaoId === undefined ? "" : json.icaoId).toUpperCase()
  var tokens = raw.split(/\s+/)

  var validity = null
  var bodyStart = tokens.length
  for (var i = 0; i < tokens.length; i++) {
    var m = VALIDITY_RE.exec(tokens[i])
    if (m) {
      validity = { fromDay: Number(m[1]), fromHour: Number(m[2]), toDay: Number(m[3]), toHour: Number(m[4]) }
      bodyStart = i + 1
      break
    }
  }
  if (!validity) return null

  var validFromMs = toMillis(json.validTimeFrom)
  var validToMs = toMillis(json.validTimeTo)
  if (validFromMs === null) validFromMs = resolveDayHour(validity.fromDay, validity.fromHour, 0, Date.now())
  if (validToMs === null) validToMs = resolveDayHour(validity.toDay, validity.toHour, 0, validFromMs)
  if (validFromMs === null || validToMs === null) return null

  var groups = []
  var current = { change: null, probability: null, window: null, fmMs: null, tokens: [] }
  var expectWindow = false

  for (var t = bodyStart; t < tokens.length; t++) {
    var token = tokens[t]
    var fm = FM_RE.exec(token)
    if (fm) {
      groups.push(current)
      current = {
        change: "FM",
        probability: null,
        window: null,
        fmMs: resolveDayHour(Number(fm[1]), Number(fm[2]), Number(fm[3]), validFromMs),
        tokens: []
      }
      expectWindow = false
      continue
    }

    var prob = PROB_RE.exec(token)
    if (prob) {
      groups.push(current)
      current = { change: null, probability: Number(prob[1]), window: null, fmMs: null, tokens: [] }
      expectWindow = true
      continue
    }

    if (token === "TEMPO" || token === "INTER") {
      // "PROB30 TEMPO" — the TEMPO qualifies the probability already opened.
      if (expectWindow && current.change === null && current.probability !== null) {
        current.change = token
        continue
      }
      groups.push(current)
      current = { change: token, probability: null, window: null, fmMs: null, tokens: [] }
      expectWindow = true
      continue
    }

    if (token === "BECMG") {
      groups.push(current)
      current = { change: "BECMG", probability: null, window: null, fmMs: null, tokens: [] }
      expectWindow = true
      continue
    }

    var win = VALIDITY_RE.exec(token)
    if (win && expectWindow) {
      current.window = token
      current.windowFromMs = resolveDayHour(Number(win[1]), Number(win[2]), 0, validFromMs)
      current.windowToMs = resolveDayHour(Number(win[3]), Number(win[4]), 0, validFromMs)
      expectWindow = false
      continue
    }

    current.tokens.push(token)
  }
  groups.push(current)

  var periods = []
  for (var g = 0; g < groups.length; g++) {
    var group = groups[g]
    if (!group.tokens.length && !group.window) continue

    var timeFrom = null
    var timeTo = null
    if (group.change === "FM") {
      timeFrom = group.fmMs
      timeTo = validToMs
    } else if (group.window) {
      timeFrom = group.windowFromMs
      timeTo = group.windowToMs
    } else {
      timeFrom = validFromMs
      timeTo = validToMs
    }
    if (timeFrom === null || timeTo === null) continue

    periods.push({
      timeFrom: timeFrom,
      timeTo: timeTo,
      change: group.change,
      probability: group.probability,
      conditions: conditionsFromTokens(group.tokens)
    })
  }

  resolveTafConditions(periods)

  // One flat shape out: the panel and the frise read wdir/wspd/visibility
  // directly, and the inheritance above is a parse-time concern, not a display
  // one. `conditions` is removed rather than left behind — a caller reading a
  // period should not have to know it exists.
  for (var f = 0; f < periods.length; f++) {
    var merged = periods[f].conditions
    delete periods[f].conditions
    periods[f].wdir = merged.wind.wdir
    periods[f].wspd = merged.wind.wspd
    periods[f].wgst = merged.wind.wgst
    periods[f].visibility = merged.visibility
    periods[f].clouds = merged.clouds
    periods[f].weather = merged.weather
    periods[f].category = merged.category
  }

  return {
    icaoId: icaoId,
    raw: raw,
    issueTime: String(json.issueTime === null || json.issueTime === undefined ? "" : json.issueTime),
    validTimeFrom: validFromMs,
    validTimeTo: validToMs,
    periods: periods
  }
}

function isOverlayPeriod(period) {
  if (!period) return false
  if (numberOrNull(period.probability) !== null) return true
  return period.change === "TEMPO" || period.change === "INTER"
}

// The group that governs NOW: the last prevailing event that has opened, and
// whose window has not closed. Overlays are deliberately ignored — a TEMPO
// does not replace the prevailing conditions, it sits over them, and calling
// one "the current forecast" would understate the forecast it overlays.
function currentTafPeriod(periods, nowMs) {
  var now = numberOrNull(nowMs)
  if (now === null || !Array.isArray(periods)) return null

  var best = null
  for (var i = 0; i < periods.length; i++) {
    var p = periods[i]
    if (!p || isOverlayPeriod(p)) continue
    var from = numberOrNull(p.timeFrom)
    var to = numberOrNull(p.timeTo)
    if (from === null || to === null) continue
    if (from > now || to <= now) continue
    // Ties keep the later group, the way tafTimeline resolves a BECMG that
    // opens at the same hour as the group it replaces.
    if (!best || from >= best.timeFrom) best = p
  }
  return best
}

// Earlier observations, newest first, for the trend: a METAR only ever says
// what is happening this half hour, and a falling altimeter or a veering wind
// is not visible in one reading. Entries must be strictly older than the
// current one, or the trend would open with the observation already on screen.
function metarHistory(entries, observedAtMs, limit) {
  var observedAt = numberOrNull(observedAtMs)
  if (!Array.isArray(entries)) return []
  var cap = numberOrNull(limit) === null ? 3 : Math.max(0, Number(limit))

  var history = []
  for (var i = 0; i < entries.length; i++) {
    var parsed = parseMetar(entries[i])
    if (!parsed || numberOrNull(parsed.obsTime) === null) continue
    if (observedAt !== null && parsed.obsTime >= observedAt) continue
    history.push(parsed)
  }
  history.sort(function (a, b) { return b.obsTime - a.obsTime })
  return history.slice(0, cap)
}

// One decoded TAF group as two lines: the heading that says WHEN, and the body
// that says WHAT. `current` marks the group in force now, which is the one
// piece of a decoded forecast that is easy to lose among seven lookalike
// paragraphs.
function describeTafPeriods(taf, units, timeFormat, nowMs) {
  if (!taf || !Array.isArray(taf.periods)) return []
  var useUnits = units === undefined || units === null ? "metric" : units
  var current = currentTafPeriod(taf.periods, nowMs)

  var lines = []
  for (var i = 0; i < taf.periods.length; i++) {
    var period = taf.periods[i]
    var from = formatObsTime(period.timeFrom, timeFormat)
    var to = formatObsTime(period.timeTo, timeFormat)

    var heading = from + " – " + to
    if (period.change) heading += " · " + period.change
    if (period.probability !== null && period.probability !== undefined) heading += " · PROB" + period.probability

    var parts = [period.category || "—"]
    if (numberOrNull(period.wspd) !== null) {
      var dir = period.wdir === "VRB" || numberOrNull(period.wdir) === null
        ? "variable" : pad3(period.wdir) + "°"
      var wind = dir + " " + period.wspd + " kt"
      if (numberOrNull(period.wgst) !== null) wind += " gusting " + period.wgst
      parts.push(wind)
    }
    if (period.visibility && numberOrNull(period.visibility.meters) !== null)
      parts.push("visibility " + formatVisibility(period.visibility, useUnits))

    lines.push({
      header: heading,
      detail: parts.join(", "),
      category: period.category || "",
      overlay: isOverlayPeriod(period),
      current: current !== null && period === current
    })
  }
  return lines
}

// Normalise a station or place name for comparison: lower case, no accents,
// punctuation treated as a separator. "Rennes/St Jacques Arpt" and
// "rennes st jacques" then compare as the same words.
function normalizePlaceName(value) {
  var text = String(value === null || value === undefined ? "" : value)
  text = text.normalize("NFD").replace(/[\u0300-\u036f]/g, "")
  text = text.toLowerCase()
  text = text.replace(/[^a-z0-9]+/g, " ").trim()
  return text
}

// Rank the stations in a bounding-box response against a typed name. The API
// has no name search of its own — `ids=` takes codes only — so the name is
// geocoded to a point, the surrounding fields are fetched by bbox, and they are
// matched here. Every query word must appear in the station name, so "nantes"
// does not match "Nantes/Atlantique" alone but also excludes Laval; a station
// whose name merely starts with the query ranks above one that contains it
// further along, and nearer fields break ties.
function matchStationsByName(entries, query, limit) {
  if (!Array.isArray(entries)) return []
  var words = normalizePlaceName(query).split(" ").filter(function (w) { return w !== "" })
  if (!words.length) return []
  var cap = numberOrNull(limit) === null ? 8 : Math.max(0, Number(limit))

  var matches = []
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i]
    if (!entry || !entry.icaoId) continue
    var normalized = normalizePlaceName(entry.name)
    if (normalized === "") continue

    var all = true
    var prefixHits = 0
    for (var w = 0; w < words.length; w++) {
      var word = words[w]
      if (normalized.indexOf(word) === -1) { all = false; break }
      var nameWords = normalized.split(" ")
      for (var n = 0; n < nameWords.length; n++)
        if (nameWords[n].indexOf(word) === 0) prefixHits++
    }
    if (!all) continue

    matches.push({
      icaoId: String(entry.icaoId).toUpperCase(),
      name: String(entry.name || ""),
      // More words matched at a word start means a better name match; the
      // distance the caller already knows is not recomputed here.
      score: prefixHits,
      latitude: numberOrNull(entry.lat),
      longitude: numberOrNull(entry.lon)
    })
  }

  matches.sort(function (a, b) {
    if (a.score !== b.score) return b.score - a.score
    return a.icaoId < b.icaoId ? -1 : (a.icaoId > b.icaoId ? 1 : 0)
  })
  return matches.slice(0, cap)
}

// One earlier observation on one line, for the trend list: the numbers a
// pilot compares between two reports, in the order the report reads them.
function formatObservationLine(parsed, units) {
  if (!parsed) return ""
  var useUnits = units === undefined || units === null ? "metric" : units
  var parts = []

  var speed = numberOrNull(parsed.wind && parsed.wind.speedKt)
  if (speed === null) parts.push("wind —")
  else if (speed === 0) parts.push("calm")
  else {
    var dir = numberOrNull(parsed.wind.dir)
    var text = (parsed.wind.variableDir === true || dir === null ? "VRB" : pad3(dir) + "°")
      + " " + Math.round(speed) + " kt"
    var gust = numberOrNull(parsed.wind.gustKt)
    if (gust !== null) text += "G" + Math.round(gust)
    parts.push(text)
  }

  var temp = numberOrNull(parsed.tempC)
  var dewp = numberOrNull(parsed.dewpC)
  if (temp !== null || dewp !== null) parts.push(formatTemp(temp, useUnits) + "/" + formatTemp(dewp, useUnits))

  if (numberOrNull(parsed.qnhHpa) !== null) parts.push(formatAltimeter(parsed.qnhHpa, useUnits))
  if (parsed.visibility && numberOrNull(parsed.visibility.meters) !== null)
    parts.push(formatVisibility(parsed.visibility, useUnits))

  return parts.join(" · ")
}

// The window over which a BECMG's change is said to happen, clipped to the
// band it governs.
//
// "BECMG 2418/2420" does not mean the new conditions hold from 18Z: it means
// they become established AT SOME POINT between 18Z and 20Z. The band cannot
// pick an hour the forecast does not name, so it reports the ambiguity it has —
// a ramp from what was in force to what will be — and only the end of the
// window is a time the TAF is willing to commit to.
//
// Null for anything else: an FM group and the initial group state conditions
// from an instant, so their bands are flat.
function becmgRampWindow(period, bandStart, bandEnd) {
  if (!period || period.change !== "BECMG") return null
  var from = numberOrNull(period.timeFrom)
  var to = numberOrNull(period.timeTo)
  if (from === null || to === null) return null
  var start = Math.max(from, bandStart)
  var end = Math.min(to, bandEnd)
  // A window the band swallows whole, or a degenerate one, is no ramp at all.
  if (end <= start) return null
  return { fromMs: start, toMs: end }
}

// Project the forecast onto a pixel frise. Prevailing conditions are swept as
// events (base, FM, BECMG) so the bands tile the whole validity window with no
// gaps; TEMPO and PROB groups come back flagged as overlays, because they
// fluctuate around the prevailing conditions rather than replacing them.
//
// A BECMG band carries a ramp: the fraction of it that the change is expected
// to happen over, with the category in force before it, so the frise can be
// drawn as a transition rather than as a change that took effect on the hour
// the window opened.
function tafTimeline(periods, nowMs, widthPx) {
  var list = []
  if (Array.isArray(periods)) {
    for (var i = 0; i < periods.length; i++) {
      var p = periods[i]
      if (!p) continue
      if (numberOrNull(p.timeFrom) === null || numberOrNull(p.timeTo) === null) continue
      if (p.timeTo <= p.timeFrom) continue
      list.push(p)
    }
  }
  if (!list.length) return { segments: [], nowX: null, fromMs: null, toMs: null, ticks: [] }

  var fromMs = list[0].timeFrom
  var toMs = list[0].timeTo
  for (var j = 1; j < list.length; j++) {
    if (list[j].timeFrom < fromMs) fromMs = list[j].timeFrom
    if (list[j].timeTo > toMs) toMs = list[j].timeTo
  }
  var width = numberOrNull(widthPx) === null ? 0 : Math.max(0, Number(widthPx))
  var span = toMs - fromMs

  function projectX(timeMs) {
    if (span <= 0) return 0
    return Math.round((timeMs - fromMs) / span * width)
  }

  function labelFor(period, timeMs) {
    var hour = pad2(new Date(timeMs).getUTCHours())
    return period.change ? hour + "Z " + period.change : hour + "Z"
  }

  var segments = []

  // Prevailing: sweep events in time order; each event's conditions hold until
  // the next event. Ties keep the later group (a BECMG that opens at the same
  // hour as the base replaces it).
  var events = []
  for (var k = 0; k < list.length; k++) {
    var period = list[k]
    if (isOverlayPeriod(period)) continue
    events.push({ period: period, at: period.timeFrom, order: k })
  }
  // Later groups win an hour tie: a BECMG opening at the base's hour replaces
  // it rather than being swallowed by it.
  events.sort(function (a, b) { return a.at === b.at ? b.order - a.order : a.at - b.at })

  for (var e = 0; e < events.length; e++) {
    var start = events[e].at
    var end = e + 1 < events.length ? events[e + 1].at : toMs
    if (end <= start) continue
    var segPeriod = events[e].period
    // What was in force before this band: the conditions the change moves away
    // from, which is the other end of the ramp.
    var previous = e > 0 ? events[e - 1].period : null
    var ramp = becmgRampWindow(segPeriod, start, end)
    segments.push({
      x: projectX(start),
      width: Math.max(0, projectX(end) - projectX(start)),
      fromMs: start,
      toMs: end,
      category: segPeriod.category,
      change: segPeriod.change,
      overlay: false,
      label: labelFor(segPeriod, start),
      // The ramp is a fraction of THIS band, so it survives the band being
      // clipped: a window that opened before the band, or that the band ends
      // inside, still ramps over the part that is visible.
      ramp: ramp === null ? null : {
        from: (ramp.fromMs - start) / (end - start),
        to: (ramp.toMs - start) / (end - start),
        fromMs: ramp.fromMs,
        toMs: ramp.toMs,
        fromCategory: previous ? previous.category || "" : "",
        toCategory: segPeriod.category || ""
      }
    })
  }

  for (var o = 0; o < list.length; o++) {
    var overlay = list[o]
    if (!isOverlayPeriod(overlay)) continue
    segments.push({
      x: projectX(overlay.timeFrom),
      width: Math.max(0, projectX(overlay.timeTo) - projectX(overlay.timeFrom)),
      fromMs: overlay.timeFrom,
      toMs: overlay.timeTo,
      category: overlay.category,
      change: overlay.change,
      probability: overlay.probability,
      overlay: true,
      label: labelFor(overlay, overlay.timeFrom)
    })
  }

  var nowValue = numberOrNull(nowMs)
  var nowX = nowValue !== null && nowValue >= fromMs && nowValue <= toMs ? projectX(nowValue) : null

  return {
    segments: segments,
    nowX: nowX,
    fromMs: fromMs,
    toMs: toMs,
    ticks: timelineTicks(fromMs, toMs, width, projectX)
  }
}

// Hour marks along the frise. A TAF's own periods can be unreadably wide (a
// 30-hour validity over a 350px card with one BECMG eight hours in says
// nothing about WHEN), so the axis is labelled on clock hours in UTC — the
// same hours the raw report is written in, and the ones a pilot reads off the
// TAF itself.
//
// The step widens with the span so the labels never collide: the frise is a
// glance, and two labels a few pixels apart are worse than none.
function timelineTicks(fromMs, toMs, widthPx, projectX) {
  var span = toMs - fromMs
  if (span <= 0 || widthPx <= 0) return []

  var spanHours = span / 3600000
  var steps = [1, 2, 3, 6, 12, 24]
  // "06Z" is about 26px at the caption size; 40 leaves a readable gap without
  // thinning the axis to the point of saying nothing.
  var minSpacing = 40
  var step = steps[steps.length - 1]
  for (var i = 0; i < steps.length; i++) {
    if (widthPx / (spanHours / steps[i]) >= minSpacing) { step = steps[i]; break }
  }

  var ticks = []
  // A "06Z" label is ~26px wide, so anything closer than this would overlap.
  var minLabelGap = 30

  // The validity start is the one time on the axis that the clock cannot
  // imply, so it is placed unconditionally; every clock tick then yields to
  // whatever is already there rather than crowding it.
  function push(timeMs, force) {
    var x = projectX(timeMs)
    if (x < 0 || x > widthPx) return
    if (!force) {
      for (var d = 0; d < ticks.length; d++)
        if (Math.abs(ticks[d].x - x) < minLabelGap) return
    }
    ticks.push({
      x: x,
      hourMs: timeMs,
      label: pad2(new Date(timeMs).getUTCHours()) + "Z",
      dayStart: new Date(timeMs).getUTCHours() === 0
    })
  }

  push(fromMs, true)
  var cursor = new Date(fromMs)
  cursor = Date.UTC(cursor.getUTCFullYear(), cursor.getUTCMonth(), cursor.getUTCDate(), cursor.getUTCHours(), 0, 0, 0)
  if (cursor < fromMs) cursor += 3600000
  while (cursor % (step * 3600000) !== 0) cursor += 3600000
  for (; cursor <= toMs; cursor += step * 3600000) push(cursor, false)

  return ticks
}

// ---------------------------------------------------------------------------
// Geography

function haversineKm(lat1, lon1, lat2, lon2) {
  var toRad = Math.PI / 180
  var dLat = (lat2 - lat1) * toRad
  var dLon = (lon2 - lon1) * toRad
  var a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) * Math.sin(dLon / 2) * Math.sin(dLon / 2)
  return 6371 * 2 * Math.asin(Math.min(1, Math.sqrt(a)))
}

// The bbox endpoint returns no distance, so the nearest reporting station is
// picked here.
function nearestReportingStation(entries, lat, lon) {
  if (!Array.isArray(entries) || !entries.length) return null
  var targetLat = numberOrNull(lat)
  var targetLon = numberOrNull(lon)
  if (targetLat === null || targetLon === null) return null

  var best = null
  var bestKm = null
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i]
    if (!entry) continue
    var entryLat = numberOrNull(entry.lat)
    var entryLon = numberOrNull(entry.lon)
    if (entryLat === null || entryLon === null) continue
    var km = haversineKm(targetLat, targetLon, entryLat, entryLon)
    if (bestKm === null || km < bestKm) { best = entry; bestKm = km }
  }
  if (!best) return null

  var out = {}
  for (var key in best) out[key] = best[key]
  out.distanceKm = bestKm
  return out
}

// Head/cross components for one runway. Wind direction is where the wind comes
// from, so a wind aligned with the runway heading is a headwind.
function crosswindComponents(runwayAlignmentDeg, windDirDeg, windSpeedKt) {
  var alignment = numberOrNull(runwayAlignmentDeg)
  var direction = numberOrNull(windDirDeg)
  var speed = numberOrNull(windSpeedKt)
  if (alignment === null || direction === null || speed === null) return { head: null, cross: null }

  var delta = ((direction - alignment) % 360 + 540) % 360 - 180
  var radians = delta * Math.PI / 180
  return { head: speed * Math.cos(radians), cross: speed * Math.sin(radians) }
}

// ---------------------------------------------------------------------------
// HTTP response shape

// `204` with an empty body is what aviationweather.gov returns for a request
// whose codes are all unknown — measured 2026-09-22 with `ids=ZZZZ,YYYY`.
// That is "station unknown", which must never be shown as "offline".
function isUnknownStation(response) {
  if (!response) return true
  if (Number(response.status) === 204) return true

  var entries = Array.isArray(response.entries) ? response.entries : []
  if (!entries.length) return true

  var requested = parseStationList(response.requested)
  if (!requested.length) return false

  var present = {}
  for (var i = 0; i < entries.length; i++) {
    if (entries[i] && entries[i].icaoId) present[String(entries[i].icaoId).toUpperCase()] = true
  }
  for (var j = 0; j < requested.length; j++) {
    if (!present[requested[j]]) return true
  }
  return false
}

if (typeof module !== "undefined") {
  module.exports = {
    METERS_PER_SM: METERS_PER_SM,
    UNLIMITED_METERS: UNLIMITED_METERS,
    MAX_QUICK_STATIONS: MAX_QUICK_STATIONS,
    parseStationList: parseStationList,
    addQuickStation: addQuickStation,
    removeQuickStation: removeQuickStation,
    matchVisibilityToken: matchVisibilityToken,
    parseVisibilityMeters: parseVisibilityMeters,
    parseWindFromRaw: parseWindFromRaw,
    ceilingFromClouds: ceilingFromClouds,
    isWeatherToken: isWeatherToken,
    weatherTokens: weatherTokens,
    ceilingCategory: ceilingCategory,
    visibilityCategory: visibilityCategory,
    categorySeverity: categorySeverity,
    classifyFlightCategory: classifyFlightCategory,
    categoryColorRole: categoryColorRole,
    parseMetar: parseMetar,
    markStale: markStale,
    formatObsTime: formatObsTime,
    formatWind: formatWind,
    formatVisibility: formatVisibility,
    formatAltimeter: formatAltimeter,
    formatTemp: formatTemp,
    decodeWeatherToken: decodeWeatherToken,
    decodeMetar: decodeMetar,
    resolveDayHour: resolveDayHour,
    parseTaf: parseTaf,
    isOverlayPeriod: isOverlayPeriod,
    currentTafPeriod: currentTafPeriod,
    metarHistory: metarHistory,
    formatObservationLine: formatObservationLine,
    describeTafPeriods: describeTafPeriods,
    tafTimeline: tafTimeline,
    timelineTicks: timelineTicks,
    haversineKm: haversineKm,
    nearestReportingStation: nearestReportingStation,
    normalizePlaceName: normalizePlaceName,
    matchStationsByName: matchStationsByName,
    crosswindComponents: crosswindComponents,
    isUnknownStation: isUnknownStation,
    isKnownCoverCode: isKnownCoverCode
  }
}

// Unit tests for Autorouter.js — request building (the secret must never reach
// argv), token lifetime, and NOTAM row handling. The response fixture is the
// documented example from the live OpenAPI schema at
// https://api.autorouter.aero/v1.0/openapi.json (fetched 2026-09-22).
var test = require("node:test")
var assert = require("node:assert/strict")
var Autorouter = require("../Autorouter.js")

test("tokenRequestConfig posts client credentials through curl's stdin config", function () {
  var config = Autorouter.tokenRequestConfig("ronan@example.com", "s3cr\"et\\!")
  assert.match(config, /^url = "https:\/\/api\.autorouter\.aerov?/)
  assert.ok(config.indexOf(Autorouter.TOKEN_URL) !== -1)
  assert.match(config, /request = "POST"/)
  assert.match(config, /data-urlencode = "grant_type=client_credentials"/)
  assert.match(config, /data-urlencode = "client_id=ronan@example\.com"/)
  // Quotes and backslashes are escaped so a password cannot break out of the
  // curl config value and inject another directive.
  assert.match(config, /data-urlencode = "client_secret=s3cr\\"et\\\\!"/)
  assert.ok(config.endsWith("\n"))
})

test("parseTokenResponse reads a success and a live invalid_client failure", function () {
  var ok = Autorouter.parseTokenResponse('{"access_token":"abc","expires_in":3600,"token_type":"Bearer"}')
  assert.equal(ok.token, "abc")
  assert.equal(ok.expiresInSec, 3600)
  assert.equal(ok.error, null)

  // Measured live without credentials on 2026-09-22.
  var bad = Autorouter.parseTokenResponse('{"error":"invalid_client","error_description":"The client credentials are invalid"}')
  assert.equal(bad.token, null)
  assert.equal(bad.error, "invalid_client: The client credentials are invalid")

  assert.equal(Autorouter.parseTokenResponse("").token, null)
  assert.equal(Autorouter.parseTokenResponse("<html>").error, "malformed response")
  assert.equal(Autorouter.parseTokenResponse('{"access_token":"a","expires_in":0}').token, "a")
})

test("tokenIsUsable renews only inside the 300 s margin", function () {
  var now = 1790062200000
  assert.equal(Autorouter.tokenIsUsable({ token: "t", expiresAtMs: now + 301000 }, now), true)
  assert.equal(Autorouter.tokenIsUsable({ token: "t", expiresAtMs: now + 299000 }, now), false)
  assert.equal(Autorouter.tokenIsUsable({ token: "t", expiresAtMs: now + 300000 }, now), false)
  assert.equal(Autorouter.tokenIsUsable({ token: "", expiresAtMs: now + 3600000 }, now), false)
  assert.equal(Autorouter.tokenIsUsable(null, now), false)
})

test("notamRequestConfig sends itemas as a JSON array, aerodrome and FIR together", function () {
  var config = Autorouter.notamRequestConfig("TOKEN", ["LFPG", "LFFF"], 40)
  assert.match(config, /header = "Authorization: Bearer TOKEN"/)

  var url = /url = "([^"]+)"/.exec(config)[1]
  assert.ok(url.indexOf(Autorouter.NOTAM_URL) === 0)
  assert.ok(url.indexOf("limit=40") !== -1)

  // The server validates against ^\[\s*(?:"[A-Z]{2}[A-Z0-9]{2}"...)\]$, so the
  // value on the wire must decode back to a well-formed JSON array.
  var encoded = /itemas=([^&]+)/.exec(url)[1]
  assert.deepEqual(JSON.parse(decodeURIComponent(encoded)), ["LFPG", "LFFF"])
  assert.equal(encoded, "%5B%22LFPG%22%2C%22LFFF%22%5D")

  // Bare codes are rejected by the server; a single-item list is still a list.
  assert.deepEqual(JSON.parse(decodeURIComponent(/itemas=([^&]+)/.exec(
    Autorouter.notamRequestConfig("T", ["lfpg"], 10))[1])), ["LFPG"])

  // Duplicates and blanks dropped, and the server's own cap honoured.
  var capped = Autorouter.notamRequestConfig("T", ["LFPG", "lfpg", "", null], 500)
  assert.deepEqual(JSON.parse(decodeURIComponent(/itemas=([^&]+)/.exec(capped)[1])), ["LFPG"])
  assert.ok(capped.indexOf("limit=100") !== -1)
})

function liveRow(overrides) {
  var row = {
    id: 15973913,
    modified: 1781766362,
    nof: "EDDZ",
    series: "A",
    number: 3137,
    year: 26,
    type: "N",
    fir: "EDGG",
    code23: "LC",
    code45: "XX",
    purpose: "BO  ",
    scope: "A  ",
    lower: 0,
    upper: 999,
    startvalidity: 1781766300,
    endvalidity: 2147483647,
    estimation: null,
    itema: ["EDDF"],
    itemd: null,
    iteme: "RWY 07L/25R CENTRE LINE LIGHTS:\nLIGHT EMITTING DIODE (LED) LIGHTS USED IN THE FULL LENGTH OF THE\nRWY CENTRELINE.",
    itemf: null,
    itemg: null,
    suppressed: false
  }
  for (var key in overrides) row[key] = overrides[key]
  return row
}

test("parseNotamResponse tolerates an empty or non-JSON body", function () {
  assert.deepEqual(Autorouter.parseNotamResponse(""),
    { total: 0, rows: [], error: "empty response" })
  assert.deepEqual(Autorouter.parseNotamResponse("   "),
    { total: 0, rows: [], error: "empty response" })
  assert.deepEqual(Autorouter.parseNotamResponse("not json"),
    { total: 0, rows: [], error: "malformed response" })
  assert.deepEqual(Autorouter.parseNotamResponse("[1,2]"),
    { total: 0, rows: [], error: "unexpected response shape" })

  var parsed = Autorouter.parseNotamResponse(JSON.stringify({ total: 1, rows: [liveRow()] }))
  assert.equal(parsed.total, 1)
  assert.equal(parsed.rows.length, 1)
  assert.equal(parsed.error, null)
})

test("an API error is reported, never rendered as an empty result set", function () {
  // The real shape: {"error":"request does not match the API schema: ...",
  // "code":"VALIDATION_FAILED","retryable":false} — observed live 2026-09-22.
  var parsed = Autorouter.parseNotamResponse(JSON.stringify({
    error: "request does not match the API schema: /query/itemas",
    code: "VALIDATION_FAILED",
    data: [],
    retryable: false
  }))
  assert.equal(parsed.rows.length, 0)
  assert.match(parsed.error, /does not match the API schema/)
  assert.match(parsed.error, /VALIDATION_FAILED/)
  // An empty error string is not an error.
  assert.equal(Autorouter.parseNotamResponse(JSON.stringify({ total: 0, rows: [], error: "" })).error, null)
})

test("formatNotamRow rebuilds the id and flags a permanent validity", function () {
  var row = Autorouter.formatNotamRow(liveRow(), "utc")
  assert.equal(row.id, "A3137/26")
  assert.equal(row.icao, "EDDF")
  assert.equal(row.fir, "EDGG")
  assert.equal(row.permanent, true)
  assert.equal(row.validTo, "permanent")
  assert.ok(row.validFrom.endsWith("Z"))
  // Multi-line iteme is folded to one line.
  assert.ok(row.text.indexOf("\n") === -1)
  assert.match(row.text, /^RWY 07L\/25R CENTRE LINE LIGHTS: LIGHT EMITTING DIODE/)

  // A short-series NOTAM and a firm expiry.
  var short = Autorouter.formatNotamRow(liveRow({
    series: "P", number: 825, year: 17, itema: ["LFPG"], endvalidity: 1790062200
  }), "utc")
  assert.equal(short.id, "P0825/17")
  assert.equal(short.permanent, false)
  assert.equal(short.validTo, "22/09 07:30Z")

  // Null endvalidity is permanent too.
  assert.equal(Autorouter.formatNotamRow(liveRow({ endvalidity: null }), "utc").permanent, true)
  assert.equal(Autorouter.formatNotamRow(null, "utc"), null)
})

test("sortNotamRows orders active, then permanent, then upcoming", function () {
  var now = 1790062200000
  var rows = [
    { id: "C", validFromMs: now + 3600000, validToMs: now + 7200000, permanent: false },
    { id: "B", validFromMs: now - 3600000, validToMs: null, permanent: true },
    { id: "A", validFromMs: now - 3600000, validToMs: now + 3600000, permanent: false },
    { id: "D", validFromMs: now - 7200000, validToMs: now + 600000, permanent: false }
  ]
  assert.deepEqual(Autorouter.sortNotamRows(rows, now).map(function (r) { return r.id }), ["D", "A", "B", "C"])
  assert.deepEqual(Autorouter.sortNotamRows(null, now), [])
})

test("filterNotamRows splits station from FIR and never duplicates a row", function () {
  var both = { id: "BOTH", itema: ["LFPG", "LFFF"], fir: "LFFF" }
  var stationOnly = { id: "STATION", itema: ["LFPG"], fir: "LFFF" }
  var firOnly = { id: "FIR", itema: ["LFFF"], fir: "LFFF" }
  var firFieldOnly = { id: "FIRFIELD", itema: ["LFPO"], fir: "LFFF" }
  var elsewhere = { id: "ELSEWHERE", itema: ["EGLL"], fir: "EGTT" }

  var split = Autorouter.filterNotamRows(
    [both, stationOnly, firOnly, firFieldOnly, elsewhere], { icao: "LFPG", fir: "LFFF" })

  assert.deepEqual(split.forStation.map(function (r) { return r.id }), ["BOTH", "STATION"])
  assert.deepEqual(split.forFir.map(function (r) { return r.id }), ["FIR", "FIRFIELD"])

  // No station configured: everything matching the FIR still lands in forFir.
  var firOnlySplit = Autorouter.filterNotamRows([firOnly, elsewhere], { icao: "", fir: "LFFF" })
  assert.deepEqual(firOnlySplit.forStation, [])
  assert.deepEqual(firOnlySplit.forFir.map(function (r) { return r.id }), ["FIR"])

  assert.deepEqual(Autorouter.filterNotamRows(null, { icao: "LFPG" }), { forStation: [], forFir: [] })
})

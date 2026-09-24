// Unit tests for Model.js — the classification and visibility rules the whole
// plugin's correctness rests on. Fixtures are real aviationweather.gov
// responses captured on 2026-09-22.
var test = require("node:test")
var assert = require("node:assert/strict")
var Model = require("../Model.js")

test("parseStationList keeps valid ICAO codes only", function () {
  assert.deepEqual(Model.parseStationList(" LFPG, lfpo\nEB"), ["LFPG", "LFPO"])
  assert.deepEqual(Model.parseStationList(""), [])
  assert.deepEqual(Model.parseStationList("lfpg lfpg"), ["LFPG"])
  assert.deepEqual(Model.parseStationList("LFPG;LFPO"), [])
})

test("the personal list is capped at ten, whatever is stored", function () {
  var eleven = "LFPG,LFPO,LFLL,EGGD,EGLL,LEMD,LIRF,LOWW,LSZH,EHAM,EBBR"
  var list = Model.parseStationList(eleven)
  assert.equal(list.length, 10)
  assert.equal(list[9], "EHAM")
  assert.ok(list.indexOf("EBBR") === -1)
  // An explicit limit still wins, for callers that want a shorter answer.
  assert.equal(Model.parseStationList(eleven, 3).length, 3)
  assert.deepEqual(Model.parseStationList(eleven, 3), ["LFPG", "LFPO", "LFLL"])
})

test("addQuickStation reports why it refused rather than doing nothing", function () {
  var full = "LFPG,LFPO,LFLL,EGGD,EGLL,LEMD,LIRF,LOWW,LSZH,EHAM"

  assert.deepEqual(Model.addQuickStation("LFPG,LFPO", "LFLL"),
    { stations: ["LFPG", "LFPO", "LFLL"], added: true, reason: "" })
  // Already listed: the list does not grow a duplicate, and the caller is told
  // it was a duplicate rather than a full list.
  assert.deepEqual(Model.addQuickStation("LFPG,LFPO", "lfpo"),
    { stations: ["LFPG", "LFPO"], added: false, reason: "duplicate" })
  // Full: the eleventh code is refused, the ten already there are untouched.
  var refused = Model.addQuickStation(full, "EBBR")
  assert.equal(refused.added, false)
  assert.equal(refused.reason, "full")
  assert.equal(refused.stations.length, 10)
  // A malformed code never reaches the list.
  assert.equal(Model.addQuickStation("LFPG", "EB").reason, "invalid")
  assert.equal(Model.addQuickStation("LFPG", "LFPGX").reason, "invalid")
  // Lower case is normalised, not refused.
  assert.equal(Model.addQuickStation("", "lfpg").stations[0], "LFPG")
})

test("removeQuickStation drops one code and keeps the order", function () {
  assert.deepEqual(Model.removeQuickStation("LFPG,LFPO,LFLL", "lfpo"), ["LFPG", "LFLL"])
  assert.deepEqual(Model.removeQuickStation("LFPG,LFPO", "ZZZZ"), ["LFPG", "LFPO"])
  assert.deepEqual(Model.removeQuickStation("", "LFPG"), [])
})

test("visibility thresholds sit on the FAA boundaries, both sides", function () {
  // Ceiling: LIFR <500, IFR <1000, MVFR <=3000, VFR above.
  assert.equal(Model.ceilingCategory(499), "LIFR")
  assert.equal(Model.ceilingCategory(500), "IFR")
  assert.equal(Model.ceilingCategory(999), "IFR")
  assert.equal(Model.ceilingCategory(1000), "MVFR")
  assert.equal(Model.ceilingCategory(3000), "MVFR")
  assert.equal(Model.ceilingCategory(3001), "VFR")

  var sm = Model.METERS_PER_SM
  assert.equal(Model.visibilityCategory(sm * 1 - 1), "LIFR")
  assert.equal(Model.visibilityCategory(sm * 1), "IFR")
  assert.equal(Model.visibilityCategory(sm * 3 - 1), "IFR")
  assert.equal(Model.visibilityCategory(sm * 3), "MVFR")
  assert.equal(Model.visibilityCategory(sm * 5), "MVFR")
  assert.equal(Model.visibilityCategory(sm * 5 + 1), "VFR")
})

test("classifyFlightCategory uses the API fltCat when present", function () {
  assert.equal(Model.classifyFlightCategory({ fltCat: "IFR" }), "IFR")
  assert.equal(Model.classifyFlightCategory({ fltCat: "lifr" }), "LIFR")
  // Unknown fltCat values fall through to the computed rule.
  assert.equal(Model.classifyFlightCategory({ fltCat: "N/A", visibility: { meters: 10000 } }), "VFR")
})

test("only BKN/OVC/VV form a ceiling", function () {
  assert.equal(Model.ceilingFromClouds([{ cover: "FEW", baseFt: 200 }], null), null)
  assert.equal(Model.ceilingFromClouds([{ cover: "SCT", baseFt: 300 }], null), null)
  assert.equal(Model.ceilingFromClouds([{ cover: "VV", baseFt: 200 }], null), 200)
  assert.equal(Model.ceilingFromClouds([{ cover: "OVC", baseFt: 900 }, { cover: "BKN", baseFt: 400 }], null), 400)
  // Vertical visibility counts when no layer is lower.
  assert.equal(Model.ceilingFromClouds([{ cover: "OVC", baseFt: 900 }], 100), 100)
})

test("parseVisibilityMeters reads the raw report, not the lossy JSON field", function () {
  assert.equal(Model.parseVisibilityMeters("METAR EGGD 220650Z AUTO 27007KT 0650 R27/1400N FG OVC002 15/15 Q1030").meters, 650)
  assert.equal(Model.parseVisibilityMeters("METAR LFPG 220630Z 03006KT 340V070 CAVOK 12/08 Q1029 NOSIG").meters, 10000)
  assert.equal(Model.parseVisibilityMeters("METAR LFPO 220730Z 03004KT 9999 SCT030 15/08 Q1030").meters, 10000)
  assert.equal(Model.parseVisibilityMeters("METAR XXXX 220730Z 03004KT 3000 1200SW SCT030 15/08 Q1030").meters, 3000)
  assert.equal(Model.parseVisibilityMeters("METAR XXXX 220730Z 03004KT 1200SW SCT030 15/08 Q1030").meters, 1200)
  assert.equal(Model.parseVisibilityMeters("METAR XXXX 220730Z 03004KT M1/4SM FG OVC002 15/15 Q1030").meters, Model.METERS_PER_SM / 4)
  assert.ok(Model.parseVisibilityMeters("METAR XXXX 220730Z 03004KT P6SM SCT030 15/08 Q1030").meters > 9999)
  assert.equal(Model.parseVisibilityMeters("METAR XXXX 220730Z 03004KT 1 1/2SM BR OVC010 15/15 Q1030").meters, 1.5 * Model.METERS_PER_SM)
  // The 9-digit timestamp must never be read as a 4-digit visibility.
  assert.equal(Model.parseVisibilityMeters("METAR XXXX 220730Z 03004KT SCT030").meters, null)
})

test("parseMetar normalises a live LIFR report", function () {
  var parsed = Model.parseMetar({
    icaoId: "EGGD",
    name: "Bristol Intl, EN, GB",
    fltCat: "LIFR",
    visib: 0.22,
    rawOb: "METAR EGGD 220720Z AUTO 28007KT 0350 R27/0450N FG OVC002 15/15 Q1030",
    clouds: [{ cover: "OVC", base: 200 }],
    vertVis: null,
    obsTime: 1790061600,
    reportTime: "2026-09-22T07:20:00.000Z",
    temp: 15,
    dewp: 15,
    altim: 1030,
    wdir: 280,
    wspd: 7
  })

  assert.equal(parsed.icaoId, "EGGD")
  assert.equal(parsed.category, "LIFR")
  assert.equal(parsed.ceilingFt, 200)
  assert.equal(parsed.visibility.meters, 350)
  assert.deepEqual(parsed.weather, ["FG"])
  assert.equal(parsed.wind.dir, 280)
  assert.equal(parsed.wind.speedKt, 7)
  assert.equal(parsed.wind.gustKt, null)
  assert.equal(parsed.tempC, 15)
  assert.equal(parsed.qnhHpa, 1030)
  assert.equal(parsed.obsTime, 1790061600000)
})

test("parseMetar keeps CAVOK unlimited and variable wind", function () {
  var parsed = Model.parseMetar({
    icaoId: "LFPG",
    fltCat: "VFR",
    visib: "6+",
    rawOb: "METAR LFPG 220730Z 03005KT 340V090 CAVOK 15/09 Q1030 NOSIG",
    clouds: [],
    obsTime: 1790062200,
    temp: 15,
    dewp: 9,
    altim: 1030
  })

  assert.equal(parsed.category, "VFR")
  assert.equal(parsed.visibility.meters, 10000)
  assert.equal(parsed.ceilingFt, null)
  assert.deepEqual(parsed.wind.variable, [340, 90])
  assert.equal(Model.formatVisibility(parsed.visibility, "metric"), "10 km or more")
  assert.equal(Model.formatVisibility(parsed.visibility, "imperial"), "6+ sm")
})

test("classifyFlightCategory falls back to ceiling and visibility together", function () {
  // Visibility fine, ceiling low: the most restrictive wins.
  assert.equal(Model.classifyFlightCategory({
    rawOb: "METAR XXXX 220730Z 03005KT 9999 OVC008 15/09 Q1030",
    clouds: [{ cover: "OVC", baseFt: 800 }],
    visibility: { meters: 10000 }
  }), "IFR")

  assert.equal(Model.classifyFlightCategory({
    rawOb: "METAR XXXX 220730Z 03005KT 9999 OVC004 15/09 Q1030",
    clouds: [{ cover: "OVC", baseFt: 400 }],
    visibility: { meters: 10000 }
  }), "LIFR")

  // Ceiling fine, visibility low.
  assert.equal(Model.classifyFlightCategory({
    rawOb: "METAR XXXX 220730Z 03005KT 2000 BR SCT030 15/15 Q1030",
    clouds: [{ cover: "SCT", baseFt: 3000 }],
    visibility: { meters: 2000 }
  }), "IFR")

  assert.equal(Model.classifyFlightCategory({ clouds: [], visibility: null }), "")
})

test("decodeWeatherToken expands the standard groups", function () {
  assert.equal(Model.decodeWeatherToken("FG"), "fog")
  assert.equal(Model.decodeWeatherToken("-RADZ"), "light rain and drizzle")
  assert.equal(Model.decodeWeatherToken("+TSRA"), "heavy thunderstorm with rain")
  assert.equal(Model.decodeWeatherToken("VCSH"), "in the vicinity showers of")
  assert.equal(Model.decodeWeatherToken("BR"), "mist")
  assert.equal(Model.decodeWeatherToken("BCFG"), "patches of fog")
  assert.equal(Model.decodeWeatherToken("NSW"), "no significant weather")
  assert.equal(Model.decodeWeatherToken("ZZZZ"), "ZZZZ")
})

test("weather tokens never pick up wind, cloud or QNH groups", function () {
  assert.deepEqual(
    Model.weatherTokens("METAR EGGD 220720Z AUTO 28007KT 0350 R27/0450N FG OVC002 15/15 Q1030"),
    ["FG"]
  )
  assert.deepEqual(
    Model.weatherTokens("METAR XXXX 220730Z 03005KT 9999 -RA BKN020 15/09 Q1030"),
    ["-RA"]
  )
  assert.deepEqual(
    Model.weatherTokens("METAR XXXX 220730Z 03005KT CAVOK 15/09 Q1030"),
    []
  )
})

test("an unknown cloud cover never reaches the decoded reading", function () {
  // The API response is remote input. A cover value outside the known codes is
  // dropped rather than echoed: echoing it put endpoint-controlled text into
  // the one Text item that used to interpret markup.
  assert.equal(Model.isKnownCoverCode("OVC"), true)
  assert.equal(Model.isKnownCoverCode("bkn"), true)
  assert.equal(Model.isKnownCoverCode("NSC"), true)
  assert.equal(Model.isKnownCoverCode("<b>OVC</b>"), false)
  assert.equal(Model.isKnownCoverCode("<img src=x>"), false)
  assert.equal(Model.isKnownCoverCode(""), false)
  assert.equal(Model.isKnownCoverCode(null), false)

  var parsed = Model.parseMetar({
    icaoId: "LFRN", obsTime: 1790087400,
    rawOb: "METAR LFRN 221430Z 05006KT CAVOK 27/06 Q1026",
    clouds: [
      { cover: "OVC", base: 200 },
      { cover: "<b>BKN</b>", base: 900 },
      { cover: "<img src=\"http://evil/x\">", base: 100 }
    ]
  })
  // Only the known layer survives, so the decoded text is ours, not theirs.
  assert.equal(parsed.clouds.length, 1)
  assert.equal(parsed.clouds[0].cover, "OVC")

  var text = Model.decodeMetar(parsed)
  assert.ok(text.indexOf("<") === -1, "decoded text must contain no markup: " + text)
  assert.ok(text.indexOf("overcast") !== -1)

  // A cover code that is known but has no word still decodes to itself, rather
  // than to nothing: these are real codes, not garbage.
  var ncd = Model.decodeMetar({ clouds: [{ cover: "NCD", baseFt: null }], raw: "" })
  assert.ok(ncd.indexOf("no cloud detected") !== -1, ncd)
})

test("decodeMetar produces a sentence with the observed conditions", function () {
  var parsed = Model.parseMetar({
    icaoId: "EGGD",
    rawOb: "METAR EGGD 220720Z AUTO 28007KT 0350 R27/0450N FG OVC002 15/15 Q1030",
    clouds: [{ cover: "OVC", base: 200 }],
    obsTime: 1790061600,
    temp: 15,
    dewp: 15,
    altim: 1030
  })
  var text = Model.decodeMetar(parsed)
  assert.match(text, /wind 280° at 7 kt/i)
  assert.match(text, /visibility 350 m/)
  assert.match(text, /fog/)
  assert.match(text, /overcast at 200 ft/)
  assert.match(text, /temperature 15 °C, dew point 15 °C/)
  assert.match(text, /QNH 1030 hPa/)
})

test("formatWind keeps knots regardless of units", function () {
  var parsed = Model.parseMetar({
    icaoId: "XXXX",
    rawOb: "METAR XXXX 220730Z 03015G25KT 9999 SCT030 15/09 Q1030",
    clouds: []
  })
  assert.equal(Model.formatWind(parsed, "metric"), "030° 15 kt gusting 25")
  assert.equal(Model.formatWind(parsed, "imperial"), "030° 15 kt gusting 25")
  assert.equal(Model.formatWind({ wind: { speedKt: 0 } }, "metric"), "calm")
  assert.equal(Model.formatWind({ wind: {} }, "metric"), "—")
})

test("formatAltimeter and formatTemp follow the units setting", function () {
  assert.equal(Model.formatAltimeter(1030, "metric"), "1030 hPa")
  assert.equal(Model.formatAltimeter(1030, "imperial"), "30.42 inHg")
  assert.equal(Model.formatTemp(15, "metric"), "15 °C")
  assert.equal(Model.formatTemp(15, "imperial"), "59 °F")
  assert.equal(Model.formatTemp(null, "metric"), "—")
})

test("markStale flips on the max-age boundary", function () {
  var now = 1790062200000
  var fresh = { obsTime: now - 80 * 60000 }
  var old = { obsTime: now - 80 * 60000 }
  assert.equal(Model.markStale(fresh, 75, now - 10 * 60000).stale, false)
  assert.equal(Model.markStale(old, 75, now).stale, true)
  assert.equal(Model.markStale({ obsTime: null }, 75, now).stale, false)
})

test("parseTaf reads the live LFPG single-period forecast", function () {
  var taf = Model.parseTaf({
    icaoId: "LFPG",
    rawTAF: "TAF LFPG 220500Z 2206/2312 05005KT CAVOK TX24/2214Z TN10/2206Z",
    issueTime: "2026-09-22T05:00:00.000Z",
    validTimeFrom: 1790056800,
    validTimeTo: 1790164800,
    fcsts: [{ timeFrom: 1790056800, timeTo: 1790164800, fcstChange: null, visib: "6+", wdir: 50, wspd: 5 }]
  })

  assert.equal(taf.icaoId, "LFPG")
  assert.equal(taf.periods.length, 1)
  assert.equal(taf.periods[0].category, "VFR")
  assert.equal(taf.periods[0].visibility.meters, 10000)
  assert.equal(taf.periods[0].wspd, 5)
  assert.equal(taf.validTimeFrom, 1790056800000)
  assert.equal(taf.validTimeTo, 1790164800000)
})

test("parseTaf splits FM, BECMG and TEMPO change groups", function () {
  var taf = Model.parseTaf({
    icaoId: "KJFK",
    rawTAF: "TAF KJFK 220529Z 2206/2312 06009KT P6SM VCSH OVC050 FM221500 04014G24KT P6SM OVC070 FM230200 03014G20KT P6SM SCT100 SCT250",
    validTimeFrom: 1790056800,
    validTimeTo: 1790164800
  })
  assert.equal(taf.periods.length, 3)
  assert.equal(taf.periods[1].change, "FM")
  assert.equal(taf.periods[1].wgst, 24)
  assert.equal(taf.periods[1].category, "VFR")
})

test("parseTaf keeps PROB/TEMPO groups as overlays", function () {
  var taf = Model.parseTaf({
    icaoId: "EGLL",
    rawTAF: "TAF EGLL 220454Z 2206/2312 VRB03KT 9999 SCT035 PROB30 2206/2208 6000 PROB30 2218/2224 16010KT PROB30 2303/2308 6000 PROB30 TEMPO 2310/2312 28015G25KT 6000 SHRA",
    validTimeFrom: 1790056800,
    validTimeTo: 1790164800
  })

  var overlays = taf.periods.filter(Model.isOverlayPeriod)
  assert.equal(overlays.length, 4)
  assert.equal(overlays[3].change, "TEMPO")
  assert.equal(overlays[3].probability, 30)
  assert.equal(overlays[3].wgst, 25)
  assert.deepEqual(overlays[3].weather, ["SHRA"])
  assert.equal(overlays[3].category, "MVFR")
  // A bare PROB group with no conditions still carries its probability.
  assert.equal(overlays[1].probability, 30)

  var prevailing = taf.periods.filter(function (p) { return !Model.isOverlayPeriod(p) })
  assert.equal(prevailing.length, 1)
  assert.equal(prevailing[0].category, "VFR")
})

test("a BECMG that carries only a wind change keeps the sky and visibility before it", function () {
  // The live OEJN forecast, which is where this was found: the BECMG opens at
  // 18Z stating a wind and nothing else, and read on its own tokens it had no
  // visibility — no category, and two hours of the frise painted grey.
  // AIM 7-1-29: "The omitted conditions are carried over from the previous
  // time group."
  var taf = Model.parseTaf({
    icaoId: "OEJN",
    rawTAF: "TAF OEJN 240500Z 2406/2512 32014KT CAVOK BECMG 2418/2420 36008KT "
      + "BECMG 2500/2502 VRB03KT 7000 NSC PROB30 TEMPO 2500/2505 2000 BR BECMG 2506/2508 34014KT CAVOK",
    validTimeFrom: Date.UTC(2026, 8, 24, 6) / 1000,
    validTimeTo: Date.UTC(2026, 8, 25, 12) / 1000
  })

  var becmg = taf.periods[1]
  assert.equal(becmg.change, "BECMG")
  // The change itself took effect...
  assert.equal(becmg.wdir, 360)
  assert.equal(becmg.wspd, 8)
  // ...and the elements it did not mention are the ones in force before it.
  assert.equal(becmg.visibility.meters, 10000)
  assert.equal(becmg.category, "VFR")

  // Every band of the frise therefore has a category: the grey was a band that
  // classified as nothing at all.
  var timeline = Model.tafTimeline(taf.periods, Date.UTC(2026, 8, 24, 19), 500)
  var bands = timeline.segments.filter(function (s) { return !s.overlay })
  assert.ok(bands.length > 1)
  for (var i = 0; i < bands.length; i++)
    assert.notEqual(Model.categoryColorRole(bands[i].category), "none")

  // A BECMG that DOES state new conditions replaces them rather than merging
  // with what came before.
  var stated = taf.periods[2]
  assert.equal(stated.visibility.meters, 7000)
  assert.equal(stated.category, "MVFR")
})

test("a FM group restates every element and never inherits", function () {
  // AIM 7-1-29 names FM as the exception: "A FM group contains all the
  // required elements". A FM that lowered the ceiling must not keep the
  // visibility of the group before it.
  var taf = Model.parseTaf({
    icaoId: "KJFK",
    rawTAF: "TAF KJFK 220529Z 2206/2312 06009KT P6SM OVC050 FM221500 04014G24KT 2SM BR OVC008",
    validTimeFrom: 1790056800,
    validTimeTo: 1790164800
  })

  assert.equal(taf.periods[0].category, "VFR")
  var fm = taf.periods[1]
  assert.equal(fm.change, "FM")
  // 2 SM visibility and an 800 ft ceiling: IFR, not the VFR it inherited from.
  assert.equal(fm.visibility.meters, 2 * Model.METERS_PER_SM)
  assert.equal(fm.category, "IFR")
})

test("a TEMPO that states a wind but no visibility keeps the visibility it fluctuates around", function () {
  var taf = Model.parseTaf({
    icaoId: "EGLL",
    rawTAF: "TAF EGLL 220454Z 2206/2312 VRB03KT 9999 SCT035 TEMPO 2210/2212 28015G25KT",
    validTimeFrom: 1790056800,
    validTimeTo: 1790164800
  })

  var tempo = taf.periods[1]
  assert.equal(Model.isOverlayPeriod(tempo), true)
  assert.equal(tempo.wspd, 15)
  // The overlay states no visibility, so it shows the conditions it sits over
  // rather than nothing.
  assert.equal(tempo.visibility.meters, 10000)
  assert.equal(tempo.category, "VFR")
})

test("NSW states the weather as clear and does not inherit the old weather", function () {
  var taf = Model.parseTaf({
    icaoId: "EGLL",
    rawTAF: "TAF EGLL 220454Z 2206/2312 20010KT 4000 RA BKN010 BECMG 2208/2210 9999 NSW SCT030",
    validTimeFrom: 1790056800,
    validTimeTo: 1790164800
  })

  assert.deepEqual(taf.periods[0].weather, ["RA"])
  // NSW is a value — "nothing significant" — not an omission, so the rain does
  // not survive into the group that called it off.
  var becmg = taf.periods[1]
  assert.deepEqual(becmg.weather, [])
  assert.equal(becmg.category, "VFR")
})

test("currentTafPeriod names the prevailing group in force, never an overlay", function () {
  var taf = Model.parseTaf({
    icaoId: "KJFK",
    rawTAF: "TAF KJFK 220529Z 2206/2312 06009KT P6SM VCSH OVC050 FM221500 04014G24KT P6SM OVC070 FM230200 03014G20KT P6SM SCT100",
    validTimeFrom: 1790056800,
    validTimeTo: 1790164800
  })

  // Before the first FM: the base group holds.
  assert.equal(Model.currentTafPeriod(taf.periods, Date.UTC(2026, 8, 22, 8) ).category, "VFR")
  // Inside the second group's window.
  var second = Model.currentTafPeriod(taf.periods, Date.UTC(2026, 8, 22, 16))
  assert.equal(second.change, "FM")
  assert.equal(second.wspd, 14)
  // Past the last group's opening, that group governs to the end of validity.
  var third = Model.currentTafPeriod(taf.periods, Date.UTC(2026, 8, 23, 6))
  assert.equal(third.change, "FM")
  assert.equal(third.wspd, 14)
  // Outside the validity window there is no current group at all.
  assert.equal(Model.currentTafPeriod(taf.periods, Date.UTC(2026, 8, 21, 0)), null)

  // An overlay in force does not become the current group: it qualifies the
  // prevailing conditions rather than replacing them.
  var prob = Model.parseTaf({
    icaoId: "EGLL",
    rawTAF: "TAF EGLL 220454Z 2206/2312 VRB03KT 9999 SCT035 PROB30 TEMPO 2210/2212 28015G25KT 6000 SHRA",
    validTimeFrom: 1790056800,
    validTimeTo: 1790164800
  })
  var inTempo = Model.currentTafPeriod(prob.periods, Date.UTC(2026, 8, 22, 11))
  assert.equal(Model.isOverlayPeriod(inTempo), false)
  assert.equal(inTempo.wspd, 3)
})

test("metarHistory returns strict earlier observations, newest first", function () {
  var entries = [
    { icaoId: "LFRN", obsTime: 1790087400, rawOb: "METAR LFRN 221430Z 05006KT CAVOK 27/06 Q1026" },
    { icaoId: "LFRN", obsTime: 1790085600, rawOb: "METAR LFRN 221400Z 05008KT CAVOK 26/06 Q1026" },
    { icaoId: "LFRN", obsTime: 1790083800, rawOb: "METAR LFRN 221330Z 09005KT CAVOK 26/08 Q1026" },
    { icaoId: "LFRN", obsTime: 1790082000, rawOb: "METAR LFRN 221300Z 04007KT CAVOK 26/08 Q1027" }
  ]
  var history = Model.metarHistory(entries, 1790087400000, 3)
  assert.equal(history.length, 3)
  // The observation already on screen is not repeated as "history".
  assert.equal(history[0].obsTime, 1790085600000)
  assert.equal(history[2].obsTime, 1790082000000)
  assert.equal(Model.metarHistory(entries, 1790087400000, 1).length, 1)
  // Entries with no timestamp cannot be ordered and are dropped.
  assert.deepEqual(Model.metarHistory([{ icaoId: "LFRN" }], 1790087400000, 3), [])
  assert.deepEqual(Model.metarHistory(null, 1790087400000, 3), [])
})

test("normalizePlaceName folds accents, case and punctuation", function () {
  assert.equal(Model.normalizePlaceName("Rennes/St Jacques Arpt"), "rennes st jacques arpt")
  assert.equal(Model.normalizePlaceName("  NANTES-Atlantique  "), "nantes atlantique")
  assert.equal(Model.normalizePlaceName("Saint-Brieuc/Armor"), "saint brieuc armor")
  // An accented query has to fold to the same form as the ASCII station name.
  assert.equal(Model.normalizePlaceName("Brest-Guipavas"), Model.normalizePlaceName("Brest Guipavas"))
  assert.equal(Model.normalizePlaceName("Brést"), Model.normalizePlaceName("brest"))
  assert.equal(Model.normalizePlaceName(null), "")
})

test("matchStationsByName requires every query word and ranks word starts", function () {
  var entries = [
    { icaoId: "LFRS", name: "Nantes/Atlantique Arpt" },
    { icaoId: "LFOV", name: "Laval/Entrammes Arpt" },
    { icaoId: "LFRN", name: "Rennes/St Jacques Arpt" },
    { icaoId: "LFBO", name: "Toulouse/Blagnac" },
    { icaoId: "LFPG", name: "Paris/Charles de Gaulle" },
    { name: "Jersey 5S" }
  ]

  // One word: only the stations whose name contains it.
  var nantes = Model.matchStationsByName(entries, "nantes", 8)
  assert.deepEqual(nantes.map(function (s) { return s.icaoId }), ["LFRS"])

  // Case and accents do not matter.
  assert.deepEqual(Model.matchStationsByName(entries, "RENNES", 8).map(function (s) { return s.icaoId }), ["LFRN"])

  // Two words must both appear, which is what makes a long name usable.
  assert.deepEqual(Model.matchStationsByName(entries, "charles gaulle", 8).map(function (s) { return s.icaoId }), ["LFPG"])
  // ... and the wrong order still works, because matching is per word.
  assert.deepEqual(Model.matchStationsByName(entries, "gaulle charles", 8).map(function (s) { return s.icaoId }), ["LFPG"])

  // A word that matches nothing returns nothing rather than the whole list.
  assert.deepEqual(Model.matchStationsByName(entries, "nantes laval", 8), [])

  // Entries with no ICAO code are never a station to select.
  assert.deepEqual(Model.matchStationsByName(entries, "jersey", 8), [])

  // Word-start matches rank above mid-word matches. "st" opens a word in
  // "St Jacques" but not in "Brest".
  var ranked = Model.matchStationsByName([
    { icaoId: "LFRB", name: "Brest/Guipavas" },
    { icaoId: "LFRN", name: "Rennes/St Jacques Arpt" }
  ], "st", 8)
  assert.deepEqual(ranked.map(function (s) { return s.icaoId }), ["LFRN", "LFRB"])

  assert.equal(Model.matchStationsByName(entries, "nantes", 8)[0].score, 1)
  assert.deepEqual(Model.matchStationsByName(entries, "", 8), [])
  assert.deepEqual(Model.matchStationsByName(null, "nantes", 8), [])
})

test("formatObservationLine reads one report as one comparison line", function () {
  var entries = [
    { icaoId: "LFRN", obsTime: 1790087400, temp: 27, dewp: 6, altim: 1026, wdir: 50, wspd: 6, visib: "6+",
      rawOb: "METAR LFRN 221430Z 05006KT 360V100 CAVOK 27/06 Q1026 NOSIG" },
    { icaoId: "LFRN", obsTime: 1790085600, temp: 26, dewp: 6, altim: 1026, wdir: 50, wspd: 8, visib: "6+",
      rawOb: "METAR LFRN 221400Z 05008KT CAVOK 26/06 Q1026" }
  ]
  var history = Model.metarHistory(entries, 1790087400000, 3)
  assert.equal(Model.formatObservationLine(history[0], "metric"), "050° 8 kt · 26 °C/6 °C · 1026 hPa · 10 km or more")

  // Wind that did not report, and a gust: both stay readable on one line.
  var gusty = Model.parseMetar({
    icaoId: "KJFK", obsTime: 1790087400,
    rawOb: "METAR KJFK 221430Z 04014G24KT 10SM BKN020 18/12 A2992",
    temp: 18, dewp: 12, altim: 1013
  })
  // 18 °C is 64 °F, 1013 hPa (the JSON side of A2992) is 29.91 inHg, and 10 SM
  // is past the 6 sm the display calls unlimited. The wind stays in knots in
  // both unit systems, as it is spoken.
  assert.equal(Model.formatObservationLine(gusty, "imperial"),
    "040° 14 ktG24 · 64 °F/54 °F · 29.91 inHg · 6+ sm")
  assert.equal(Model.formatObservationLine(gusty, "metric"),
    "040° 14 ktG24 · 18 °C/12 °C · 1013 hPa · 10 km or more")
  assert.equal(Model.formatObservationLine(null, "metric"), "")
})

test("describeTafPeriods marks the group in force and splits heading from body", function () {
  var taf = Model.parseTaf({
    icaoId: "KJFK",
    rawTAF: "TAF KJFK 220529Z 2206/2312 06009KT P6SM VCSH OVC050 FM221500 04014G24KT P6SM OVC070 FM230200 03014G20KT P6SM SCT100",
    validTimeFrom: 1790056800,
    validTimeTo: 1790164800
  })
  var now = Date.UTC(2026, 8, 22, 16)
  var lines = Model.describeTafPeriods(taf, "metric", "utc", now)

  assert.equal(lines.length, 3)
  // Exactly one line is "the one that applies now", and it is the second group.
  assert.equal(lines.filter(function (l) { return l.current }).length, 1)
  assert.equal(lines[1].current, true)
  assert.equal(lines[0].current, false)

  // The heading carries the window; the body carries the conditions.
  assert.ok(lines[1].header.indexOf("–") !== -1)
  assert.ok(lines[1].header.indexOf("FM") !== -1)
  assert.equal(lines[1].detail, "VFR, 040° 14 kt gusting 24, visibility 10 km or more")

  // An overlay is flagged as one, so the view can indent it under the group it
  // qualifies rather than presenting it as a separate forecast.
  var prob = Model.parseTaf({
    icaoId: "EGLL",
    rawTAF: "TAF EGLL 220454Z 2206/2312 VRB03KT 9999 SCT035 PROB30 TEMPO 2308/2310 28015G25KT 3000 SHRA",
    validTimeFrom: 1790056800,
    validTimeTo: 1790164800
  })
  var overlayLines = Model.describeTafPeriods(prob, "metric", "utc", Date.UTC(2026, 8, 22, 11))
  assert.equal(overlayLines.length, 2)
  assert.equal(overlayLines[1].overlay, true)
  assert.equal(overlayLines[1].current, false)
  assert.ok(overlayLines[1].header.indexOf("PROB30") !== -1)
  assert.ok(overlayLines[1].header.indexOf("TEMPO") !== -1)

  assert.deepEqual(Model.describeTafPeriods(null, "metric", "utc", now), [])
})

test("tafTimeline ramps a BECMG band from the conditions before it", function () {
  var period = function (from, to, category, change) {
    return { timeFrom: from, timeTo: to, category: category, change: change, probability: null }
  }
  var h = 3600000
  var base = Date.UTC(2026, 8, 24, 6)
  // A BECMG period's timeFrom/timeTo IS its window — "BECMG 2418/2420" — not the
  // length of its band. The band runs from the window's start until the next
  // group takes over at 00Z: 6 h over 220px at 10px/h, so 60px. The 18Z–20Z
  // window is the first 20px of that, and the remaining 40px are settled MVFR.
  var timeline = Model.tafTimeline([
    period(base, base + 12 * h, "VFR", null),
    period(base + 12 * h, base + 14 * h, "MVFR", "BECMG"),
    period(base + 18 * h, base + 22 * h, "IFR", "FM")
  ], null, 220)

  var bands = timeline.segments.filter(function (s) { return !s.overlay })
  assert.equal(bands.length, 3)

  // The initial group has nothing to ramp from, and an FM group states its
  // conditions from an instant.
  assert.equal(bands[0].ramp, null)
  assert.equal(bands[2].ramp, null)

  var becmg = bands[1]
  assert.equal(becmg.width, 60)
  assert.ok(becmg.ramp, "a BECMG band carries a ramp")
  // A third of the band, ramping from what was in force to what it states.
  assert.equal(Math.round(becmg.ramp.from * becmg.width), 0)
  assert.equal(Math.round(becmg.ramp.to * becmg.width), 20)
  assert.equal(becmg.ramp.fromCategory, "VFR")
  assert.equal(becmg.ramp.toCategory, "MVFR")
})

test("a BECMG window that outruns its band is clipped to the visible part", function () {
  var period = function (from, to, category, change) {
    return { timeFrom: from, timeTo: to, category: category, change: change, probability: null }
  }
  var h = 3600000
  var base = Date.UTC(2026, 8, 24, 6)
  // "BECMG 2418/2422" ramps over four hours, but a group taking over at 20Z
  // ends the band first: the ramp can only cover the 18Z–20Z that is drawn,
  // and it must still reach the far edge rather than stopping short of it.
  var timeline = Model.tafTimeline([
    period(base, base + 12 * h, "VFR", null),
    period(base + 12 * h, base + 16 * h, "MVFR", "BECMG"),
    period(base + 14 * h, base + 18 * h, "IFR", "FM")
  ], null, 180)

  var becmg = timeline.segments.filter(function (s) { return !s.overlay })[1]
  assert.equal(becmg.width, 20)
  assert.ok(becmg.ramp)
  // Clipped to the band: the ramp spans the whole of it, not the four hours.
  assert.equal(becmg.ramp.from, 0)
  assert.equal(becmg.ramp.to, 1)
  assert.equal(becmg.ramp.toMs, becmg.toMs)
})

test("tafTimeline tiles the validity window and marks overlays", function () {
  var taf = Model.parseTaf({
    icaoId: "KJFK",
    rawTAF: "TAF KJFK 220529Z 2206/2312 06009KT P6SM VCSH OVC050 FM221500 04014G24KT P6SM OVC070 FM230200 03014G20KT P6SM SCT100",
    validTimeFrom: 1790056800,
    validTimeTo: 1790164800
  })
  var now = 1790089200000 // 22/15:00Z, exactly at the second FM group
  var timeline = Model.tafTimeline(taf.periods, now, 300)

  assert.equal(timeline.fromMs, 1790056800000)
  assert.equal(timeline.toMs, 1790164800000)
  assert.equal(timeline.segments.length, 3)
  assert.equal(timeline.nowX, Math.round((now - timeline.fromMs) / (timeline.toMs - timeline.fromMs) * 300))

  // No gaps: each prevailing band starts where the previous ends.
  var bands = timeline.segments.filter(function (s) { return !s.overlay })
  for (var i = 1; i < bands.length; i++)
    assert.equal(bands[i].x, bands[i - 1].x + bands[i - 1].width)
  assert.equal(bands[bands.length - 1].x + bands[bands.length - 1].width, 300)
})

test("tafTimeline labels the axis on clock hours, widened to fit", function () {
  var taf = Model.parseTaf({
    icaoId: "LFPG",
    rawTAF: "TAF LFPG 220500Z 2206/2312 05005KT CAVOK",
    validTimeFrom: 1790056800,   // 22/06:00Z
    validTimeTo: 1790164800      // 23/12:00Z, a 30-hour validity
  })

  // 30 hours over 350px: one tick per hour would collide, so the step widens.
  var wide = Model.tafTimeline(taf.periods, null, 350)
  assert.ok(wide.ticks.length > 0)
  assert.ok(wide.ticks.length <= 12, "30 h over 350px must not draw 30 labels")
  // The validity start is always labelled, whatever the step lands on.
  assert.equal(wide.ticks[0].x, 0)
  // Ticks are ordered and inside the canvas.
  for (var i = 0; i < wide.ticks.length; i++) {
    assert.ok(wide.ticks[i].x >= 0 && wide.ticks[i].x <= 350)
    if (i > 0) assert.ok(wide.ticks[i].x > wide.ticks[i - 1].x)
  }
  // Labels are bare UTC hours, whatever the span: the date on the axis said
  // less than the space it took.
  assert.equal(wide.ticks[0].label, "06Z")
  assert.ok(wide.ticks.every(function (t) { return /^[0-9]{2}Z$/.test(t.label) }))
  // Midnight is still tagged, so a long validity keeps its day boundaries
  // readable without spelling the date out.
  assert.ok(wide.ticks.some(function (t) { return t.label === "00Z" && t.dayStart }))

  // A short validity gets hourly labels without the date.
  var short = Model.tafTimeline([
    { timeFrom: Date.UTC(2026, 8, 22, 6), timeTo: Date.UTC(2026, 8, 22, 10), category: "VFR" }
  ], null, 350)
  assert.deepEqual(short.ticks.map(function (t) { return t.label }),
    ["06Z", "07Z", "08Z", "09Z", "10Z"])

  // No forecast, no ticks.
  assert.deepEqual(Model.tafTimeline([], null, 350).ticks, [])
})

test("tafTimeline keeps every band tiling a zero-width canvas", function () {
  var timeline = Model.tafTimeline([
    { timeFrom: 1000, timeTo: 4000, category: "VFR", change: null, probability: null }
  ], null, 0)
  assert.deepEqual(timeline.ticks, [])
  assert.equal(timeline.segments.length, 1)
})

test("tafTimeline renders TEMPO bands as overlays without replacing the parent", function () {
  var period = function (from, to, category, change, probability) {
    return { timeFrom: from, timeTo: to, category: category, change: change, probability: probability }
  }
  var timeline = Model.tafTimeline([
    period(1000, 4000, "VFR", null, null),
    period(2000, 3000, "IFR", "TEMPO", null)
  ], 2500, 300)

  var bands = timeline.segments.filter(function (s) { return !s.overlay })
  var overlays = timeline.segments.filter(function (s) { return s.overlay })
  assert.equal(bands.length, 1)
  assert.equal(bands[0].category, "VFR")
  assert.equal(bands[0].width, 300)
  assert.equal(overlays.length, 1)
  assert.equal(overlays[0].category, "IFR")
  assert.equal(overlays[0].x, 100)
  assert.equal(overlays[0].width, 100)
})

test("formatObsTime honours the utc and local settings", function () {
  var ms = Date.UTC(2026, 8, 22, 7, 30, 0)
  assert.equal(Model.formatObsTime(ms, "utc"), "07:30Z")
  assert.match(Model.formatObsTime(ms, "local"), /^\d{2}:\d{2} \(UTC[+-]\d/)
  assert.equal(Model.formatObsTime(null, "utc"), "—")
})

test("crosswindComponents splits head and cross for a runway", function () {
  // Runway 09 (090°), wind 090° at 20 kt: pure headwind.
  var aligned = Model.crosswindComponents(90, 90, 20)
  assert.equal(Math.round(aligned.head), 20)
  assert.equal(Math.round(aligned.cross), 0)

  // Runway 09, wind 180° at 20 kt: pure crosswind.
  var across = Model.crosswindComponents(90, 180, 20)
  assert.equal(Math.round(across.head), 0)
  assert.equal(Math.round(across.cross), 20)

  // Runway 09, wind 270° at 20 kt: pure tailwind.
  assert.equal(Math.round(Model.crosswindComponents(90, 270, 20).head), -20)
  assert.deepEqual(Model.crosswindComponents(null, 90, 20), { head: null, cross: null })
})

test("nearestReportingStation picks by haversine distance", function () {
  var entries = [
    { icaoId: "LFPO", lat: 48.72, lon: 2.38 },
    { icaoId: "LFPG", lat: 49.01, lon: 2.55 },
    { icaoId: "LFLL", lat: 45.72, lon: 5.08 }
  ]
  // Reference point right next to Roissy.
  assert.equal(Model.nearestReportingStation(entries, 49.0, 2.5).icaoId, "LFPG")
  assert.ok(Model.nearestReportingStation(entries, 49.0, 2.5).distanceKm < 15)
  assert.equal(Model.nearestReportingStation([], 49, 2), null)
  assert.equal(Model.nearestReportingStation(entries, null, null), null)
})

test("isUnknownStation separates 204 from a populated response", function () {
  assert.equal(Model.isUnknownStation({ status: 204, entries: [] }), true)
  assert.equal(Model.isUnknownStation({ status: 200, entries: [] }), true)
  assert.equal(Model.isUnknownStation({ status: 200, entries: [{ icaoId: "LFPG" }], requested: "LFPG" }), false)
  // Partial response: the requested code that is missing is unknown.
  assert.equal(Model.isUnknownStation({ status: 200, entries: [{ icaoId: "LFPG" }], requested: "LFPG,ZZZZ" }), true)
})

test("categorySeverity orders the four categories", function () {
  assert.ok(Model.categorySeverity("LIFR") < Model.categorySeverity("IFR"))
  assert.ok(Model.categorySeverity("IFR") < Model.categorySeverity("MVFR"))
  assert.ok(Model.categorySeverity("MVFR") < Model.categorySeverity("VFR"))
  assert.equal(Model.categorySeverity(""), -1)
  assert.equal(Model.categoryColorRole("LIFR"), "lifr")
  assert.equal(Model.categoryColorRole(""), "none")
})

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

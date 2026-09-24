import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything that must exist once, not once per screen.
//
// The shell mounts a `service` plugin exactly once and hands it to views
// through shell.serviceFor(id) — a bar surface, by contrast, is created per
// monitor. Timers and the report cache therefore live here, and the bar pill
// and the popup only render what this holds.
//
// One rule from the security review is load-bearing: every external binary is
// called by absolute path, and every network child runs with a cleared
// environment, so nothing resolves through an inherited PATH.
//
// A second rule, from the marketplace review: the response size cap is enforced
// WHILE the body arrives, not after. Every network request goes through
// requestCommand(), which pipes curl into `head -c maxResponseBytes`, so an
// endpoint cannot make the shell buffer an unbounded body before any check
// runs. A collector that receives the whole body first and then compares its
// length is too late — the memory has already been spent.
Item {
  id: root

  // Injected by the shell when the service is mounted.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.tecknozic.skybrief"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string weatherLocationPath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"

  readonly property string apiBase: "https://aviationweather.gov/api/data"
  readonly property string geocodeUrl: "https://geocoding-api.open-meteo.com/v1/search"

  // Bounds that apply to every request this service makes.
  readonly property int requestTimeoutSec: 20
  readonly property int processTimeoutSec: 25
  readonly property int maxResponseBytes: 524288
  readonly property int maxRequestedStations: 12
  // How far around a geocoded place the station search looks, and how many
  // candidates it offers. One degree is about 110 km, so ±0.6° covers an
  // airport serving a city without dragging in the next region's fields.
  readonly property real searchRadiusDegrees: 0.6
  readonly property int maxSearchResults: 8

  // ---- settings ----------------------------------------------------------

  property var settings: ({})

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // `omarchy bar set <id> showRaw true` writes the STRING "true" into
  // shell.json — the CLI takes a value, not a JSON literal — so a strict
  // `=== true` would read an enabled setting as off and the switch would
  // silently refuse to move.
  function settingBool(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "string") {
      var text = value.trim().toLowerCase()
      if (text === "false" || text === "0" || text === "no" || text === "off" || text === "") return false
      if (text === "true" || text === "1" || text === "yes" || text === "on") return true
      return fallback === true
    }
    return value === true || Number(value) === 1
  }

  readonly property string configuredStation: String(setting("station", "")).trim().toUpperCase()
  readonly property string configuredFir: String(setting("fir", "")).trim().toUpperCase()
  readonly property string units: String(setting("units", "metric"))
  readonly property string timeFormat: String(setting("timeFormat", "utc"))
  readonly property bool showRaw: settingBool("showRaw", true)
  readonly property int refreshMinutes: Math.max(2, Number(setting("refreshMinutes", 10)) || 10)
  readonly property int maxAgeMinutes: Math.max(15, Number(setting("maxAgeMinutes", 75)) || 75)
  readonly property string alertCategory: String(setting("alertCategory", "off"))
  // How far back the METAR request reaches. The API caps a response at six
  // observations per station (measured), so asking for more hours than the
  // trend reads only makes the response bigger, not the trend longer.
  readonly property int historyHours: 3
  readonly property int historyCount: Math.max(0, Math.min(6, Number(setting("historyCount", 3)) || 0))

  // Called by the bar widget on every settings change and at panel open. A
  // settings change that moves the station or the refresh cadence takes effect
  // immediately rather than at the next timer tick.
  function configure(next) {
    var previous = settings
    settings = next && typeof next === "object" ? next : ({})

    var stationMoved = String(previous && previous.station || "").trim().toUpperCase() !== configuredStation
    var firMoved = String(previous && previous.fir || "").trim().toUpperCase() !== configuredFir
    var cadenceMoved = Number(previous && previous.refreshMinutes || 0) !== refreshMinutes

    if (stationMoved || firMoved || cadenceMoved) requestRefresh(true)
  }

  // ---- state -------------------------------------------------------------

  // icaoId -> parsed METAR
  property var reports: ({})
  // icaoId -> earlier parsed METARs, newest first. Kept out of `reports` so
  // nothing that reads one current report can accidentally read a list.
  property var histories: ({})
  property var tafs: ({})
  property var sigmets: []
  property var stationInfo: ({})
  property var runwayInfo: ({})

  // idle | loading | ready | offline | unknown-station | error
  property string status: "idle"
  property string lastError: ""
  property double lastSuccessMs: 0

  // The station actually being reported on: the configured one, or the
  // nearest reporting field resolved from the Omarchy weather location.
  property string resolvedStation: ""
  readonly property string favouriteStation: configuredStation !== "" ? configuredStation : resolvedStation
  property var weatherLocation: ({ name: "", latitude: null, longitude: null })

  // Views bind straight to the state properties below. Every change replaces a
  // property wholesale (`reports = next`, never `reports[code] = ...`), so QML's
  // own change notification carries the update to both the pill and the panel —
  // no manual refresh signal is needed, and an in-place mutation would be the
  // one edit that silently stopped reaching them.

  function stationList() {
    var list = Model.parseStationList(setting("quickStations", ""))
    var favourite = configuredStation
    if (favourite !== "") {
      var withoutFavourite = []
      for (var i = 0; i < list.length; i++) if (list[i] !== favourite) withoutFavourite.push(list[i])
      list = [favourite].concat(withoutFavourite)
    }
    return list.slice(0, maxRequestedStations)
  }

  function reportFor(icao) {
    var code = String(icao || "").toUpperCase()
    return reports[code] || null
  }

  function categoryFor(icao) {
    var report = reportFor(icao)
    return report ? String(report.category || "") : ""
  }

  // The pill's label: one letter per category, distinct fallbacks for the
  // states that are not a category at all.
  function pillLabel() {
    var favourite = favouriteStation
    if (status === "offline") return "!"
    if (status === "idle") return "…"
    if (status === "loading") return favourite && reportFor(favourite) ? categoryLetter(categoryFor(favourite)) : "…"
    if (favourite === "") return "?"
    if (!reportFor(favourite)) return status === "unknown-station" ? "?" : "…"
    var letter = categoryLetter(categoryFor(favourite))
    return letter === "" ? "?" : letter
  }

  function categoryLetter(category) {
    var key = String(category || "").toUpperCase()
    if (key === "VFR") return "V"
    if (key === "MVFR") return "M"
    if (key === "IFR") return "I"
    if (key === "LIFR") return "L"
    return ""
  }

  // ---- refresh -----------------------------------------------------------

  // Bumped by every new refresh. A response that arrives under an older
  // generation is dropped unparsed: a slow SIGMET answer must never overwrite
  // the state a newer refresh just committed.
  property int generation: 0
  property bool metarPending: false
  property bool tafPending: false
  property bool sigmetPending: false
  property bool resolutionPending: false

  function requestRefresh(force) {
    if (force !== true && fetchInFlight()) return
    generation++
    lastError = ""
    if (favouriteStation === "") resolveStation()
    else {
      resolvedStation = configuredStation
      startFetch()
    }
  }

  function fetchInFlight() {
    return metarProc.running || tafProc.running || sigmetProc.running
      || nearestProc.running || geocodeProc.running || searchProc.running
      || searchGeocodeProc.running
  }

  // ---- search by name ----------------------------------------------------
  //
  // The API has no name search: `ids=` takes codes only, and `stationinfo`
  // refuses a name. So a typed name is geocoded to a point, the reporting
  // fields around that point are fetched by bounding box, and the names in the
  // response are matched locally (Model.matchStationsByName). The result is a
  // shortlist to choose from, never an automatic switch of the favourite: a
  // place name is ambiguous in a way an ICAO code is not.

  property var searchResults: []
  property string searchError: ""
  property bool searchPending: false

  function searchByName(query) {
    var text = String(query || "").trim()
    searchResults = []
    searchError = ""
    if (text.length < 3) {
      searchError = "Type at least three characters."
      return
    }
    searchPending = true
    searchGeocodeProc.query = text
    searchGeocodeProc.generation = generation
    searchGeocodeProc.command = requestCommand(geocodeUrl + "?name=" + encodeURIComponent(text)
      + "&count=1&format=json&language=en")
    searchGeocodeProc.running = true
  }

  function clearSearch() {
    searchResults = []
    searchError = ""
    searchPending = false
  }

  // With no station configured the nearest reporting field is used, taken from
  // the Omarchy weather location. Coordinates are exact; a bare name is
  // geocoded through the same service the weather panel uses. Neither being
  // available is an error, never a silent fallback to some arbitrary airport.
  function resolveStation() {
    if (configuredStation !== "") {
      resolvedStation = configuredStation
      startFetch()
      return
    }

    var latitude = Number(weatherLocation && weatherLocation.latitude)
    var longitude = Number(weatherLocation && weatherLocation.longitude)
    if (isFinite(latitude) && isFinite(longitude) && (latitude !== 0 || longitude !== 0)) {
      runBbox(latitude, longitude)
      return
    }

    var name = String(weatherLocation && weatherLocation.name || "").trim()
    if (name !== "") {
      geocodeProc.generation = generation
      geocodeProc.command = requestCommand(geocodeUrl + "?name=" + encodeURIComponent(name) + "&count=1&format=json")
      geocodeProc.running = true
      return
    }

    resolvedStation = ""
    status = "error"
    lastError = "No station configured and no Omarchy weather location known"
  }

  function runBbox(latitude, longitude) {
    var bbox = round3(latitude - 1.5) + "," + round3(longitude - 1.5) + ","
      + round3(latitude + 1.5) + "," + round3(longitude + 1.5)
    nearestProc.generation = generation
    nearestProc.originLat = latitude
    nearestProc.originLon = longitude
    nearestProc.command = requestCommand(apiBase + "/metar?bbox=" + bbox + "&format=json")
    nearestProc.running = true
  }

  // The result of arithmetic on a QML `real` is typed as QJSPrimitiveValue, on
  // which no Number method is visible; routing through a plain function keeps
  // the conversion in the type system. String() trims the trailing zeros the
  // API does not care about anyway.
  function round3(value) {
    return String(Math.round(Number(value) * 1000) / 1000)
  }

  function startFetch() {
    var codes = stationList()
    if (codes.length === 0) {
      status = "error"
      lastError = "No station configured"
      return
    }

    status = "loading"

    metarProc.generation = generation
    metarProc.requested = codes.join(",")
    // `hours` asks for the past observations as well as the current one, in the
    // same request: the trend line needs them, and one response carrying both
    // is cheaper than a second call per station.
    metarProc.command = requestCommand(apiBase + "/metar?ids=" + codes.join(",")
      + "&format=json&hours=" + historyHours)
    metarProc.running = true

    var favourite = favouriteStation
    if (favourite !== "") {
      tafProc.generation = generation
      tafProc.requested = favourite
      tafProc.command = requestCommand(apiBase + "/taf?ids=" + favourite + "&format=json")
      tafProc.running = true
    }

    // No filter parameter works on the SIGMET endpoint (measured: fir=, firId=,
    // bbox= and ids= all return the whole list), so the full list is fetched
    // and narrowed here. It is the slowest call of the set, and its failure is
    // deliberately not fatal to the station status.
    sigmetProc.generation = generation
    sigmetProc.command = requestCommand(apiBase + "/isigmet?format=json")
    sigmetProc.running = true
  }

  // Every network request is bounded while its body is being received.
  //
  // `head -c` closes the pipe the moment the cap is reached, so curl's write
  // fails and it exits 23 instead of buffering an unbounded body — the memory
  // is never spent. `pipefail` makes that 23 (or curl's own 6/22/28) the exit
  // status of the whole pipeline rather than head's success. `--` ends curl's
  // options so a URL can never be read as a flag, and the URL is passed as a
  // positional argument, never interpolated into the shell string.
  readonly property int curlOverflowExitCode: 23

  function requestCommand(url) {
    return ["/usr/bin/bash", "-o", "pipefail", "-c",
      "/usr/bin/timeout \"$1\" /usr/bin/curl -fsS --max-time \"$2\" -- \"$3\""
        + " | /usr/bin/head -c \"$4\"",
      "skybrief-request",
      String(processTimeoutSec), String(requestTimeoutSec), String(url), String(maxResponseBytes)]
  }

  // A body that hit the cap is not a network failure and must read as its own
  // thing: "too large to use" is actionable, "unreachable" is not.
  function isOverflowExit(code) {
    return code === curlOverflowExitCode
  }

  function overflowMessage(kind) {
    return kind + ": response exceeded " + Math.round(maxResponseBytes / 1024)
      + " KiB and was cut off"
  }

  function parseEntries(raw) {
    var text = String(raw || "").trim()
    if (text === "") return []
    try {
      var data = JSON.parse(text)
      return Array.isArray(data) ? data : []
    } catch (e) {
      return []
    }
  }

  function commitMetar(raw, requestGeneration) {
    if (requestGeneration !== generation) return
    var entries = parseEntries(raw)
    var requested = Model.parseStationList(metarProc.requested)

    // The response carries every station's window of observations interleaved
    // (newest report first, then each station's earlier ones). The newest entry
    // per station is the current report; the rest is that station's history.
    var next = ({})
    var nextHistories = ({})
    for (var existing in reports) next[existing] = reports[existing]

    var byStation = ({})
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!entry || !entry.icaoId) continue
      var code = String(entry.icaoId).toUpperCase()
      if (!byStation[code]) byStation[code] = []
      byStation[code].push(entry)
    }

    for (var station in byStation) {
      var forStation = byStation[station]
      // Newest wins rather than "first in the array wins": the API happens to
      // interleave newest-first today, but ordering by the timestamp we already
      // parse costs nothing and does not depend on that.
      var current = null
      for (var s = 0; s < forStation.length; s++) {
        var parsed = Model.parseMetar(forStation[s])
        if (!parsed || parsed.obsTime === null) continue
        if (!current || parsed.obsTime > current.obsTime) current = parsed
      }
      if (!current) continue
      Model.markStale(current, maxAgeMinutes, Date.now())
      next[current.icaoId] = current
      nextHistories[current.icaoId] = Model.metarHistory(forStation, current.obsTime, historyCount)
    }
    reports = next
    histories = nextHistories

    var favourite = favouriteStation
    lastSuccessMs = Date.now()

    if (favourite === "") {
      status = entries.length ? "ready" : "unknown-station"
      lastError = entries.length ? "" : "No reporting station found near the configured location"
      return
    }

    // A code that is absent from a response — including the empty `204` body
    // the API returns when every code is unknown — is "station unknown". That
    // is a different state from "offline" and must never be conflated with it.
    var present = {}
    for (var j = 0; j < entries.length; j++) {
      if (entries[j] && entries[j].icaoId) present[String(entries[j].icaoId).toUpperCase()] = true
    }
    if (!present[favourite]) {
      status = "unknown-station"
      lastError = requested.length ? "Station " + favourite + " has no observation" : ""
      return
    }

    status = "ready"
    lastError = ""
    requestStationInfo(favourite)
    // Runway metadata is only ever read by the detail view, but it is fetched
    // with the report that produces the crosswind numbers: a request made when
    // the view opens would show an empty table behind a click.
    requestRunways(favourite)
    announceIfSevere(favourite)
  }

  function commitTaf(raw, requestGeneration) {
    if (requestGeneration !== generation) return
    var entries = parseEntries(raw)
    if (!entries.length) return
    var parsed = Model.parseTaf(entries[0])
    if (!parsed) return
    var next = ({})
    for (var existing in tafs) next[existing] = tafs[existing]
    next[parsed.icaoId] = parsed
    tafs = next
  }

  function commitSigmet(raw, requestGeneration) {
    if (requestGeneration !== generation) return
    var entries = parseEntries(raw)
    sigmets = entries
  }

  // FIR-narrowed SIGMETs for the detail view. The endpoint has no working
  // filter, so the whole list is already in hand.
  function sigmetsForFir() {
    var fir = configuredFir
    if (fir === "" || !Array.isArray(sigmets)) return []
    var out = []
    for (var i = 0; i < sigmets.length; i++) {
      var entry = sigmets[i]
      if (!entry) continue
      if (String(entry.firId || "").toUpperCase() === fir) out.push(entry)
    }
    return out
  }

  property var stationInfoRequested: ({})
  property var runwayInfoRequested: ({})

  // Station metadata is fetched once per code per session and cached.
  function requestStationInfo(code) {
    if (code === "" || stationInfoRequested[code] === true) return
    markRequested("station", code)
    infoProc.generation = generation
    infoProc.code = code
    infoProc.command = requestCommand(apiBase + "/stationinfo?ids=" + code + "&format=json")
    infoProc.running = true
  }

  function requestRunways(code) {
    if (code === "" || runwayInfoRequested[code] === true) return
    markRequested("runway", code)
    runwayProc.generation = generation
    runwayProc.code = code
    runwayProc.command = requestCommand(apiBase + "/airport?ids=" + code + "&format=json")
    runwayProc.running = true
  }

  // Object properties are replaced, not mutated: an in-place write through a
  // `var` property does not notify, so a plain assignment would silently leave
  // the guard unreadable to any binding that looked at it.
  function markRequested(kind, code) {
    var next = ({})
    var source = kind === "station" ? stationInfoRequested : runwayInfoRequested
    for (var existing in source) next[existing] = source[existing]
    next[code] = true
    if (kind === "station") stationInfoRequested = next
    else runwayInfoRequested = next
  }

  function runwaysFor(code) {
    var entry = runwayInfo[String(code || "").toUpperCase()]
    if (!entry || !Array.isArray(entry.runways)) return []
    return entry.runways
  }

  // Earlier observations of one station, newest first, excluding the current
  // one. Empty when the trend is switched off or the station is too new.
  function historyFor(code) {
    var list = histories[String(code || "").toUpperCase()]
    return Array.isArray(list) ? list : []
  }

  // ---- network children --------------------------------------------------

  function handleFailure(kind, code, streamText) {
    // curl's own message is the useful part: DNS failure, TLS failure and HTTP
    // errors are all exit codes here, and a bare number would say nothing.
    var detail = String(streamText || "").trim()
    if (detail.length > 200) detail = detail.slice(0, 200)
    // An oversized body is not a reachability problem: the endpoint answered,
    // the answer was simply unusable, and saying so is more actionable than
    // reporting curl's pipe code.
    if (isOverflowExit(code)) detail = overflowMessage(kind).replace(kind + ": ", "")
    if (detail === "") detail = "exit " + code
    lastError = kind + ": " + detail
    status = "offline"
    retryTimer.restart()
  }

  Process {
    id: metarProc
    property int generation: 0
    property string requested: ""
    command: []
    clearEnvironment: true
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.commitMetar(text, metarProc.generation)
      }
    }
    stderr: StdioCollector { id: metarErr; waitForEnd: true }
    onExited: function(code) {
      if (code === 0) return
      if (metarProc.generation !== root.generation) return
      root.handleFailure("METAR unavailable", code, metarErr.text)
    }
  }

  Process {
    id: tafProc
    property int generation: 0
    property string requested: ""
    command: []
    clearEnvironment: true
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.commitTaf(text, tafProc.generation)
      }
    }
    onExited: function(code) {
      // A missing TAF leaves the METAR view intact: it is a secondary product,
      // so its failure is recorded without demoting the station status.
      if (code === 0 || tafProc.generation !== root.generation || root.status !== "ready") return
      root.lastError = root.isOverflowExit(code)
        ? root.overflowMessage("TAF unavailable")
        : "TAF unavailable (exit " + code + ")"
    }
  }

  Process {
    id: sigmetProc
    property int generation: 0
    command: []
    clearEnvironment: true
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.commitSigmet(text, sigmetProc.generation)
      }
    }
    // Observed >20 s on a good connection, and a SIGMET failure must not take
    // the station down with it: the section reports its own error.
    onExited: function(code) {
      if (code !== 0 && sigmetProc.generation === root.generation)
        root.sigmetError = root.isOverflowExit(code)
          ? root.overflowMessage("SIGMET feed")
          : "SIGMET feed unavailable (exit " + code + ")"
      else if (code === 0)
        root.sigmetError = ""
    }
  }

  property string sigmetError: ""

  Process {
    id: nearestProc
    property int generation: 0
    property real originLat: 0
    property real originLon: 0
    command: []
    clearEnvironment: true
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (nearestProc.generation !== root.generation) return
        var entries = root.parseEntries(text)
        var nearest = Model.nearestReportingStation(entries, nearestProc.originLat, nearestProc.originLon)
        if (!nearest || !nearest.icaoId) {
          root.status = "error"
          root.lastError = "No reporting station within range of the configured location"
          return
        }
        root.resolvedStation = String(nearest.icaoId).toUpperCase()
        root.startFetch()
      }
    }
    onExited: function(code) {
      if (code === 0) return
      if (nearestProc.generation !== root.generation) return
      root.handleFailure("Station lookup failed", code, "")
    }
  }

  Process {
    id: geocodeProc
    property int generation: 0
    command: []
    clearEnvironment: true
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (geocodeProc.generation !== root.generation) return
        var latitude = NaN
        var longitude = NaN
        try {
          var data = JSON.parse(String(text || "").trim())
          var result = data && Array.isArray(data.results) ? data.results[0] : null
          if (result) {
            latitude = Number(result.latitude)
            longitude = Number(result.longitude)
          }
        } catch (e) {
          latitude = NaN
        }
        if (!isFinite(latitude) || !isFinite(longitude)) {
          root.status = "error"
          root.lastError = "Could not locate " + String(root.weatherLocation.name || "")
          return
        }
        root.runBbox(latitude, longitude)
      }
    }
    onExited: function(code) {
      if (code === 0) return
      if (geocodeProc.generation !== root.generation) return
      root.handleFailure("Geocoding failed", code, "")
    }
  }

  // The name search reuses the same geocoder as the nearest-station fallback,
  // but keeps its own process: sharing geocodeProc would cancel an in-flight
  // location lookup the moment the user typed a search.
  Process {
    id: searchGeocodeProc
    property int generation: 0
    property string query: ""
    command: []
    clearEnvironment: true
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (searchGeocodeProc.generation !== root.generation) return
        var latitude = NaN
        var longitude = NaN
        try {
          var data = JSON.parse(String(text || "").trim())
          var result = data && Array.isArray(data.results) ? data.results[0] : null
          if (result) {
            latitude = Number(result.latitude)
            longitude = Number(result.longitude)
          }
        } catch (e) {
          latitude = NaN
        }
        if (!isFinite(latitude) || !isFinite(longitude)) {
          root.searchPending = false
          root.searchError = "No place called \"" + searchGeocodeProc.query + "\"."
          return
        }
        searchProc.generation = root.generation
        searchProc.query = searchGeocodeProc.query
        searchProc.command = root.requestCommand(root.apiBase + "/metar?bbox="
          + root.round3(latitude - searchRadiusDegrees) + "," + root.round3(longitude - searchRadiusDegrees) + ","
          + root.round3(latitude + searchRadiusDegrees) + "," + root.round3(longitude + searchRadiusDegrees)
          + "&format=json")
        searchProc.running = true
      }
    }
    onExited: function(code) {
      if (code === 0) return
      if (searchGeocodeProc.generation !== root.generation) return
      root.searchPending = false
      root.searchError = "Could not search for \"" + searchGeocodeProc.query + "\"."
    }
  }

  Process {
    id: searchProc
    property int generation: 0
    property string query: ""
    command: []
    clearEnvironment: true
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (searchProc.generation !== root.generation) return
        var entries = root.parseEntries(text)
        var matches = Model.matchStationsByName(entries, searchProc.query, maxSearchResults)
        root.searchResults = matches
        root.searchPending = false
        root.searchError = matches.length
          ? ""
          : "No reporting station near \"" + searchProc.query + "\". A nearby airfield may be under a different name."
      }
    }
    onExited: function(code) {
      if (code === 0) return
      if (searchProc.generation !== root.generation) return
      root.searchPending = false
      root.searchError = root.isOverflowExit(code)
        ? root.overflowMessage("Station search")
        : "Station search failed."
    }
  }

  Process {
    id: infoProc
    property int generation: 0
    property string code: ""
    property string kind: ""
    command: []
    clearEnvironment: true
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var entries = root.parseEntries(text)
        if (!entries.length) return
        var next = ({})
        for (var existing in root.stationInfo) next[existing] = root.stationInfo[existing]
        var entry = entries[0]
        next[infoProc.code] = {
          name: String(entry.site || entry.name || ""),
          country: String(entry.country || ""),
          elevationFt: Number(entry.elev)
        }
        root.stationInfo = next
      }
    }
  }

  Process {
    id: runwayProc
    property int generation: 0
    property string code: ""
    command: []
    clearEnvironment: true
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var entries = root.parseEntries(text)
        if (!entries.length) return
        var runways = []
        var raw = entries[0] && Array.isArray(entries[0].runways) ? entries[0].runways : []
        for (var i = 0; i < raw.length; i++) {
          var runway = raw[i]
          if (!runway) continue
          var alignment = Number(runway.alignment)
          if (!isFinite(alignment)) continue
          runways.push({
            id: String(runway.id || ""),
            alignment: alignment,
            dimension: String(runway.dimension || ""),
            surface: String(runway.surface || "")
          })
        }
        var next = ({})
        for (var existing in root.runwayInfo) next[existing] = root.runwayInfo[existing]
        next[runwayProc.code] = { runways: runways }
        root.runwayInfo = next
      }
    }
  }

  // ---- alerting ----------------------------------------------------------

  // One notification per (station, observation). Re-announcing the same report
  // every refresh cycle would be worse than not announcing it at all.
  property var announced: ({})

  function announceIfSevere(icao) {
    if (alertCategory === "off" || alertCategory === "") return
    var report = reportFor(icao)
    if (!report) return

    var threshold = Model.categorySeverity(alertCategory)
    if (threshold < 0) return
    var severity = Model.categorySeverity(report.category)
    if (severity < 0 || severity > threshold) return

    var key = String(icao) + "@" + String(report.reportTime || report.obsTime || "")
    if (announced[key] === true) return
    var next = ({})
    for (var existing in announced) next[existing] = announced[existing]
    next[key] = true
    announced = next

    var detail = ""
    if (report.ceilingFt !== null && report.ceilingFt !== undefined)
      detail += "ceiling " + Math.round(report.ceilingFt) + " ft"
    if (report.visibility && report.visibility.meters !== null) {
      if (detail !== "") detail += ", "
      detail += "visibility " + Model.formatVisibility(report.visibility, units)
    }
    if (detail === "") detail = Model.formatWind(report, units)

    notifyProc.command = ["/usr/bin/omarchy-notification-send", "-u", "normal",
      "-i", "weather-few-clouds",
      String(icao) + " " + String(report.category || ""), detail]
    notifyProc.running = true
  }

  // The notification daemon is reached over the session bus, so its child needs
  // the bus address and the runtime dir even though everything else is cleared.
  // They are read out of the shell's own environment and named explicitly
  // rather than inherited, so PATH still plays no part in what the child sees.
  readonly property var notifyEnvironment: ({
    "PATH": "/usr/bin:/bin",
    "XDG_RUNTIME_DIR": String(Quickshell.env("XDG_RUNTIME_DIR") || ""),
    "DBUS_SESSION_BUS_ADDRESS": String(Quickshell.env("DBUS_SESSION_BUS_ADDRESS") || "")
  })

  Process {
    id: notifyProc
    command: []
    running: false
    clearEnvironment: true
    environment: root.notifyEnvironment
  }

  // ---- timers ------------------------------------------------------------

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60000
    repeat: true
    triggeredOnStart: true
    onTriggered: root.requestRefresh(true)
  }

  // A resume after suspend commonly fails the first request because the Wi-Fi
  // has not reassociated yet. One short retry avoids a full refresh interval of
  // showing a stale report as though it were current.
  Timer {
    id: retryTimer
    interval: 30000
    repeat: false
    onTriggered: root.requestRefresh(true)
  }

  Timer {
    id: staleTimer
    interval: 60000
    repeat: true
    running: true
    onTriggered: {
      // Age is a function of the clock, not of the network: a report crosses
      // the staleness line on its own even if no request succeeds.
      var now = Date.now()
      var next = ({})
      var changed = false
      for (var code in root.reports) {
        var report = root.reports[code]
        if (!report) continue
        var wasStale = report.stale === true
        Model.markStale(report, root.maxAgeMinutes, now)
        next[code] = report
        if (report.stale !== wasStale) changed = true
      }
      if (changed) {
        root.reports = next
      }
    }
  }

  property FileView weatherLocationFile: FileView {
    path: root.weatherLocationPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.weatherLocation = root.parseWeatherLocation(text())
    onLoadFailed: root.weatherLocation = root.parseWeatherLocation("")
  }

  function parseWeatherLocation(raw) {
    var unset = { name: "", latitude: null, longitude: null }
    try {
      var data = JSON.parse(String(raw || ""))
      if (!data || typeof data !== "object") return unset
      var latitude = parseFloat(data.latitude)
      var longitude = parseFloat(data.longitude)
      var hasCoordinates = isFinite(latitude) && isFinite(longitude)
      return {
        name: typeof data.name === "string" ? data.name.replace(/^\s+|\s+$/g, "") : "",
        latitude: hasCoordinates ? latitude : null,
        longitude: hasCoordinates ? longitude : null
      }
    } catch (e) {
      return unset
    }
  }

  // The first read can race shell startup, the same way the weather panel's
  // does; one delayed reload self-corrects a missed location.
  Timer {
    interval: 1500
    running: true
    onTriggered: root.weatherLocationFile.reload()
  }

  // Views call this when they open: a popup showing a ten-minute-old report
  // when the panel is open in front of you is not worth the request saved.
  function notifyOpened() {
    requestRefresh(true)
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "Autorouter.js" as Autorouter

// Everything that must exist once, not once per screen.
//
// The shell mounts a `service` plugin exactly once and hands it to views
// through shell.serviceFor(id) — a bar surface, by contrast, is created per
// monitor. Timers, the report cache and the autorouter credentials therefore
// live here, and the bar pill and the popup only render what this holds.
//
// Two rules from the security review are load-bearing:
//   * every external binary is called by absolute path, and every network
//     child runs with a cleared environment, so nothing resolves through an
//     inherited PATH;
//   * the autorouter client secret is written on a child's stdin, never in
//     argv, where `ps` and the shell history would both show it.
Item {
  id: root

  // Injected by the shell when the service is mounted.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.tecknozic.skybrief"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/skybrief"
  readonly property string credentialPath: stateDir + "/autorouter.json"
  readonly property string weatherLocationPath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"

  readonly property string apiBase: "https://aviationweather.gov/api/data"
  readonly property string geocodeUrl: "https://geocoding-api.open-meteo.com/v1/search"

  // Bounds that apply to every request this service makes.
  readonly property int requestTimeoutSec: 20
  readonly property int processTimeoutSec: 25
  readonly property int maxResponseBytes: 524288
  readonly property int maxRequestedStations: 12

  // ---- settings ----------------------------------------------------------

  property var settings: ({})

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string configuredStation: String(setting("station", "")).trim().toUpperCase()
  readonly property string configuredFir: String(setting("fir", "")).trim().toUpperCase()
  readonly property string units: String(setting("units", "metric"))
  readonly property string timeFormat: String(setting("timeFormat", "utc"))
  readonly property bool showRaw: setting("showRaw", true) === true
  readonly property int refreshMinutes: Math.max(2, Number(setting("refreshMinutes", 10)) || 10)
  readonly property int maxAgeMinutes: Math.max(15, Number(setting("maxAgeMinutes", 75)) || 75)
  readonly property string alertCategory: String(setting("alertCategory", "off"))
  readonly property string notamSource: String(setting("notamSource", "off"))
  readonly property int notamLimit: Math.max(5, Math.min(100, Number(setting("notamLimit", 40)) || 40))

  // Called by the bar widget on every settings change and at panel open. A
  // settings change that moves the station or the refresh cadence takes effect
  // immediately rather than at the next timer tick.
  function configure(next) {
    var previous = settings
    settings = next && typeof next === "object" ? next : ({})

    var stationMoved = String(previous && previous.station || "").trim().toUpperCase() !== configuredStation
    var firMoved = String(previous && previous.fir || "").trim().toUpperCase() !== configuredFir
    var cadenceMoved = Number(previous && previous.refreshMinutes || 0) !== refreshMinutes
    var notamMoved = String(previous && previous.notamSource || "") !== notamSource

    if (stationMoved || firMoved || cadenceMoved || notamMoved) requestRefresh(true)
  }

  // ---- state -------------------------------------------------------------

  // icaoId -> parsed METAR
  property var reports: ({})
  property var tafs: ({})
  property var sigmets: []
  property var notams: ({ forStation: [], forFir: [] })
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

  // ---- credentials -------------------------------------------------------

  property var credential: ({})

  readonly property bool hasCredentials: String(credential && credential.user || "") !== ""
    && String(credential && credential.password || "") !== ""
  readonly property bool notamsEnabled: notamSource === "autorouter"

  property FileView credentialFile: FileView {
    path: root.credentialPath
    watchChanges: false
    printErrors: false
    onLoaded: root.credential = root.parseCredential(text())
    onLoadFailed: root.credential = ({})
  }

  function parseCredential(raw) {
    try {
      var data = JSON.parse(String(raw || ""))
      if (!data || typeof data !== "object") return ({})
      return {
        user: typeof data.user === "string" ? data.user : "",
        password: typeof data.password === "string" ? data.password : ""
      }
    } catch (e) {
      return ({})
    }
  }

  // The credentials file must never be created world-readable, and the secret
  // must never be visible in `ps`. `/usr/bin/install -D -m 600 /dev/stdin`
  // creates the directory and the file with mode 0600 from stdin in one step —
  // verified on this machine before being relied on here.
  function saveCredentials(user, password) {
    if (String(user || "").trim() === "" || String(password || "") === "") {
      lastError = "Both the autorouter user and password are required"
      return false
    }
    credentialWrite.payload = JSON.stringify({ user: String(user), password: String(password) }) + "\n"
    credentialWrite.running = true
    return true
  }

  function clearCredentials() {
    credentialRemove.running = true
  }

  property string credentialPayload: ""

  Process {
    id: credentialWrite
    property string payload: ""
    command: ["/usr/bin/install", "-D", "-m", "600", "/dev/stdin", root.credentialPath]
    clearEnvironment: true
    stdinEnabled: true
    running: false
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      credentialWrite.write(credentialWrite.payload)
      credentialWrite.stdinEnabled = false
    }
    onExited: function(code) {
      credentialWrite.stdinEnabled = true
      if (code !== 0) {
        root.lastError = "Could not save the autorouter credentials (exit " + code + ")"
        return
      }
      root.credentialFile.reload()
      root.tokenState = ({ token: "", expiresAtMs: 0 })
      root.lastError = ""
      root.requestRefresh(true)
    }
  }

  Process {
    id: credentialRemove
    command: ["/usr/bin/rm", "-f", root.credentialPath]
    clearEnvironment: true
    running: false
    onExited: function() {
      root.credential = ({})
      root.tokenState = ({ token: "", expiresAtMs: 0 })
      root.notams = ({ forStation: [], forFir: [] })
      root.requestRefresh(true)
    }
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

  property var tokenState: ({ token: "", expiresAtMs: 0 })

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
      || nearestProc.running || geocodeProc.running
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
    metarProc.command = requestCommand(apiBase + "/metar?ids=" + codes.join(",") + "&format=json")
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

    if (notamsEnabled && hasCredentials) refreshNotams()
    else if (notamsEnabled) fetchNotamStateNotNeeded()
  }

  function fetchNotamStateNotNeeded() {
    notams = ({ forStation: [], forFir: [] })
  }

  function requestCommand(url) {
    return ["/usr/bin/timeout", String(processTimeoutSec), "/usr/bin/curl",
      "-fsS", "--max-time", String(requestTimeoutSec), url]
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

    var next = ({})
    for (var existing in reports) next[existing] = reports[existing]
    for (var i = 0; i < entries.length; i++) {
      var parsed = Model.parseMetar(entries[i])
      if (!parsed) continue
      Model.markStale(parsed, maxAgeMinutes, Date.now())
      next[parsed.icaoId] = parsed
    }
    reports = next

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

  // ---- autorouter --------------------------------------------------------

  property bool notamPending: false
  // Kept separate from `lastError`: a NOTAM failure must not blank the weather
  // card, and the NOTAM section must not claim "none in force" when the query
  // never succeeded.
  property string notamError: ""

  function refreshNotams() {
    var codes = []
    if (favouriteStation !== "") codes.push(favouriteStation)
    if (configuredFir !== "") codes.push(configuredFir)
    if (codes.length === 0) return

    var now = Date.now()
    if (Autorouter.tokenIsUsable(tokenState, now)) {
      requestNotamRows(tokenState.token)
      return
    }

    tokenProc.generation = generation
    tokenProc.payload = Autorouter.tokenRequestConfig(credential.user, credential.password)
    tokenProc.running = true
  }

  function requestNotamRows(token) {
    var codes = []
    if (favouriteStation !== "") codes.push(favouriteStation)
    if (configuredFir !== "") codes.push(configuredFir)
    notamProc.generation = generation
    notamProc.requestedIcao = favouriteStation
    notamProc.requestedFir = configuredFir
    notamProc.payload = Autorouter.notamRequestConfig(token, codes, notamLimit)
    notamProc.running = true
    notamPending = true
  }

  Process {
    id: tokenProc
    property string payload: ""
    property int generation: 0
    property bool reported: false
    // --fail-with-body, not plain --fail: autorouter answers an invalid client
    // with HTTP 403 and a JSON body naming the reason. Plain --fail would throw
    // that body away and leave the user with "exit 22", which says nothing.
    command: ["/usr/bin/timeout", String(root.processTimeoutSec), "/usr/bin/curl",
      "-fsS", "--fail-with-body", "--max-time", String(root.requestTimeoutSec), "-K", "-"]
    clearEnvironment: true
    stdinEnabled: true
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (tokenProc.generation !== root.generation) return
        if (String(text || "").length > root.maxResponseBytes) return
        var parsed = Autorouter.parseTokenResponse(text)
        if (parsed.error || !parsed.token) {
          tokenProc.reported = true
          root.notamError = "autorouter sign-in failed — " + String(parsed.error || "no token")
          root.notamPending = false
          return
        }
        root.notamError = ""
        var expiresIn = parsed.expiresInSec === null ? 3600 : parsed.expiresInSec
        root.tokenState = { token: parsed.token, expiresAtMs: Date.now() + expiresIn * 1000 }
        root.requestNotamRows(parsed.token)
      }
    }
    onStarted: {
      tokenProc.reported = false
      tokenProc.write(tokenProc.payload)
      tokenProc.stdinEnabled = false
    }
    onExited: function(code) {
      tokenProc.stdinEnabled = true
      if (tokenProc.generation !== root.generation) return
      if (tokenProc.reported) return
      if (code === 0) return
      root.notamPending = false
      root.notamError = "autorouter is unreachable (curl exit " + code + ")"
    }
  }

  Process {
    id: notamProc
    property string payload: ""
    property int generation: 0
    property string requestedIcao: ""
    property string requestedFir: ""
    property bool reported: false
    command: ["/usr/bin/timeout", String(root.processTimeoutSec), "/usr/bin/curl",
      "-fsS", "--fail-with-body", "--max-time", String(root.requestTimeoutSec), "-K", "-"]
    clearEnvironment: true
    stdinEnabled: true
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (notamProc.generation !== root.generation) return
        root.notamPending = false
        if (String(text || "").length > root.maxResponseBytes) return
        var parsed = Autorouter.parseNotamResponse(text)
        if (parsed.error) {
          notamProc.reported = true
          root.notamError = "NOTAM query rejected — " + parsed.error
          return
        }
        var rows = []
        for (var i = 0; i < parsed.rows.length; i++) {
          var row = Autorouter.formatNotamRow(parsed.rows[i], root.timeFormat)
          if (row) rows.push(row)
        }
        rows = Autorouter.sortNotamRows(rows, Date.now())
        root.notams = Autorouter.filterNotamRows(rows, {
          icao: notamProc.requestedIcao,
          fir: notamProc.requestedFir
        })
        root.notamError = ""
      }
    }
    onStarted: {
      notamProc.reported = false
      notamProc.write(notamProc.payload)
      notamProc.stdinEnabled = false
    }
    onExited: function(code) {
      notamProc.stdinEnabled = true
      if (notamProc.generation !== root.generation) return
      if (notamProc.reported) return
      if (code === 0) return
      root.notamPending = false
      root.notamError = "NOTAM query failed (curl exit " + code + ")"
    }
  }

  // ---- network children --------------------------------------------------

  function handleFailure(kind, code, streamText) {
    // curl's own message is the useful part: DNS failure, TLS failure and HTTP
    // errors are all exit codes here, and a bare number would say nothing.
    var detail = String(streamText || "").trim()
    if (detail.length > 200) detail = detail.slice(0, 200)
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
        if (String(text || "").length > root.maxResponseBytes) return
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
        if (String(text || "").length > root.maxResponseBytes) return
        root.commitTaf(text, tafProc.generation)
      }
    }
    onExited: function(code) {
      // A missing TAF leaves the METAR view intact: it is a secondary product,
      // so its failure is recorded without demoting the station status.
      if (code !== 0 && tafProc.generation === root.generation && root.status === "ready")
        root.lastError = "TAF unavailable (exit " + code + ")"
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
        if (String(text || "").length > root.maxResponseBytes) return
        root.commitSigmet(text, sigmetProc.generation)
      }
    }
    // Observed >20 s on a good connection, and a SIGMET failure must not take
    // the station down with it: the section reports its own error.
    onExited: function(code) {
      if (code !== 0 && sigmetProc.generation === root.generation)
        root.sigmetError = "SIGMET feed unavailable (exit " + code + ")"
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
        if (String(text || "").length > root.maxResponseBytes) return
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
        if (String(text || "").length > root.maxResponseBytes) return
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
        if (String(text || "").length > root.maxResponseBytes) return
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
        if (String(text || "").length > root.maxResponseBytes) return
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

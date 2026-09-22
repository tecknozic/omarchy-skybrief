import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The popup: a compact flight-weather card, and — behind the Details button —
// the full decoded report with wind components, cloud layers, SIGMETs and
// NOTAMs.
//
// `expanded` is a view state, not a second window: the same KeyboardPanel grows
// and its content column swaps. One escape key, one focus target, one popout
// identity.
Panel {
  id: root
  moduleName: "io.github.tecknozic.skybrief"
  // The bar widget already owns the IPC target; a second handler for the same
  // target would be a second answer to the same question.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // The bar identifies a panel by its bar widget, not by this nested item.
  readonly property var barIdentity: hostWidget || root

  // Aviation flight-category colours — a code, not a decoration. The same table
  // lives in BarWidget.qml.
  readonly property var categoryColors: ({
    vfr: "#4fbf5f",
    mvfr: "#4f8fdd",
    ifr: "#e0503f",
    lifr: "#d05fd0"
  })

  readonly property var service: root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function"
    ? root.bar.shell.serviceFor(root.moduleName)
    : null

  property bool expanded: false
  property string credentialUser: ""
  property string credentialPassword: ""
  property string copyNote: ""
  property string expandedNotam: ""

  readonly property string station: root.service ? String(root.service.favouriteStation || "") : ""
  readonly property var report: root.service ? root.service.reportFor(root.station) : null
  readonly property var taf: root.service ? root.service.tafs[root.station] || null : null
  readonly property string status: root.service ? String(root.service.status || "idle") : "idle"
  readonly property string lastError: root.service ? String(root.service.lastError || "") : ""
  readonly property string units: root.service ? root.service.units : "metric"
  readonly property string timeFormat: root.service ? root.service.timeFormat : "utc"
  readonly property bool showRaw: root.service ? root.service.showRaw : true
  readonly property bool notamsEnabled: root.service ? root.service.notamsEnabled : false
  readonly property bool hasCredentials: root.service ? root.service.hasCredentials : false
  readonly property string notamSource: root.service ? root.service.notamSource : "off"
  readonly property string configuredFir: root.service ? root.service.configuredFir : ""
  readonly property var notams: root.service ? root.service.notams : ({ forStation: [], forFir: [] })
  readonly property var sigmets: root.service ? root.service.sigmetsForFir() : []
  readonly property string sigmetError: root.service ? String(root.service.sigmetError || "") : ""
  readonly property string notamError: root.service ? String(root.service.notamError || "") : ""
  readonly property bool notamPending: root.service ? root.service.notamPending === true : false
  readonly property var stationMeta: root.service ? root.service.stationInfo[root.station] || null : null
  readonly property var runways: root.service ? root.service.runwaysFor(root.station) : []
  readonly property string category: report ? String(report.category || "") : ""
  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color categoryColor: {
    var role = Model.categoryColorRole(category)
    return categoryColors[role] !== undefined ? categoryColors[role] : root.foreground
  }
  readonly property color dim: Qt.darker(root.foreground, 1.4)

  readonly property string heroTitle: station !== "" ? station : "SkyBrief"
  readonly property string heroMeta: {
    if (!report) return status === "offline" ? "OFFLINE" : "NO REPORT"
    var name = stationMeta && stationMeta.name ? stationMeta.name : (report.name || "")
    var observed = Model.formatObsTime(report.obsTime, timeFormat)
    return name !== "" ? name + " · " + observed : observed
  }

  // ---- state and actions -------------------------------------------------

  function open() {
    root.expanded = false
    root.controller.show()
    refresh()
  }

  function openFromHotkey() {
    root.controller.show()
    refresh()
  }

  function close() {
    root.copyNote = ""
    root.expandedNotam = ""
    root.controller.hide()
  }

  function refresh() {
    if (root.service) root.service.requestRefresh(true)
  }

  // Settings writes go through the shell so the choice survives a restart.
  // The whole entry is merged, never replaced: writing one key must not drop
  // the others.
  function writeSetting(key, value) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    var source = root.settings || {}
    for (var existing in source) if (existing !== "id") entry[existing] = source[existing]
    entry[key] = value
    root.settings = entry
    bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function chooseStation(code) {
    var icao = String(code || "").trim().toUpperCase()
    if (!/^[A-Z0-9]{4}$/.test(icao)) return
    writeSetting("station", icao)
    refresh()
  }

  function addToQuickList(code) {
    var icao = String(code || "").trim().toUpperCase()
    if (!/^[A-Z0-9]{4}$/.test(icao)) return
    var list = Model.parseStationList(root.settings ? root.settings.quickStations : "")
    if (list.indexOf(icao) === -1) list.push(icao)
    writeSetting("quickStations", list.join(","))
  }

  function copy(text) {
    if (String(text || "") === "") return
    Quickshell.clipboardText = String(text)
    root.copyNote = "Copied"
    copyNoteTimer.restart()
  }

  function saveCredentials() {
    if (root.service) root.service.saveCredentials(root.credentialUser, root.credentialPassword)
    root.credentialPassword = ""
  }

  readonly property string quickStations: service ? service.stationList().join(",") : ""

  Timer {
    id: copyNoteTimer
    interval: 2200
    onTriggered: root.copyNote = ""
  }

  // A popup showing a ten-minute-old report when it is open in front of you is
  // not worth the request saved; opening refreshes.
  onOpenedChanged: if (opened) refresh()

  // ---- layout ------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.expanded ? 720 : 380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a text field has the keyboard, the panel must not steal keys.
      blocked: searchField.activeFocus || userField.activeFocus || passwordField.activeFocus
      onCloseRequested: root.expanded ? root.expanded = false : root.close()
      onTextKey: function(text) {
        if (text === "r") root.refresh()
        else if (text === "d") root.expanded = !root.expanded
        else if (text === "c" && root.report) root.copy(root.report.raw)
      }
      // Arrows and j/k scroll the card. The panel is reachable by keyboard, so
      // the detail view must be readable without a mouse.
      onMoveRequested: function(dx, dy) {
        var step = Style.space(48)
        if (dy !== 0) scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height,
          scroll.contentY + dy * step))
        if (dx !== 0) scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height,
          scroll.contentY + dx * step))
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroll.width
          spacing: Style.space(14)

          // ---- header ----------------------------------------------------

          PanelHero {
            id: hero
            width: parent.width
            title: root.heroTitle
            meta: root.heroMeta
            detail: root.category
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: root.status === "offline" || root.status === "error" ? "󰅖"
                  : (root.status === "unknown-station" ? "󰋼" : "󰖐")
                color: root.category !== "" ? root.categoryColor : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // A stale report is never presented as a current one.
          Text {
            visible: !!(root.report && root.report.stale)
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: "Observation is older than " + (service ? service.maxAgeMinutes : 0)
              + " minutes — it has not been refreshed since."
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // An error banner keeps the last known report visible underneath
          // rather than blanking the popup.
          Text {
            visible: root.lastError !== "" && (root.status === "offline" || root.status === "error" || root.status === "unknown-station")
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.status === "unknown-station"
              ? "Unknown station — " + root.lastError
              : (root.status === "offline" ? "Offline — " + root.lastError : root.lastError)
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // ---- raw / decoded ---------------------------------------------

          Row {
            width: parent.width
            spacing: Style.space(8)

            Toggle {
              width: parent.width
              label: root.showRaw ? "Raw reports" : "Decoded reports"
              description: "Switch between the raw METAR text and a plain-language reading."
              checked: root.showRaw
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.writeSetting("showRaw", !root.showRaw)
            }
          }

          // ---- METAR -----------------------------------------------------

          PanelSeparator { width: parent.width }
          PanelSectionHeader {
            text: root.taf ? "METAR" : "OBSERVATION"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.report !== null
            width: parent.width
            textFormat: root.showRaw ? Text.PlainText : Text.AutoText
            wrapMode: Text.Wrap
            text: root.report
              ? (root.showRaw ? root.report.raw : Model.decodeMetar(root.report, root.units))
              : "No observation available."
            color: root.foreground
            font.family: root.showRaw ? Style.font.family : root.fontFamily
            font.pixelSize: Style.font.body
          }

          // ---- TAF frise -------------------------------------------------

          PanelSeparator { visible: root.taf !== null; width: parent.width }
          PanelSectionHeader {
            visible: root.taf !== null
            text: "FORECAST"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Canvas {
            id: frise
            visible: root.taf !== null
            width: parent.width
            height: Style.space(34)

            // A Canvas does not re-run paint() when a binding input changes, so
            // the repaint is driven from the forecast object itself: the service
            // replaces `tafs[icao]` wholesale, which makes identity a reliable
            // change signal.
            property var forecast: root.taf
            onForecastChanged: requestPaint()
            onWidthChanged: requestPaint()
            onVisibleChanged: if (visible) requestPaint()

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              if (!root.taf) return

              var timeline = Model.tafTimeline(root.taf.periods, Date.now(), width)
              for (var i = 0; i < timeline.segments.length; i++) {
                var segment = timeline.segments[i]
                var role = Model.categoryColorRole(segment.category)
                ctx.fillStyle = root.categoryColors[role] !== undefined ? root.categoryColors[role] : "#888888"
                ctx.globalAlpha = segment.overlay ? 0.45 : 0.9
                var y = segment.overlay ? height / 2 + 2 : 2
                var h = segment.overlay ? height / 2 - 4 : height - 4
                ctx.fillRect(segment.x, y, Math.max(1, segment.width - 1), h)
              }
              ctx.globalAlpha = 1

              if (timeline.nowX !== null) {
                ctx.strokeStyle = root.foreground
                ctx.lineWidth = 1
                ctx.beginPath()
                ctx.moveTo(timeline.nowX, 0)
                ctx.lineTo(timeline.nowX, height)
                ctx.stroke()
              }
            }
          }

          Row {
            visible: root.taf !== null
            width: parent.width
            spacing: Style.space(10)

            Repeater {
              model: ["VFR", "MVFR", "IFR", "LIFR"]

              Row {
                required property string modelData
                spacing: Style.space(4)
                Rectangle {
                  width: Style.space(8)
                  height: Style.space(8)
                  radius: 1
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.categoryColors[Model.categoryColorRole(modelData)]
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }
          }

          // ---- quick list ------------------------------------------------

          PanelSeparator { visible: root.quickStations !== ""; width: parent.width }
          PanelSectionHeader {
            visible: root.quickStations !== ""
            text: "QUICK LIST"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: Model.parseStationList(root.quickStations)

              Button {
                required property string modelData
                width: parent.width
                leftAlign: true
                bordered: false
                foreground: root.foreground
                fontFamily: root.fontFamily
                iconText: root.letterFor(modelData)
                text: modelData + "  " + root.quickRowText(modelData)
                onClicked: root.chooseStation(modelData)
              }
            }
          }

          // ---- search ----------------------------------------------------

          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: searchField
              width: parent.width - addButton.width - parent.spacing
              placeholderText: "ICAO code"
              foreground: root.foreground
              font.family: root.fontFamily
              onAccepted: {
                root.addToQuickList(text)
                root.chooseStation(text)
                text = ""
              }
            }

            PanelActionButton {
              id: addButton
              iconText: "󰐕"
              tooltipText: "Add to the quick list and use it"
              foreground: root.foreground
              onClicked: {
                root.addToQuickList(searchField.text)
                root.chooseStation(searchField.text)
                searchField.text = ""
              }
            }
          }

          // The two failures are distinct and never conflated: a code the API
          // does not know is not a network problem.
          Text {
            visible: root.status === "unknown-station" && root.station !== ""
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.station + " is not a reporting station"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // ---- actions ---------------------------------------------------

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              width: (parent.width - parent.spacing * 2) / 2
              bordered: true
              iconText: "󰒡"
              text: "Details"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.expanded = true
            }

            PanelActionButton {
              iconText: "󰑓"
              tooltipText: "Refresh now"
              foreground: root.foreground
              onClicked: root.refresh()
            }

            PanelActionButton {
              iconText: "󰆏"
              tooltipText: "Copy the raw METAR"
              foreground: root.foreground
              onClicked: root.copy(root.report ? root.report.raw : "")
            }
          }

          Text {
            visible: root.copyNote !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.copyNote
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // ================================================================
          // Detail view
          // ================================================================

          Column {
            visible: root.expanded
            width: parent.width
            spacing: Style.space(14)

            PanelSeparator { width: parent.width }

            // ---- decoded METAR and TAF --------------------------------

            PanelSectionHeader {
              text: "DECODED"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.report !== null
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.report ? Model.decodeMetar(root.report, root.units) : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              visible: root.taf !== null
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: {
                if (!root.taf) return ""
                var text = "TAF valid " + Model.formatObsTime(root.taf.validTimeFrom, root.timeFormat)
                  + " to " + Model.formatObsTime(root.taf.validTimeTo, root.timeFormat) + "."
                for (var i = 0; i < root.taf.periods.length; i++) {
                  var period = root.taf.periods[i]
                  var header = Model.formatObsTime(period.timeFrom, root.timeFormat)
                    + (period.change ? " " + period.change : "")
                    + (period.probability !== null && period.probability !== undefined ? " PROB" + period.probability : "")
                  text += "\n" + header + " — " + (period.category || "—")
                    + (period.wspd !== null ? ", " + (period.wdir === "VRB" ? "variable" : period.wdir + "°") + " " + period.wspd + " kt" : "")
                    + (period.wgst !== null ? " gusting " + period.wgst : "")
                    + (period.visibility && period.visibility.meters !== null
                      ? ", visibility " + Model.formatVisibility(period.visibility, root.units) : "")
                }
                return text
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            // The raw section is collapsible: the decoded text is what a quick
            // look needs, and the raw text is what a thorough one wants.
            Toggle {
              width: parent.width
              label: "Show raw text"
              checked: root.showRaw
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.writeSetting("showRaw", !root.showRaw)
            }

            Text {
              visible: root.showRaw && root.report !== null
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.report ? root.report.raw : ""
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: root.showRaw && root.taf !== null
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.taf ? root.taf.raw : ""
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            // ---- wind ---------------------------------------------------

            PanelSeparator { visible: root.report !== null; width: parent.width }
            PanelSectionHeader {
              visible: root.report !== null
              text: "WIND"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.report !== null
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.report ? Model.formatWind(root.report, root.units)
                + (root.report.wind && root.report.wind.variable
                  ? "  ·  varying " + root.report.wind.variable[0] + "°–" + root.report.wind.variable[1] + "°" : "")
                : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Column {
              width: parent.width
              spacing: Style.space(2)
              // No runways known for this field — the section simply is not
              // there rather than showing an empty table.
              visible: root.runways.length > 0 && root.report !== null
                && root.report.wind && root.report.wind.speedKt !== null
                && root.report.wind.dir !== null

              PanelSectionHeader {
                text: "RUNWAY COMPONENTS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.runways

                Row {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(8)

                  readonly property var components: root.report && root.report.wind
                    ? Model.crosswindComponents(modelData.alignment, root.report.wind.dir, root.report.wind.speedKt)
                    : ({ head: null, cross: null })

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.id
                    width: Style.space(80)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: parent.components.head === null ? "—"
                      : (parent.components.head >= 0 ? "head " : "tail ")
                        + Math.abs(Math.round(parent.components.head)) + " kt"
                    width: Style.space(110)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: parent.components.cross === null ? "—"
                      : "cross " + Math.abs(Math.round(parent.components.cross)) + " kt "
                        + (parent.components.cross >= 0 ? "from the right" : "from the left")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }

            // ---- clouds ------------------------------------------------

            PanelSeparator { visible: root.report !== null; width: parent.width }
            PanelSectionHeader {
              visible: root.report !== null
              text: "CLOUD"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.report !== null
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: {
                if (!root.report) return ""
                // An empty layer list is not missing data: CAVOK, NSC and SKC
                // all mean, positively, that nothing significant is there.
                var text = root.report.clouds.length === 0
                  ? "no significant cloud reported"
                  : Model.formatClouds(root.report.clouds, root.units)
                if (root.report.ceilingFt !== null && root.report.ceilingFt !== undefined)
                  text += "\nceiling " + Math.round(root.report.ceilingFt) + " ft"
                else
                  text += "\nno ceiling"
                return text
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            // ---- SIGMET ------------------------------------------------

            PanelSeparator {
              visible: root.configuredFir !== "" && (root.sigmets.length > 0 || root.sigmetError !== "")
              width: parent.width
            }
            PanelSectionHeader {
              visible: root.configuredFir !== "" && (root.sigmets.length > 0 || root.sigmetError !== "")
              text: "SIGMET · FIR " + root.configuredFir
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.configuredFir !== "" && root.sigmetError !== "" && root.sigmets.length === 0
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.sigmetError
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              visible: root.configuredFir !== "" && root.sigmetError === "" && root.sigmets.length === 0
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: "No SIGMET for this FIR."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: root.sigmets

              Column {
                required property var modelData
                width: parent.width
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: String(modelData.hazard || "") + (modelData.qualifier ? " " + modelData.qualifier : "")
                    + "  ·  " + Model.formatObsTime(modelData.validTimeFrom * 1000, root.timeFormat)
                    + " – " + Model.formatObsTime(modelData.validTimeTo * 1000, root.timeFormat)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: String(modelData.rawSigmet || "")
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            // ---- NOTAM -------------------------------------------------

            PanelSeparator { width: parent.width }
            PanelSectionHeader {
              text: "NOTAM"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // Off: an explanation and nothing else. Making an unauthenticated
            // request to a service the user has not signed up for would be both
            // pointless and rude.
            Text {
              visible: !root.notamsEnabled
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: "NOTAMs are not free anywhere: every public source needs an account. "
                + "SkyBrief uses autorouter.aero — create a free account at "
                + "https://www.autorouter.aero/signup, ask for API access through their "
                + "support ticket system, then set the NOTAM source to autorouter here "
                + "and enter the credentials below. Until then no NOTAM request is made."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Column {
              visible: root.notamsEnabled
              width: parent.width
              spacing: Style.space(6)

              Text {
                visible: !root.hasCredentials
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: "Enter your autorouter account. The credentials are stored in "
                  + "~/.local/state/omarchy/skybrief/autorouter.json with mode 0600 — "
                  + "never in shell.json."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              TextField {
                id: userField
                width: parent.width
                visible: !root.hasCredentials
                placeholderText: "autorouter user (email)"
                foreground: root.foreground
                font.family: root.fontFamily
                onTextChanged: root.credentialUser = text
              }

              TextField {
                id: passwordField
                width: parent.width
                visible: !root.hasCredentials
                password: true
                placeholderText: "autorouter password"
                foreground: root.foreground
                font.family: root.fontFamily
                onTextChanged: root.credentialPassword = text
              }

              Button {
                width: parent.width
                bordered: true
                visible: !root.hasCredentials
                iconText: "󰆓"
                text: "Save credentials"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.saveCredentials()
              }
            }

            // Three distinct states, never conflated: a failed query, a query
            // in flight, and a genuinely empty result.
            Text {
              visible: root.notamsEnabled && root.notamError !== ""
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.notamError
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              visible: root.notamsEnabled && root.notamError === "" && root.notamPending
              width: parent.width
              textFormat: Text.PlainText
              text: "Querying autorouter…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              visible: root.notamsEnabled && root.hasCredentials && root.notamError === ""
                && !root.notamPending
                && root.notams.forStation.length === 0 && root.notams.forFir.length === 0
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: "No NOTAM in force for this aerodrome or FIR."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Column {
              visible: root.notamsEnabled && root.notams.forStation.length > 0
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                text: "AERODROME " + root.station
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.notams.forStation

                Column {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(2)

                  Row {
                    width: parent.width
                    spacing: Style.space(8)
                    Text {
                      textFormat: Text.PlainText
                      text: modelData.id
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: modelData.validFrom + " → " + modelData.validTo
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    // Folded at three lines and unfolded on click, so one long
                    // NOTAM cannot push the rest off the panel.
                    maximumLineCount: root.expandedNotam === modelData.id ? 1000 : 3
                    elide: root.expandedNotam === modelData.id ? Text.ElideNone : Text.ElideRight
                    text: modelData.text
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body

                    MouseArea {
                      anchors.fill: parent
                      onClicked: root.expandedNotam = root.expandedNotam === modelData.id ? "" : modelData.id
                    }
                  }
                }
              }
            }

            Column {
              visible: root.notamsEnabled && root.notams.forFir.length > 0
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                text: "FIR " + root.configuredFir
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.notams.forFir

                Column {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(2)

                  Row {
                    width: parent.width
                    spacing: Style.space(8)
                    Text {
                      textFormat: Text.PlainText
                      text: modelData.id
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: modelData.validFrom + " → " + modelData.validTo
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    maximumLineCount: root.expandedNotam === modelData.id ? 1000 : 3
                    elide: root.expandedNotam === modelData.id ? Text.ElideNone : Text.ElideRight
                    text: modelData.text
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body

                    MouseArea {
                      anchors.fill: parent
                      onClicked: root.expandedNotam = root.expandedNotam === modelData.id ? "" : modelData.id
                    }
                  }
                }
              }
            }

            Button {
              width: parent.width
              visible: root.notamsEnabled && root.hasCredentials
              bordered: true
              iconText: "󰩹"
              text: "Clear credentials"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: if (root.service) root.service.clearCredentials()
            }

            // ---- back --------------------------------------------------

            PanelSeparator { width: parent.width }
            Button {
              width: parent.width
              bordered: true
              iconText: "󰁍"
              text: "Back"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.expanded = false
            }
          }
        }
      }
    }
  }

  function letterFor(code) {
    if (!root.service) return ""
    return service.categoryLetter(service.categoryFor(code))
  }

  function quickRowText(code) {
    if (!root.service) return ""
    var report = service.reportFor(code)
    if (!report) return "no observation"
    var age = ""
    if (report.obsTime) {
      var minutes = Math.round((Date.now() - report.obsTime) / 60000)
      age = minutes <= 0 ? "now" : minutes + " min ago"
    }
    return (report.category || "—") + (age !== "" ? "  ·  " + age : "")
  }
}

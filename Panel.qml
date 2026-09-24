import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The popup: the observation and the forecast it leads into, then — behind the
// Details button — what does not fit in a glance: runway wind components and
// SIGMETs.
//
// `expanded` is a view state, not a second window: the same KeyboardPanel grows
// and a column appears at the end. One escape key, one focus target, one popout
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
  // The trend starts folded: the current observation is what the panel is for,
  // and three earlier ones above the forecast would push it off the first
  // screenful. The choice does not persist — it is a glance, not a preference.
  property bool trendOpen: false
  property string copyNote: ""
  // A one-line answer to the last list action: the personal list being full is
  // a state the user cannot see from the rows themselves.
  property string listNote: ""

  readonly property string station: root.service ? String(root.service.favouriteStation || "") : ""
  readonly property var report: root.service ? root.service.reportFor(root.station) : null
  readonly property var taf: root.service ? root.service.tafs[root.station] || null : null
  readonly property string status: root.service ? String(root.service.status || "idle") : "idle"
  readonly property string lastError: root.service ? String(root.service.lastError || "") : ""
  readonly property string units: root.service ? root.service.units : "metric"
  readonly property string timeFormat: root.service ? root.service.timeFormat : "utc"
  readonly property bool showRaw: root.service ? root.service.showRaw : true
  readonly property string configuredFir: root.service ? root.service.configuredFir : ""
  readonly property var sigmets: root.service ? root.service.sigmetsForFir() : []
  readonly property string sigmetError: root.service ? String(root.service.sigmetError || "") : ""
  readonly property var stationMeta: root.service ? root.service.stationInfo[root.station] || null : null
  readonly property var runways: root.service ? root.service.runwaysFor(root.station) : []

  // Runway components need a known field, a known wind, and a direction to
  // resolve it against. Without all three the table is a column of dashes, so
  // the section is not shown at all — and the detail view, which is then
  // whatever else is enabled, does not get a leading separator for it.
  readonly property bool hasRunwayComponents: root.runways.length > 0 && root.report !== null
    && root.report.wind && root.report.wind.speedKt !== null && root.report.wind.dir !== null
  readonly property bool sigmetSectionVisible: root.configuredFir !== ""
    && (root.sigmets.length > 0 || root.sigmetError !== "")

  // Runways and SIGMET are the whole of the detail view, and either can be
  // absent: no wind means no crosswind table, no configured FIR means no
  // SIGMET. When both are absent the view would open empty, so it says so
  // instead.
  readonly property bool detailHasContent: root.hasRunwayComponents || root.sigmetSectionVisible
  readonly property string detailLabel: root.expanded ? "Close" : "Details"
  readonly property string category: report ? String(report.category || "") : ""
  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color categoryColor: {
    var role = Model.categoryColorRole(category)
    return categoryColors[role] !== undefined ? categoryColors[role] : root.foreground
  }
  readonly property color dim: Qt.darker(root.foreground, 1.4)

  readonly property string heroTitle: station !== "" ? station : "SkyBrief"

  // The observation has no single "current group" to highlight, so its trend is
  // read from the stored earlier observations instead.
  readonly property var history: root.service ? root.service.historyFor(root.station) : []

  // Name-search state, straight from the service so a re-open shows whatever
  // the last search found rather than an empty box.
  readonly property var searchResults: root.service && Array.isArray(root.service.searchResults)
    ? root.service.searchResults : []
  readonly property string searchError: root.service ? String(root.service.searchError || "") : ""
  readonly property bool searchPending: root.service ? root.service.searchPending === true : false

  // The forecast, group by group when decoded: reading it back as one paragraph
  // hides which group is in force, which is the thing a decoded TAF is for.
  readonly property var tafLines: root.taf
    ? Model.describeTafPeriods(root.taf, units, timeFormat, Date.now())
    : []

  readonly property string heroMeta: {
    if (!report) return status === "offline" ? "OFFLINE" : "NO REPORT"
    var name = stationMeta && stationMeta.name ? stationMeta.name : (report.name || "")
    var observed = Model.formatObsTime(report.obsTime, timeFormat)
    return name !== "" ? name + " · " + observed : observed
  }

  // ---- state and actions -------------------------------------------------

  function open() {
    root.expanded = false
    resetSearch()
    root.controller.show()
    refresh()
  }

  function openFromHotkey() {
    resetSearch()
    root.controller.show()
    refresh()
  }

  // The field and its note describe one attempt at typing a code, which ends
  // when the panel does.
  function resetSearch() {
    root.listNote = ""
    if (searchField) searchField.text = ""
    if (root.service) root.service.clearSearch()
  }

  function close() {
    root.copyNote = ""
    root.expanded = false
    root.trendOpen = false
    resetSearch()
    root.controller.hide()
  }

  function refresh() {
    if (root.service) root.service.requestRefresh(true)
  }

  // Settings writes go through the shell so the choice survives a restart.
  // The whole entry is merged, never replaced: writing one key must not drop
  // the others.
  function writeSettings(changes) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    var source = root.settings || {}
    for (var existing in source) if (existing !== "id") entry[existing] = source[existing]
    for (var key in changes) entry[key] = changes[key]
    root.settings = entry
    bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function writeSetting(key, value) {
    var changes = {}
    changes[key] = value
    writeSettings(changes)
  }

  // One entry point for the field and the add button. A four-character code is
  // an ICAO code, and is both listed and made the favourite; anything else is
  // treated as a place name and opens a shortlist, because a place name can be
  // several airfields and only the user knows which one they meant.
  function submitQuery(raw) {
    var text = String(raw === null || raw === undefined ? "" : raw).trim()
    if (/^[A-Za-z0-9]{4}$/.test(text)) {
      root.submitStation(text)
      return
    }
    if (root.service) root.service.searchByName(text)
  }

  // Picking a candidate is what makes it the favourite; adding it to the quick
  // list is a bonus that must not be able to block the choice — a full list
  // still lets the station be selected.
  function chooseSearchResult(icao) {
    var code = String(icao || "").trim().toUpperCase()
    if (!/^[A-Z0-9]{4}$/.test(code)) return
    root.chooseStation(code)
    root.addToQuickList(code)
    if (root.service) root.service.clearSearch()
    searchField.text = ""
  }

  // One entry point for the field and the add button. A code that is a valid
  // station is both listed and made the favourite; anything else stays in the
  // field with the reason, so a typo can be corrected instead of retyped.
  function submitStation(raw) {
    var icao = String(raw === null || raw === undefined ? "" : raw).trim().toUpperCase()
    if (!/^[A-Z0-9]{4}$/.test(icao)) {
      root.listNote = "That is not a four-character ICAO code."
      return
    }
    if (!root.addToQuickList(icao)) return
    root.chooseStation(icao)
    searchField.text = ""
  }

  function chooseStation(code) {
    var icao = String(code || "").trim().toUpperCase()
    if (!/^[A-Z0-9]{4}$/.test(icao)) return
    root.listNote = ""
    writeSetting("station", icao)
    refresh()
  }

  function addToQuickList(code) {
    var result = Model.addQuickStation(root.settings ? root.settings.quickStations : "", code)
    if (result.added) {
      root.listNote = ""
      writeSettings({ quickStations: result.stations.join(",") })
      return true
    }
    // A full list and an already-listed code are different problems, so they
    // get different sentences; neither leaves the user wondering why nothing
    // happened.
    if (result.reason === "full")
      root.listNote = "Quick list is full (" + Model.MAX_QUICK_STATIONS + " stations) — remove one with the bin."
    else if (result.reason === "duplicate")
      return true
    else
      root.listNote = "That is not a four-character ICAO code."
    return false
  }

  // Removing the station that is currently the favourite would leave the widget
  // reading a code it is no longer offered, so the favourite is cleared in the
  // same write and falls back to the nearest reporting field.
  function removeFromQuickList(code) {
    var icao = String(code || "").trim().toUpperCase()
    var next = Model.removeQuickStation(root.settings ? root.settings.quickStations : "", icao)

    var changes = { quickStations: next.join(",") }
    if (String(root.settings ? root.settings.station : "").trim().toUpperCase() === icao)
      changes.station = ""
    // A note about the list being full stops being true the moment room is
    // made, and a note that outlives its cause is worse than no note.
    root.listNote = ""
    writeSettings(changes)
    refresh()
  }

  function copy(text) {
    if (String(text || "") === "") return
    Quickshell.clipboardText = String(text)
    root.copyNote = "Copied"
    copyNoteTimer.restart()
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
      blocked: searchField.activeFocus
      onCloseRequested: root.expanded ? root.expanded = false : root.close()
      onTextKey: function(text) {
        if (text === "r") root.refresh()
        else if (text === "d" && root.detailHasContent) root.expanded = !root.expanded
        else if (text === "c" && root.report) root.copy(root.report.raw)
        else if (text === "t" && root.taf) root.copy(root.taf.raw)
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
      // Tab walks the text fields the visible view actually offers. Without
      // this the catcher (Keys.BeforeItem) consumes Tab, no field can ever take
      // focus, and `blocked` above would be dead logic.
      onTabRequested: function(direction) {
        var fields = [searchField]
        var available = []
        for (var i = 0; i < fields.length; i++)
          if (fields[i] && fields[i].visible) available.push(fields[i])
        if (!available.length) return

        var current = -1
        for (var j = 0; j < available.length; j++)
          if (available[j].activeFocus) current = j

        if (direction > 0) {
          if (current === available.length - 1 || current === -1) {
            if (current === -1) available[0].forceActiveFocus()
            else keyCatcher.forceActiveFocus()
          } else available[current + 1].forceActiveFocus()
        } else {
          if (current <= 0) keyCatcher.forceActiveFocus()
          else available[current - 1].forceActiveFocus()
        }
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
            // The category pill is not the hero's `detail`: that one is pinned
            // to the trailing edge of the title row, and the category belongs
            // under the symbol it qualifies, at the head of the card.
            detail: ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              // A plain Item rather than a Column: a Column refuses horizontal
              // anchors on its children, and both of these are centred.
              Item {
                implicitWidth: Math.max(symbol.implicitWidth, categoryPill.implicitWidth)
                implicitHeight: symbol.implicitHeight
                  + (categoryPill.visible ? Style.space(4) + categoryPill.implicitHeight : 0)

                Text {
                  id: symbol
                  anchors.top: parent.top
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: root.status === "offline" || root.status === "error" ? "󰅖"
                    : (root.status === "unknown-station" ? "󰋼" : "󰖐")
                  color: root.category !== "" ? root.categoryColor : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }

                // Hidden outright when there is no category, so the states that
                // are not one — no observation, offline — keep the bare glyph
                // instead of an empty lozenge under it.
                BorderSurface {
                  id: categoryPill
                  visible: root.category !== ""
                  anchors.top: symbol.bottom
                  anchors.topMargin: Style.space(4)
                  anchors.horizontalCenter: parent.horizontalCenter
                  implicitWidth: categoryText.implicitWidth + Style.space(10)
                  implicitHeight: categoryText.implicitHeight + Style.space(4)
                  color: "transparent"
                  borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
                  radius: Style.cornerRadius

                  Text {
                    id: categoryText
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: root.category
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }
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

          // The label names the CURRENT mode and the control is the switch, not
          // a sentence about what switching does: the METAR text below is the
          // explanation, and the description was restating it.
          //
          // The switch sits against the label it qualifies rather than at the
          // far edge of the card: "Raw [o]" reads as one control, and the
          // refresh then owns the trailing edge of this row on its own.
          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              id: rawLabel
              textFormat: Text.PlainText
              text: root.showRaw ? "Raw" : "Decoded"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: rawToggle
              checked: root.showRaw
              foreground: root.foreground
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.writeSetting("showRaw", !root.showRaw)
              PanelToolTip {
                visible: rawToggle.containsMouse
                text: root.showRaw ? "Show the decoded reading" : "Show the raw METAR text"
                fontFamily: root.fontFamily
              }
            }

            Item {
              width: Math.max(0, parent.width - rawLabel.implicitWidth - rawToggle.implicitWidth
                - refreshButton.implicitWidth - parent.spacing * 3)
              height: 1
            }

            // The refresh acts on the whole card, but it belongs with the mode
            // switch: both are how the reader asks for something to be shown
            // differently, and neither is about one particular report.
            PanelActionButton {
              id: refreshButton
              iconText: "󰑓"
              tooltipText: root.service && root.service.status === "loading"
                ? "Refreshing…" : "Refresh now"
              foreground: root.foreground
              fontFamily: root.fontFamily
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.refresh()
            }
          }

          // ---- METAR -----------------------------------------------------

          PanelSeparator { width: parent.width }

          // The copy affordance sits on the header line of the text it copies,
          // one row per report: a button next to the text it acts on cannot be
          // mistaken for a button acting on the panel.
          Row {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              id: metarHeader
              text: root.taf ? "METAR" : "OBSERVATION"
              foreground: root.foreground
              fontFamily: root.fontFamily
              anchors.verticalCenter: parent.verticalCenter
            }

            Item {
              width: Math.max(0, parent.width - metarHeader.implicitWidth - copyMetar.width - parent.spacing * 2)
              height: 1
            }

            PanelActionButton {
              id: copyMetar
              iconText: "󰆏"
              tooltipText: "Copy the raw METAR"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.copy(root.report ? root.report.raw : "")
            }
          }

          // PlainText unconditionally: the decoded reading is built from the
          // remote report, so markup-shaped text arriving in a station name or
          // a cloud token must be displayed literally rather than interpreted
          // as rich text. AutoText here was the one sink in the plugin that
          // could turn endpoint-controlled bytes into formatting.
          Text {
            visible: root.report !== null
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.report
              ? (root.showRaw ? root.report.raw : Model.decodeMetar(root.report, root.units))
              : "No observation available."
            color: root.foreground
            font.family: root.showRaw ? Style.font.family : root.fontFamily
            font.pixelSize: Style.font.body
          }

          // ---- trend -----------------------------------------------------

          // Earlier observations of the same station: one METAR says what is
          // happening, three say which way it is going. Folded away by default
          // so the current report stays the first thing read, and shown at all
          // only when the station actually has a past in the response.
          Column {
            visible: root.history.length > 0
            width: parent.width
            spacing: Style.space(4)

            // A bare label when collapsed, a clickable row when there is
            // something to unfold: an affordance that does nothing is worse
            // than none. The click area is a sibling of the labels, not a child
            // of the Row — an anchored child disables the Row's own layout.
            Item {
              width: parent.width
              height: trendHeader.implicitHeight

              Row {
                id: trendHeader
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: "TREND · " + root.history.length + " earlier"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.trendOpen ? "󰅃" : "󰅀"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.trendOpen = !root.trendOpen
              }
            }

            Repeater {
              model: root.trendOpen ? root.history : []

              Row {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: Model.formatObsTime(modelData.obsTime, root.timeFormat)
                  width: Style.space(46)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  textFormat: Text.PlainText
                  text: Model.formatObservationLine(modelData, root.units)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          // ---- TAF -------------------------------------------------------

          // The forecast is shown by default, right under the observation it
          // continues: the two are read together, and a forecast a click away
          // is a forecast nobody looks at.
          PanelSeparator { visible: root.taf !== null; width: parent.width }

          Row {
            visible: root.taf !== null
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              id: forecastHeader
              text: "FORECAST"
              foreground: root.foreground
              fontFamily: root.fontFamily
              anchors.verticalCenter: parent.verticalCenter
            }

            Item {
              width: Math.max(0, parent.width - forecastHeader.implicitWidth - tafCopyButton.width - parent.spacing * 2)
              height: 1
            }

            PanelActionButton {
              id: tafCopyButton
              iconText: "󰆏"
              tooltipText: "Copy the raw TAF"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.copy(root.taf ? root.taf.raw : "")
            }
          }

          // The raw forecast is one line of coded groups; the decoded one is the
          // same forecast spelled out period by period, with the group in force
          // marked so it can be found without comparing five clock ranges.
          Text {
            visible: root.taf !== null && root.showRaw
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.taf ? root.taf.raw : ""
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            visible: root.taf !== null && !root.showRaw
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.tafLines

              Column {
                required property var modelData
                width: parent.width
                spacing: Style.space(1)

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  // The marker is a bar in the category colour, the same code
                  // the frise above uses, plus the word for the group in force:
                  // colour alone would not survive a colour-blind reader.
                  Rectangle {
                    width: Style.space(3)
                    height: parent.height
                    color: modelData.overlay
                      ? "transparent"
                      : root.tafLineColor(modelData)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.header
                    color: modelData.current ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: modelData.current
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    visible: modelData.current
                    textFormat: Text.PlainText
                    text: "NOW"
                    color: root.categoryColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: modelData.detail
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  leftPadding: Style.space(9)
                }
              }
            }
          }

          Canvas {
            id: frise
            visible: root.taf !== null
            width: parent.width
            height: Style.space(52)

            // A Canvas does not re-run paint() when a binding input changes, so
            // the repaint is driven from the forecast object itself: the service
            // replaces `tafs[icao]` wholesale, which makes identity a reliable
            // change signal.
            property var forecast: root.taf
            onForecastChanged: requestPaint()
            onWidthChanged: requestPaint()
            onVisibleChanged: if (visible) requestPaint()

            // Bands occupy the top half; the bottom half is the time axis.
            readonly property real bandHeight: Math.round(height * 0.58)
            readonly property real axisHeight: height - bandHeight

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              if (!root.taf) return

              var timeline = Model.tafTimeline(root.taf.periods, Date.now(), width)
              var band = frise.bandHeight

              for (var i = 0; i < timeline.segments.length; i++) {
                var segment = timeline.segments[i]
                var role = Model.categoryColorRole(segment.category)
                var toColor = root.categoryColors[role] !== undefined ? root.categoryColors[role] : "#888888"
                ctx.fillStyle = toColor
                ctx.globalAlpha = segment.overlay ? 0.45 : 0.9
                var y = segment.overlay ? band / 2 + 1 : 1
                var h = segment.overlay ? band / 2 - 3 : band - 3
                var right = segment.x + segment.width

                // A BECMG band is not a change that took effect on the hour the
                // window opened: the TAF says only that the new conditions
                // establish themselves somewhere inside that window. The band is
                // drawn as a ramp from the conditions in force before it to the
                // ones it states, and flat only beyond the window — the one
                // moment the TAF does name.
                var ramp = segment.ramp
                if (ramp) {
                  var fromRole = Model.categoryColorRole(ramp.fromCategory)
                  var fromColor = root.categoryColors[fromRole] !== undefined ? root.categoryColors[fromRole] : toColor
                  var x0 = segment.x + ramp.from * segment.width
                  var x1 = segment.x + ramp.to * segment.width
                  // Whatever the ramp does not cover is unambiguous: the old
                  // conditions before it, the new ones after it.
                  if (x0 > segment.x) {
                    ctx.fillStyle = fromColor
                    ctx.fillRect(segment.x, y, x0 - segment.x, h)
                  }
                  var gradient = ctx.createLinearGradient(x0, 0, x1, 0)
                  gradient.addColorStop(0, fromColor)
                  gradient.addColorStop(1, toColor)
                  ctx.fillStyle = gradient
                  ctx.fillRect(x0, y, Math.max(1, x1 - x0), h)
                  if (x1 < right) {
                    ctx.fillStyle = toColor
                    ctx.fillRect(x1, y, right - x1, h)
                  }
                  continue
                }

                ctx.fillRect(segment.x, y, Math.max(1, segment.width - 1), h)
              }
              ctx.globalAlpha = 1

              // Hour marks. A tick is drawn for every label so the eye can
              // follow it down from the band, with the label below the axis.
              ctx.font = Math.round(Style.font.caption) + "px " + root.fontFamily
              ctx.textBaseline = "top"
              for (var t = 0; t < timeline.ticks.length; t++) {
                var tick = timeline.ticks[t]
                ctx.strokeStyle = root.foreground
                ctx.globalAlpha = tick.dayStart ? 0.65 : 0.3
                ctx.lineWidth = 1
                ctx.beginPath()
                ctx.moveTo(tick.x, band)
                ctx.lineTo(tick.x, band + (tick.dayStart ? 5 : 3))
                ctx.stroke()

                ctx.globalAlpha = 1
                ctx.fillStyle = root.dim
                var textWidth = ctx.measureText(tick.label).width
                // Clamp inside the canvas rather than letting the first and
                // last labels bleed off the card.
                var textX = Math.max(0, Math.min(width - textWidth, tick.x - textWidth / 2))
                ctx.fillText(tick.label, textX, band + 6)
              }

              if (timeline.nowX !== null) {
                ctx.strokeStyle = root.foreground
                ctx.globalAlpha = 1
                ctx.lineWidth = 1
                ctx.beginPath()
                ctx.moveTo(timeline.nowX, 0)
                ctx.lineTo(timeline.nowX, band)
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
            text: "QUICK LIST  " + Model.parseStationList(root.quickStations).length
              + "/" + Model.MAX_QUICK_STATIONS
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: Model.parseStationList(root.quickStations)

              Row {
                id: quickRow
                required property string modelData
                width: parent.width
                height: quickRowSurface.height
                spacing: Style.space(4)

                // The category letter used to sit on the left as a glyph; it
                // was saying what the category word says again, one column
                // later. A Button cannot carry three columns — its content is
                // fixed to an icon and one label — so the row is the kit's
                // cursor surface with the same hover chrome and its own click.
                CursorSurface {
                  id: quickRowSurface
                  property bool hovered: false
                  readonly property var hoverSpec: Border.controlSpec("hover-cursor", root.foreground, Color.accent)

                  hasCursor: hovered
                  foreground: root.foreground
                  width: Math.max(0, parent.width - parent.spacing - trash.width)
                  height: Math.max(Style.space(22),
                    quickRowContent.implicitHeight + Style.spacing.controlPaddingY * 2
                      + Border.top(hoverSpec) + Border.bottom(hoverSpec))
                  anchors.verticalCenter: parent.verticalCenter

                  HoverHandler {
                    onHoveredChanged: quickRowSurface.hovered = hovered
                  }

                  Row {
                    id: quickRowContent
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.controlPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)

                    Text {
                      textFormat: Text.PlainText
                      text: quickRow.modelData
                      width: Style.space(46)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    // The category in the aviation colour the pill uses, so
                    // the list can be read down this one column.
                    Text {
                      textFormat: Text.PlainText
                      text: root.quickCategory(quickRow.modelData) || "—"
                      width: Style.space(44)
                      color: root.quickCategoryColor(quickRow.modelData)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: root.quickAgeText(quickRow.modelData)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.chooseStation(quickRow.modelData)
                  }
                }

                // Removing a row is the one destructive action here, so it gets
                // the urgent hover tint — the same convention the network and
                // bluetooth panels use for forget/unpair.
                PanelActionButton {
                  id: trash
                  iconText: "󰩹"
                  tooltipText: "Remove " + quickRow.modelData + " from the quick list"
                  foreground: root.dim
                  hoverColor: Color.urgent
                  anchors.verticalCenter: parent.verticalCenter
                  onClicked: root.removeFromQuickList(quickRow.modelData)
                }
              }
            }
          }

          // ---- search ----------------------------------------------------

          // One field for both ways of naming a field: a four-character code is
          // an ICAO code and goes straight in, anything else is a place name
          // and opens a shortlist to choose from. A name can cover several
          // airfields, so it never switches the favourite on its own.
          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: searchField
              width: parent.width - addButton.width - parent.spacing
              placeholderText: "ICAO code or place name"
              foreground: root.foreground
              font.family: root.fontFamily
              onAccepted: root.submitQuery(text)
            }

            PanelActionButton {
              id: addButton
              iconText: "󰐕"
              tooltipText: "Use this code, or search this name"
              foreground: root.foreground
              onClicked: root.submitQuery(searchField.text)
            }
          }

          // The shortlist. Rows are the same cursor surface as the quick list,
          // for the same reason: a code, a name and a distance do not fit in a
          // Button's fixed two-part content.
          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.searchResults.length > 0 || root.searchError !== "" || root.searchPending

            Text {
              visible: root.searchPending
              width: parent.width
              textFormat: Text.PlainText
              text: "Searching…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: !root.searchPending && root.searchError !== ""
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.searchError
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.searchResults

              Row {
                id: resultRow
                required property var modelData
                width: parent.width
                height: resultSurface.height

                CursorSurface {
                  id: resultSurface
                  property bool hovered: false
                  readonly property var hoverSpec: Border.controlSpec("hover-cursor", root.foreground, Color.accent)

                  hasCursor: hovered
                  foreground: root.foreground
                  width: parent.width
                  height: Math.max(Style.space(22),
                    resultContent.implicitHeight + Style.spacing.controlPaddingY * 2
                      + Border.top(hoverSpec) + Border.bottom(hoverSpec))

                  HoverHandler {
                    onHoveredChanged: resultSurface.hovered = hovered
                  }

                  Row {
                    id: resultContent
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.controlPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      textFormat: Text.PlainText
                      text: resultRow.modelData.icaoId
                      width: Style.space(46)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: resultRow.modelData.name
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.chooseSearchResult(resultRow.modelData.icaoId)
                  }
                }
              }
            }
          }

          // The answer to the last list action. Shown next to the field rather
          // than as a toast, so it cannot be missed while the list is scrolled
          // and it disappears with the panel.
          Text {
            visible: root.listNote !== ""
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: root.listNote
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
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

          // One control, and it says what it does in both directions: the
          // second click is the way back, so a separate Back button would be a
          // second name for the same action.
          Button {
            width: parent.width
            bordered: true
            visible: root.detailHasContent
            iconText: root.expanded ? "󰁍" : "󰒡"
            text: root.detailLabel
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.expanded = !root.expanded
          }

          // Nothing to unfold — and saying which of the two conditions is
          // missing would mean naming a setting the user may not even want.
          Text {
            visible: !root.detailHasContent
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: "No runway data for this field and no FIR configured — nothing to unfold."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
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
          // Detail view — runways, SIGMET
          // ================================================================

          Column {
            visible: root.expanded
            width: parent.width
            spacing: Style.space(14)

            // ---- runway components -------------------------------------

            Column {
              width: parent.width
              spacing: Style.space(2)
              visible: root.hasRunwayComponents
              PanelSeparator { width: parent.width }

              PanelSectionHeader {
                text: "RUNWAY COMPONENTS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.hasRunwayComponents ? root.runways : []

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
          }
        }
      }
    }
  }

  // The quick list reads down three columns: the code, the category in its
  // aviation colour, and the age of the observation. The category word rather
  // than the single letter, because the colour now carries the code and a
  // letter beside a coloured word would be the same information twice.
  // The bar beside a decoded TAF group carries the group's own category, so a
  // deteriorating forecast reads as the same colours the frise and the pill use.
  function tafLineColor(line) {
    var role = Model.categoryColorRole(line ? line.category : "")
    return root.categoryColors[role] !== undefined ? root.categoryColors[role] : root.dim
  }

  function quickCategory(code) {
    if (!root.service) return ""
    var report = root.service.reportFor(code)
    return report ? String(report.category || "") : ""
  }

  function quickCategoryColor(code) {
    var role = Model.categoryColorRole(root.quickCategory(code))
    return root.categoryColors[role] !== undefined ? root.categoryColors[role] : root.dim
  }

  function quickAgeText(code) {
    if (!root.service) return ""
    var report = root.service.reportFor(code)
    if (!report) return "no observation"
    if (!report.obsTime) return ""
    var minutes = Math.round((Date.now() - report.obsTime) / 60000)
    return minutes <= 0 ? "now" : minutes + " min ago"
  }
}

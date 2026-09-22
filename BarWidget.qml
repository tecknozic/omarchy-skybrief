import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar pill. Everything that must exist once for the whole desktop lives in
// Service.qml; this file renders one letter and forwards clicks to the popup.
//
// A letter rather than a coloured dot: it stays legible at the bar's status-slot
// size, reads the same on a light and a dark theme, and carries the same visual
// weight as the rest of the bar.
BarWidget {
  id: root
  moduleName: "io.github.tecknozic.skybrief"

  // Aviation flight-category colours are a code, not a decoration: VFR green,
  // MVFR blue, IFR red, LIFR magenta. Deliberately literal rather than drawn
  // from the active theme — a green that changed with the wallpaper would stop
  // meaning "VFR". The same table lives in Panel.qml.
  readonly property var categoryColors: ({
    vfr: "#4fbf5f",
    mvfr: "#4f8fdd",
    ifr: "#e0503f",
    lifr: "#d05fd0"
  })

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(root.moduleName)
    : null

  readonly property var report: service ? service.reportFor(service.favouriteStation) : null
  readonly property string status: service ? String(service.status || "idle") : "idle"
  readonly property string category: report ? String(report.category || "") : ""
  readonly property string colourRole: Model.categoryColorRole(category)
  readonly property bool hasCategoryColour: colourRole !== "none" && categoryColors[colourRole] !== undefined
  readonly property color categoryColor: hasCategoryColour ? categoryColors[colourRole] : (root.bar ? root.bar.barForeground : "#ffffff")

  // One letter per category, plus a distinct glyph for each state that is not
  // a category at all: `?` for a station with no observation, `!` for a
  // network failure, `…` before the first answer.
  readonly property string label: service ? String(service.pillLabel() || "…") : "…"

  // Tooltip: the numbers a pilot actually glances at, or the error that replaced
  // them. An uncoloured glyph says why it has no category.
  readonly property string tooltip: {
    if (!service) return "SkyBrief"
    if (status === "offline" || status === "error") return "SkyBrief — " + (service.lastError || status)
    if (status === "unknown-station")
      return "SkyBrief — " + (service.favouriteStation || "station") + " has no observation"
    if (!report) return "SkyBrief — loading…"

    var parts = [String(service.favouriteStation) + (category !== "" ? " " + category : "")]
    parts.push(Model.formatWind(report, service.units))
    parts.push(Model.formatVisibility(report.visibility, service.units))
    parts.push(report.ceilingFt === null || report.ceilingFt === undefined
      ? "no ceiling"
      : "ceiling " + Math.round(report.ceilingFt) + " ft")
    if (report.stale) parts.push("stale")
    return parts.join(" · ")
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (service) service.requestRefresh(true)
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract the shell's summon/hide/toggle routing looks for on the
  // bar-widget root (Bar.findPanelWidget checks open/close/opened).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    injectPanel()
    if (service) service.configure(root.settings)
  }
  Component.onCompleted: if (service) service.configure(root.settings)

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    slotSize: Style.bar.statusSlot
    // The coloured glyph is what carries the category; the neutral bar
    // foreground stays for the states that have no category yet.
    active: root.hasCategoryColour
    activeColor: root.categoryColor
    tooltipText: root.tooltip

    onPressed: function(button_) {
      // Right click opens the same detail view the hotkey does, so the mouse
      // path and the `omarchy-shell shell toggle` path land in one place.
      if (button_ === Qt.RightButton) {
        if (root.bar) root.bar.run("omarchy-shell shell toggle io.github.tecknozic.skybrief")
      } else if (button_ === Qt.MiddleButton) {
        root.refresh()
      } else {
        root.togglePanel()
      }
    }
  }
}

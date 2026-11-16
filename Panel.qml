import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar widget for a local llama.cpp router (local-llm.service + the bundled bin/llm CLI).
// Click: panel. Right-click: unload the model in VRAM. Middle-click: web UI.
Panel {
  id: root
  moduleName: "io.github.0w3n-n.local-llm"
  ipcTarget: "io.github.0w3n-n.local-llm"
  manageIpc: false

  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null
  readonly property Item modelColumn: panel.loadedContent ? panel.loadedContent.modelColumn : null

  property string focusSection: "header"   // header | models | actions
  property int modelIndex: 0
  property int actionIndex: 0
  property bool cursorActive: false

  // What the icon's lower (attention) triangle shows (see LlmIcon.qml).
  readonly property string iconMode: {
    if (!llm.serverOn) return "stopped"
    if (!llm.online || llm.anyLoading) return llm.online ? "loading" : "idle"
    if (!llm.loadedModel) return "idle"
    if (llm.thinking) return "thinking"
    if (llm.loadedAsleep) return "asleep"
    return "ready"
  }
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The icon's upper triangle (VRAM gauge) takes a second colour from the
  // theme: "ch2" from the theme's scope.json when it ships one, otherwise the
  // theme's cyan/blue. Re-read whenever the theme changes.
  readonly property string themeDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/current"
  property var themeScope: ({})
  property var themeColors: ({})
  function hexOr(value, fallback) {
    var v = String(value || "")
    return /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(v) ? v : fallback
  }
  readonly property color gaugeColor: hexOr(themeScope.ch2, hexOr(themeColors.cyan, hexOr(themeColors.blue, Commons.Color.accent)))
  readonly property color warnColor: hexOr(themeScope.red, hexOr(themeColors.red, Commons.Color.urgent))

  function parseScope(text) {
    try {
      var parsed = JSON.parse(String(text || "{}"))
      var out = {}
      for (var k in parsed) if (/^[a-z0-9_]{1,24}$/.test(k)) out[k] = hexOr(parsed[k], undefined)
      return out
    } catch (e) { return ({}) }
  }

  function parseColorsToml(text) {
    var out = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length && i < 400; i++) {
      var m = lines[i].match(/^\s*([a-z_]{1,32})\s*=\s*"(#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?)"/)
      if (m) out[m[1]] = m[2]
    }
    return out
  }

  function plain(text) {
    return String(text || "").replace(/[<>&]/g, "")
  }

  function barTooltip() {
    if (!llm.polled) return ""
    if (!llm.online) return llm.installed ? strings.t("tip.stopped") : strings.t("tip.notSetUp")
    if (!llm.loadedModel) return strings.t("tip.idle")
    var state = llm.thinking ? strings.t("tip.generating")
      : llm.loadedAsleep ? strings.t("tip.asleep") : strings.t("tip.ready")
    var line = strings.t("tip.model").arg(plain(llm.loadedModel.id)).arg(state)
    if (llm.vramMiB >= 0 && llm.gpuTotalMiB > 0)
      line += "\n" + strings.t("tip.vram").arg(gib(llm.vramMiB)).arg(gib(llm.gpuTotalMiB))
    if (llm.gpuNearlyFull) line += "\n" + strings.t("tip.full")
    return line
  }

  // [glyph, i18n key, handler]
  readonly property var actions: [
    { glyph: "󰇚", key: "action.pull", run: function() { llm.runCli("pull"); root.close() } },
    { glyph: "󰍛", key: "action.llmfit", run: function() { llm.runCli("fit"); root.close() } },
    { glyph: "󰖟", key: "action.webui", run: function() { llm.openWebUi(); root.close() } },
    { glyph: "󰏫", key: "action.presets", run: function() { llm.runCli("edit"); root.close() } },
    { glyph: "󰦪", key: "action.logs", run: function() { llm.runCli("logs"); root.close() } }
  ]

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function gib(mib) {
    return Commons.I18n.formatNumber(mib / 1024, 1)
  }

  function heroMeta() {
    if (!llm.polled) return strings.t("hero.checking")
    if (llm.desiredServer === 1) return strings.t("hero.starting")
    if (llm.desiredServer === 0) return strings.t("hero.stopping")
    if (!llm.online) {
      if (llm.unitState === "failed") return strings.t("hero.failed")
      if (llm.unitState === "activating") return strings.t("hero.starting")
      if (!llm.installed) return strings.t("hero.notSetUp")
      return strings.t("hero.stopped")
    }
    for (var i = 0; i < llm.models.length; i++)
      if (llm.statusOf(llm.models[i]) === "loading") return strings.t("hero.loading").arg(llm.models[i].id)
    if (llm.loadedModel && llm.thinking) return strings.t("hero.thinking").arg(llm.loadedModel.id)
    if (llm.loadedModel) return llm.loadedAsleep
      ? strings.t("hero.asleep").arg(llm.loadedModel.id)
      : strings.t("hero.serving").arg(llm.loadedModel.id)
    return strings.tn("hero.idle", llm.models.length).arg(Commons.I18n.formatNumber(llm.models.length))
  }

  function statusText(m) {
    var st = llm.statusOf(m)
    var parts = [strings.t("status." + st)]
    if (st === "loaded" && llm.vramMiB >= 0)
      parts[0] = strings.t("status.loadedVram").arg(gib(llm.vramMiB))
    if (m.vision) parts.push(strings.t("model.vision"))
    if (m.aliases.length > 0) parts.push(strings.t("model.alias").arg(m.aliases.join(", ")))
    return parts.join(" · ")
  }

  function ensureCursor() {
    if (focusSection === "models" && llm.models.length === 0) focusSection = "actions"
    modelIndex = Math.max(0, Math.min(modelIndex, llm.models.length - 1))
    actionIndex = Math.max(0, Math.min(actionIndex, actions.length - 1))
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (focusSection === "actions" && dx !== 0) {
      actionIndex = Math.max(0, Math.min(actions.length - 1, actionIndex + dx))
      return
    }
    if (dy === 0) return
    if (focusSection === "header") {
      if (dy > 0) {
        if (llm.models.length > 0) { focusSection = "models"; modelIndex = 0 }
        else focusSection = "actions"
      }
    } else if (focusSection === "models") {
      if (dy < 0 && modelIndex === 0) focusSection = "header"
      else if (dy > 0 && modelIndex === llm.models.length - 1) focusSection = "actions"
      else modelIndex = Math.max(0, Math.min(llm.models.length - 1, modelIndex + dy))
    } else if (focusSection === "actions" && dy < 0) {
      if (llm.models.length > 0) { focusSection = "models"; modelIndex = llm.models.length - 1 }
      else focusSection = "header"
    }
    scrollCursorIntoView()
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") { llm.toggleServer(); if (!llm.installed) root.close() }
    else if (focusSection === "models") llm.toggleModel(llm.models[modelIndex])
    else if (focusSection === "actions") actions[actionIndex].run()
  }

  function scrollCursorIntoView() {
    if (!panelFlick) return
    if (focusSection === "header") { panelFlick.contentY = 0; return }
    if (focusSection === "actions") { panelFlick.contentY = Math.max(0, panelFlick.contentHeight - panelFlick.height); return }
    if (!modelColumn || modelIndex >= modelColumn.children.length) return
    var item = modelColumn.children[modelIndex]
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    focusSection = "header"
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  FileView {
    path: root.themeDir + "/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { scopeView.reload(); colorsView.reload() }
    onLoadFailed: { scopeView.reload(); colorsView.reload() }
  }
  FileView {
    id: scopeView
    path: root.themeDir + "/theme/scope.json"
    printErrors: false
    onLoaded: root.themeScope = root.parseScope(text())
    onLoadFailed: root.themeScope = ({})
  }
  FileView {
    id: colorsView
    path: root.themeDir + "/theme/colors.toml"
    printErrors: false
    onLoaded: root.themeColors = root.parseColorsToml(text())
    onLoadFailed: root.themeColors = ({})
  }

  Service {
    id: llm
    settings: root.settings
    watching: root.opened
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { llm.refresh(true); return "ok" }
    function unload(): string { llm.unloadAll(); return "ok" }
    function status(): string {
      // English on purpose: scripts read this.
      if (!llm.online) return "offline"
      return "mode=" + root.iconMode + (llm.loadedModel ? " model=" + llm.loadedModel.id : "")
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.barTooltip()
    iconComponent: Component {
      Item {
        LlmIcon {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          iconSize: button.iconSize
          color: root.barForeground
          gaugeColor: root.gaugeColor
          warnColor: root.warnColor
          gauge: llm.vramFraction
          warn: llm.gpuNearlyFull
          mode: root.iconMode
        }
      }
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) llm.unloadAll()
      else if (b === Qt.MiddleButton) llm.openWebUi()
      else root.toggle()
    }
  }


  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(560))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      property alias modelColumn: modelColumn
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "r") llm.refresh(true)
        else if (k === "s") llm.toggleServer()
        else if (k === "u") llm.unloadAll()
        else if (k === "p") root.actions[0].run()
        else if (k === "f") root.actions[1].run()
        else if (k === "w") root.actions[2].run()
        else if (k === "e") root.actions[3].run()
        else if (k === "l") root.actions[4].run()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.cursorActive && root.focusSection === "header"
            function focusHero() { root.cursorActive = true; root.focusSection = "header" }

            PanelHero {
              id: hero
              width: parent.width
              title: strings.t("title")
              meta: root.heroMeta()
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                LlmIcon {
                  iconSize: Style.font.display
                  grid: 5
                  color: root.foreground
                  gaugeColor: root.gaugeColor
                  warnColor: root.warnColor
                  gauge: llm.vramFraction
                  warn: llm.gpuNearlyFull
                  mode: root.iconMode
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: llm.serverOn
                  busy: llm.busy || llm.desiredServer !== -1
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: { llm.toggleServer(); if (!llm.installed) root.close() }

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: !llm.installed ? strings.t("server.setup")
                      : llm.serverOn ? strings.t("server.stop") : strings.t("server.start")
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: llm.lastError !== ""
            width: parent.width
            text: llm.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            visible: llm.online
            width: parent.width
            spacing: Style.spacing.labelGap
            InfoPair {
              label: strings.t("info.api")
              value: llm.baseUrl + "/v1"
            }
            InfoPair {
              visible: llm.vramMiB >= 0 && llm.gpuTotalMiB > 0
              label: strings.t("info.vram")
              value: strings.t("info.vramValue").arg(root.gib(llm.vramMiB)).arg(root.gib(llm.gpuTotalMiB))
              valueColor: llm.gpuNearlyFull ? root.warnColor : root.gaugeColor
            }

            // Legend for the icon's two halves, drawn with the same triangles.
            Row {
              width: parent.width
              spacing: Style.space(14)
              topPadding: Style.space(4)

              Row {
                spacing: Style.space(5)
                Text { textFormat: Text.PlainText; text: "◣"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { textFormat: Text.PlainText; text: strings.t("legend.attention"); color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
              }
              Row {
                spacing: Style.space(5)
                Text { textFormat: Text.PlainText; text: "◥"; color: llm.gpuNearlyFull ? root.warnColor : root.gaugeColor; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { textFormat: Text.PlainText; text: strings.t("legend.vram"); color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: llm.polled && !llm.online && llm.desiredServer === -1
            width: parent.width
            text: !llm.installed ? strings.t("offline.setupHelp")
              : llm.unitState === "failed" ? strings.t("offline.failedHelp") : strings.t("offline.help")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            visible: llm.online
            foreground: root.foreground
          }

          Column {
            visible: llm.online
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: strings.t("models.header")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: llm.models.length === 0
              width: parent.width
              text: strings.t("models.empty")
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Column {
              id: modelColumn
              visible: llm.models.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: llm.models
                ModelRow {
                  required property var modelData
                  required property int index
                  width: modelColumn.width
                  entry: modelData
                  rowIndex: index
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Row {
            id: actionRow
            spacing: Style.space(6)
            anchors.horizontalCenter: parent.horizontalCenter

            Repeater {
              model: root.actions
              PanelActionButton {
                required property var modelData
                required property int index
                iconText: modelData.glyph
                tooltipText: strings.t(modelData.key)
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === index
                enabled: modelData.key !== "action.webui" || llm.online
                onHovered: function(on) {
                  if (!on) return
                  root.cursorActive = true
                  root.focusSection = "actions"
                  root.actionIndex = index
                }
                onClicked: modelData.run()
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: strings.t("keys.hint")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  component ModelRow: CursorSurface {
    id: row
    property var entry: null
    property int rowIndex: 0
    readonly property string st: llm.statusOf(entry)
    readonly property bool isOn: st === "loaded" || st === "sleeping" || st === "loading"

    hasCursor: root.cursorActive && root.focusSection === "models" && root.modelIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.focusSection = "models"
        root.modelIndex = row.rowIndex
      }
      onClicked: llm.toggleModel(row.entry)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: row.st === "loaded" || row.st === "sleeping" ? "󰄯" : (row.st === "failed" ? "󰅙" : (row.isOn || row.st === "unloading" ? "󰪞" : "󰄰"))
        color: row.st === "loaded" ? root.accent : row.st === "sleeping" ? root.dim : (row.st === "failed" ? root.urgent : root.dim)
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.entry ? row.entry.id : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideMiddle
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.entry ? root.statusText(row.entry) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: row.isOn ? "󰓛" : "󰐊"
        tooltipText: row.isOn ? strings.t("model.unload") : strings.t("model.load")
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: llm.toggleModel(row.entry)
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property color valueColor: root.foreground
    width: parent.width
    spacing: Style.space(8)

    Text {
      id: infoLabel
      textFormat: Text.PlainText
      text: parent.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width - infoLabel.implicitWidth - parent.spacing
      horizontalAlignment: Text.AlignRight
      text: parent.value
      color: parent.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
    }
  }
}

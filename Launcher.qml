import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property bool opened: false
  property bool searchMode: false
  property bool editMode: false
  property bool addOpen: false
  property bool dataReady: false
  property string formError: ""
  property string filterText: ""
  property int selectedIndex: 0
  property int layoutContentCount: 0
  property var services: []

  readonly property string pluginId: "io.github.elvis-christian.homelab-launcher"
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + pluginId
  readonly property string dataDir: Quickshell.env("HOME") + "/.config/omarchy/homelab-launcher"
  readonly property string assetsDir: pluginDir + "/assets"
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color selectedBorder: Color.menu.selectedBorder
  readonly property var cardBorderSpec: Border.flat(Color.accent, Math.max(1, Style.space(2)))
  readonly property int margin: Style.spacing.panelPadding
  readonly property int gap: Style.spacing.lg
  readonly property int columns: bestColumnCount(layoutContentCount)
  readonly property int rows: Math.max(1, Math.ceil((services.length + 1) / columns))
  readonly property int cardWidth: Math.min(Style.space(1000), panel.width - Style.gapsOut * 8)
  readonly property int cardHeight: Math.min(Style.space(650), panel.height - Style.gapsOut * 8)
  readonly property int cellWidth: Math.floor(grid.width / columns)
  readonly property int cellHeight: Math.floor(grid.height / rows)

  function open(_payloadJson) {
    opened = true
    searchMode = false
    editMode = false
    addOpen = false
    filterText = ""
    selectedIndex = 0
    rebuild()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { opened = false }

  function dismiss() {
    if (addOpen) {
      closeAddDialog()
      return
    }
    opened = false
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
  }

  function loadServices(raw) {
    try {
      var parsed = JSON.parse(raw || "{}")
      services = Array.isArray(parsed.services) ? parsed.services : []
    } catch (e) {
      console.warn("HomeLab Launcher: services.json inválido:", e)
      services = []
    }
    rebuild()
  }

  function normalized(value) {
    return String(value || "").toLowerCase()
      .normalize("NFD").replace(/[\u0300-\u036f]/g, "")
  }

  function bestColumnCount(count) {
    var candidates = panel.width < 900 ? [3] : [5]
    var best = candidates[0]
    var bestPadding = 1000000
    for (var i = 0; i < candidates.length; i++) {
      var candidate = candidates[i]
      var padding = count > 0 ? (candidate - (count % candidate)) % candidate : 0
      if (padding < bestPadding || (padding === bestPadding && candidate > best)) {
        best = candidate
        bestPadding = padding
      }
    }
    return best
  }

  function rebuild() {
    var needle = normalized(filterText)
    displayModel.clear()
    for (var i = 0; i < services.length; i++) {
      var service = services[i]
      var haystack = normalized(service.name + " " + service.group + " " + service.url)
      if (!needle || haystack.indexOf(needle) !== -1) {
        displayModel.append({
          name: service.name,
          url: service.url,
          icon: service.icon,
          iconScale: Number(service.iconScale || 1),
          monochrome: service.monochrome === true,
          sourceIndex: i,
          isAdd: false,
          isSpacer: false
        })
      }
    }
    if (editMode && !needle) {
      displayModel.append({
        name: "Novo atalho",
        url: "",
        icon: "",
        iconScale: 1,
        monochrome: false,
        sourceIndex: -1,
        isAdd: true,
        isSpacer: false
      })
    }
    layoutContentCount = displayModel.count
    var targetColumns = bestColumnCount(layoutContentCount)
    var spacerCount = !needle && layoutContentCount > 0
      ? (targetColumns - (layoutContentCount % targetColumns)) % targetColumns
      : 0
    for (var spacer = 0; spacer < spacerCount; spacer++) {
      displayModel.append({
        name: "Omarchy",
        url: "https://omarchy.org",
        icon: "/usr/share/omarchy/icon.png",
        iconScale: 1,
        monochrome: true,
        sourceIndex: -1,
        isAdd: false,
        isSpacer: true
      })
    }
    layoutContentCount = displayModel.count
    if (layoutContentCount === 0) selectedIndex = 0
    else selectedIndex = Math.max(0, Math.min(selectedIndex, layoutContentCount - 1))
    Qt.callLater(function() {
      if (displayModel.count > 0) grid.positionViewAtIndex(selectedIndex, GridView.Contain)
    })
  }

  function setFilter(value) {
    filterText = value
    selectedIndex = 0
    rebuild()
  }

  function move(dx, dy) {
    if (layoutContentCount === 0) return
    var next = selectedIndex + dx + dy * columns
    if (next < 0) next = layoutContentCount - 1
    if (next >= layoutContentCount) next = 0
    selectedIndex = next
    grid.positionViewAtIndex(selectedIndex, GridView.Contain)
  }

  function activate(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.isSpacer) {
      dismiss()
      Quickshell.execDetached(["xdg-open", row.url])
      return
    }
    if (row.isAdd) {
      openAddDialog()
      return
    }
    if (editMode) return
    var target = row.url
    dismiss()
    Quickshell.execDetached(["xdg-open", target])
  }

  function iconSource(value) {
    var icon = String(value || "").trim()
    if (/^https?:\/\//i.test(icon) || /^file:\/\//i.test(icon)) return icon
    if (icon.charAt(0) === "/") return "file://" + icon
    return "file://" + assetsDir + "/" + icon
  }

  function persistServices(nextServices) {
    services = nextServices
    servicesFile.setText(JSON.stringify({ services: nextServices }, null, 2) + "\n")
    rebuild()
  }

  function toggleEditMode() {
    editMode = !editMode
    addOpen = false
    filterText = ""
    searchMode = false
    selectedIndex = 0
    rebuild()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function deleteService(sourceIndex) {
    if (sourceIndex < 0 || sourceIndex >= services.length) return
    var next = services.slice()
    next.splice(sourceIndex, 1)
    persistServices(next)
  }

  function reorderService(sourceIndex, dropX, dropY) {
    if (sourceIndex < 0 || sourceIndex >= services.length) return
    var column = Math.max(0, Math.min(columns - 1, Math.floor(dropX / cellWidth)))
    var row = Math.max(0, Math.floor(dropY / cellHeight))
    var targetIndex = Math.max(0, Math.min(services.length - 1, row * columns + column))
    moveService(JSON.stringify({ from: sourceIndex, to: targetIndex }))
  }

  function moveService(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { return "invalid" }
    var sourceIndex = Number(payload.from)
    var targetIndex = Number(payload.to)
    if (!isFinite(sourceIndex) || !isFinite(targetIndex)) return "invalid"
    sourceIndex = Math.round(sourceIndex)
    targetIndex = Math.round(targetIndex)
    if (sourceIndex < 0 || sourceIndex >= services.length) return "invalid"
    targetIndex = Math.max(0, Math.min(services.length - 1, targetIndex))
    if (targetIndex === sourceIndex) {
      rebuild()
      return "ok"
    }
    var next = services.slice()
    var moved = next.splice(sourceIndex, 1)[0]
    next.splice(targetIndex, 0, moved)
    persistServices(next)
    selectedIndex = targetIndex
    return "ok"
  }

  function openAddDialog() {
    addOpen = true
    formError = ""
    nameField.text = ""
    urlField.text = ""
    iconField.text = ""
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function closeAddDialog() {
    addOpen = false
    formError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function addService() {
    var name = nameField.text.trim()
    var url = urlField.text.trim()
    var icon = iconField.text.trim()
    if (!name || !url || !icon) {
      formError = "Preencha nome, endereço e ícone."
      return
    }
    if (!/^(https?:\/\/|file:\/\/|\/)/i.test(icon) && !/\.(svg|png)$/i.test(icon)) {
      formError = "Use uma URL, caminho local ou arquivo SVG/PNG."
      return
    }
    for (var i = 0; i < services.length; i++) {
      if (String(services[i].url || "") === url) {
        formError = "Esse endereço já existe."
        return
      }
    }
    var next = services.slice()
    next.push({ name: name, url: url, icon: icon, group: "HomeLab" })
    addOpen = false
    persistServices(next)
  }

  ListModel { id: displayModel }

  Process {
    id: dataDirProcess
    command: ["mkdir", "-p", root.dataDir]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("HomeLab Launcher: could not create data directory")
        return
      }
      root.dataReady = true
      servicesFile.reload()
    }
  }

  Component.onCompleted: dataDirProcess.running = true

  FileView {
    id: servicesFile
    path: root.dataDir + "/services.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var raw = text()
      if (root.dataReady && String(raw || "").trim() === "") {
        raw = JSON.stringify({ services: [] }, null, 2) + "\n"
        setText(raw)
      }
      root.loadServices(raw)
    }
    onFileChanged: reload()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-homelab-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }

    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.cardBorderSpec
      padding: root.margin

      MouseArea { anchors.fill: parent; onClicked: function(mouse) { mouse.accepted = true } }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.addOpen) {
            if (event.key === Qt.Key_Escape) {
              root.closeAddDialog()
              event.accepted = true
            }
            return
          } else if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            root.searchMode = false
            event.accepted = true
          } else if (event.key === Qt.Key_Slash && !root.searchMode) {
            root.searchMode = true
            event.accepted = true
          } else if (event.key === Qt.Key_Backspace && root.searchMode) {
            root.setFilter(root.filterText.slice(0, -1))
            event.accepted = true
          } else if (event.key === Qt.Key_Left || (!root.searchMode && event.text === "h")) {
            root.move(-1, 0); event.accepted = true
          } else if (event.key === Qt.Key_Right || (!root.searchMode && event.text === "l")) {
            root.move(1, 0); event.accepted = true
          } else if (event.key === Qt.Key_Up || (!root.searchMode && event.text === "k")) {
            root.move(0, -1); event.accepted = true
          } else if (event.key === Qt.Key_Down || (!root.searchMode && event.text === "j")) {
            root.move(0, 1); event.accepted = true
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            root.move((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1, 0)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.activate(root.selectedIndex); event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32) {
            root.searchMode = true
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.gap

        Item {
          width: parent.width
          height: Style.space(58)

          Column {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - editControl.width - root.gap
            spacing: Style.spacing.xs

            Text {
              width: parent.width
              text: root.searchMode ? ("HOMELAB  /  " + (root.filterText || "BUSCAR…")) : "HOMELAB"
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
              elide: Text.ElideRight
            }

            Text {
              id: countLabel
              width: parent.width
              text: root.editMode ? "arraste para reorganizar" : (root.services.length + " atalhos")
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              font.weight: Font.Normal
              opacity: 0.72
              elide: Text.ElideRight
            }
          }

          Column {
            id: editControl
            width: Math.max(editLabel.implicitWidth, editSwitch.implicitWidth)
            height: parent.height
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Text {
              id: editLabel
              anchors.horizontalCenter: parent.horizontalCenter
              text: "EDIT"
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              font.weight: Font.Medium
            }

            ToggleSwitch {
              id: editSwitch
              anchors.horizontalCenter: parent.horizontalCenter
              checked: root.editMode
              foreground: root.foreground
              accent: Color.accent
              trackHeight: Style.space(18)
              rounded: false
              cursorRing: false
              onToggled: root.toggleEditMode()

              PanelToolTip {
                visible: editSwitch.containsMouse
                text: root.editMode ? "Sair da edição" : "Editar atalhos"
                fontFamily: Style.font.menuFamily
              }
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: root.borderColor; opacity: 0.32 }

        GridView {
          id: grid
          width: parent.width
          height: parent.height - y
          clip: true
          interactive: false
          model: displayModel
          cellWidth: root.cellWidth
          cellHeight: root.cellHeight
          boundsBehavior: Flickable.StopAtBounds
          keyNavigationEnabled: false

          delegate: Rectangle {
            id: serviceCard
            required property int index
            required property string name
            required property string url
            required property string icon
            required property real iconScale
            required property bool monochrome
            required property int sourceIndex
            required property bool isAdd
            required property bool isSpacer

            width: root.cellWidth - root.gap
            height: root.cellHeight - root.gap
            radius: Style.cornerRadius
            z: dragHandler.active ? 20 : 0
            scale: dragHandler.active ? 1.045 : 1.0
            opacity: dragHandler.active ? 0.94 : 1.0
            color: isAdd
              ? Util.alpha(root.selectedText, 0.025)
              : index === root.selectedIndex
              ? Util.alpha(root.selectedText, 0.085)
              : (hover.hovered ? Util.alpha(root.foreground, 0.055) : "transparent")
            border.width: 1
            border.color: index === root.selectedIndex
              ? Util.alpha(root.selectedText, 0.52)
              : (hover.hovered ? Util.alpha(root.foreground, 0.30) : root.borderColor)

            Behavior on color { ColorAnimation { duration: 100 } }
            Behavior on border.color { ColorAnimation { duration: 100 } }
            Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 90 } }

            Row {
              id: serviceContent
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.lg + 3
              anchors.rightMargin: Style.spacing.xxl
              spacing: Style.spacing.lg
              visible: true

              Item {
                id: iconWell
                width: Style.space(32)
                height: width
                anchors.verticalCenter: parent.verticalCenter

                Image {
                  id: iconSource
                  width: Math.round(Style.space(27) * iconScale)
                  height: width
                  anchors.centerIn: parent
                  source: isAdd ? "" : root.iconSource(icon)
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  sourceSize.width: 192
                  sourceSize.height: 192
                  smooth: true
                  mipmap: true
                  visible: !isAdd && !monochrome
                }

                MultiEffect {
                  anchors.fill: iconSource
                  source: iconSource
                  visible: !isAdd && monochrome
                  brightness: 1.0
                  colorization: 1.0
                  colorizationColor: index === root.selectedIndex ? root.selectedText : root.foreground
                }

                Text {
                  anchors.centerIn: parent
                  visible: isAdd
                  text: "+"
                  color: root.selectedText
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.title
                  font.weight: Font.Light
                }
              }

              Text {
                id: serviceName
                width: parent.width - iconWell.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                text: isAdd ? "Novo atalho" : name
                color: index === root.selectedIndex ? root.selectedText : root.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.Medium
                elide: Text.ElideRight
              }
            }

            Rectangle {
              visible: root.editMode && !isAdd && !isSpacer
              z: 10
              width: Style.space(25)
              height: width
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.spacing.sm
              radius: width / 2
              color: removeMouse.containsMouse ? Util.alpha(Color.urgent, 0.30) : Util.alpha(Color.urgent, 0.16)
              border.width: 1
              border.color: Util.alpha(Color.urgent, 0.72)

              Text {
                anchors.centerIn: parent
                text: "−"
                color: root.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.title
              }

              MouseArea {
                id: removeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) {
                  mouse.accepted = true
                  root.deleteService(sourceIndex)
                }
              }
            }

            DragHandler {
              id: dragHandler
              property bool hadActiveDrag: false
              enabled: root.editMode && !isAdd && !isSpacer
              target: serviceCard
              onActiveChanged: {
                if (active) {
                  hadActiveDrag = true
                  root.selectedIndex = index
                } else if (enabled && hadActiveDrag) {
                  hadActiveDrag = false
                  var center = serviceCard.mapToItem(grid, serviceCard.width / 2, serviceCard.height / 2)
                  var from = sourceIndex
                  var dropX = center.x
                  var dropY = center.y
                  Qt.callLater(function() { root.reorderService(from, dropX, dropY) })
                }
              }
            }

            HoverHandler {
              id: hover
              cursorShape: dragHandler.active ? Qt.ClosedHandCursor
                : (root.editMode && !isAdd && !isSpacer ? Qt.OpenHandCursor : Qt.PointingHandCursor)
              onHoveredChanged: if (hovered) root.selectedIndex = index
            }
            TapHandler { onTapped: root.activate(index) }
          }
        }
      }

      Rectangle {
        anchors.fill: parent
        visible: root.addOpen
        z: 50
        color: Util.alpha(root.background, 0.84)

        MouseArea { anchors.fill: parent; onClicked: root.closeAddDialog() }

        BorderSurface {
          width: Math.min(Style.space(520), parent.width - root.margin * 4)
          height: Style.space(280)
          anchors.centerIn: parent
          color: root.background
          borderSpec: root.cardBorderSpec
          radius: Math.max(Style.space(12), Style.cornerRadius)
          padding: Style.spacing.panelPadding

          MouseArea { anchors.fill: parent; onClicked: function(mouse) { mouse.accepted = true } }

          Column {
            anchors.fill: parent
            anchors.margins: Style.spacing.panelPadding
            spacing: Style.spacing.xxl

            Text {
              text: "NOVO ATALHO"
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
            }

            TextField {
              id: nameField
              width: parent.width
              placeholderText: "Nome"
              onAccepted: urlField.forceActiveFocus()
            }

            TextField {
              id: urlField
              width: parent.width
              placeholderText: "Endereço — https://… ou http://…"
              onAccepted: iconField.forceActiveFocus()
            }

            TextField {
              id: iconField
              width: parent.width
              placeholderText: "Ícone — URL ou caminho para SVG/PNG"
              onAccepted: root.addService()
            }

            Text {
              width: parent.width
              text: root.formError || "O ícone pode ser uma URL, caminho absoluto ou nome de arquivo em assets/."
              color: root.formError ? Color.urgent : Color.muted
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Item { width: 1; height: Style.spacing.sm }

            Row {
              anchors.right: parent.right
              spacing: Style.spacing.lg

              Button {
                text: "Cancelar"
                bordered: true
                focusable: true
                onClicked: root.closeAddDialog()
              }

              Button {
                text: "Adicionar"
                selected: true
                bordered: true
                focusable: true
                onClicked: root.addService()
              }
            }
          }
        }
      }
    }
  }
}

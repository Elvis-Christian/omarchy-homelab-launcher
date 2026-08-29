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
  property int editingSourceIndex: -1
  property string formError: ""
  property string filterText: ""
  property int selectedIndex: 0
  property int layoutContentCount: 0
  property var services: []
  property bool importingIcon: false
  property bool iconImportTimedOut: false
  property var pendingService: null
  property bool servicesReadPending: false
  property string pendingServicesWrite: ""
  property string activeServicesWrite: ""
  property var iconCache: ({})
  property var iconReadPending: ({})
  property var iconReadQueue: []
  property string activeManagedIcon: ""

  readonly property string pluginId: "io.github.elvis-christian.homelab-launcher"
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + pluginId
  readonly property string dataDir: Quickshell.env("HOME") + "/.config/omarchy/homelab-launcher"
  readonly property string assetsDir: pluginDir + "/assets"
  readonly property string servicesPath: dataDir + "/services.json"
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
  readonly property int cellHeight: Math.floor((grid.height - grid.topMargin) / rows)
  readonly property int maxServices: 50
  readonly property int maxNameLength: 100
  readonly property int maxUrlLength: 2048
  readonly property int maxIconPathLength: 4096

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
      var incoming = Array.isArray(parsed.services) ? parsed.services : []
      var safeServices = []
      for (var i = 0; i < incoming.length && safeServices.length < maxServices; i++) {
        var service = incoming[i]
        if (!service || typeof service !== "object") continue
        var name = typeof service.name === "string" ? service.name.trim() : ""
        var url = typeof service.url === "string" ? service.url.trim() : ""
        var icon = typeof service.icon === "string" ? service.icon.trim() : ""
        if (!name || name.length > maxNameLength || !safeHttpUrl(url)) continue
        safeServices.push({
          name: name,
          url: url,
          // Preserve old shortcuts, but never hand an untrusted legacy icon path
          // to Image. Editing the shortcut imports it into managed storage.
          icon: safeIconReference(icon) ? icon : "",
          group: typeof service.group === "string" ? service.group.slice(0, maxNameLength) : "HomeLab",
          iconScale: Math.max(0.25, Math.min(2, Number(service.iconScale) || 1)),
          monochrome: service.monochrome === true
        })
      }
      services = safeServices
    } catch (e) {
      console.warn("HomeLab Launcher: invalid services.json:", e)
      services = []
    }
    rebuild()
  }

  function normalized(value) {
    return String(value || "").toLowerCase()
      .normalize("NFD").replace(/[\u0300-\u036f]/g, "")
  }

  function safeHttpUrl(value) {
    var url = String(value || "").trim()
    return url.length <= maxUrlLength && /^https?:\/\/[^\s]+$/i.test(url)
  }

  function safeIconReference(value) {
    var icon = String(value || "").trim()
    return icon.length <= maxIconPathLength && managedIconReference(icon)
  }

  function managedIconReference(value) {
    var icon = String(value || "").trim()
    var prefix = dataDir + "/icons/"
    if (icon.indexOf(prefix) !== 0) return false
    return /^[a-f0-9]{64}\.(?:png|svg)$/.test(icon.slice(prefix.length))
  }

  function safeIconInput(value) {
    var icon = String(value || "").trim()
    if (!icon || icon.length > maxIconPathLength || /^https?:\/\//i.test(icon)) return false
    if (/^file:\/\//i.test(icon) && !/^file:\/\/(?:localhost)?\//i.test(icon)) return false
    return /\.(?:png|svg)$/i.test(icon)
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
        name: "New shortcut",
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
    if (!safeHttpUrl(target)) {
      console.warn("HomeLab Launcher: blocked unsafe shortcut URL")
      return
    }
    dismiss()
    Quickshell.execDetached(["xdg-open", target])
  }

  function iconSource(value) {
    var icon = String(value || "").trim()
    // Never hand remote URLs to QML's image loader. This plugin stays loaded in
    // omarchy-shell, and that loader provides no per-request deadline or response
    // size limit. Returning an empty source also protects existing configurations
    // that may still contain a remote icon.
    if (icon === "/usr/share/omarchy/icon.png") return "file://" + icon
    if (!managedIconReference(icon)) return ""
    if (iconCache[icon] !== undefined) return iconCache[icon]
    queueManagedIcon(icon)
    return ""
  }

  function queueManagedIcon(icon) {
    if (iconCache[icon] !== undefined || iconReadPending[icon]) return
    var pending = Object.assign({}, iconReadPending)
    pending[icon] = true
    iconReadPending = pending
    var queue = iconReadQueue.slice()
    queue.push(icon)
    iconReadQueue = queue
    Qt.callLater(startManagedIconRead)
  }

  function startManagedIconRead() {
    if (managedIconProcess.running || iconReadQueue.length === 0) return
    var queue = iconReadQueue.slice()
    activeManagedIcon = queue.shift()
    iconReadQueue = queue
    managedIconProcess.command = [root.pluginDir + "/scripts/import-icon", "--data-url", activeManagedIcon]
    managedIconTimeout.restart()
    managedIconProcess.running = true
  }

  function persistServices(nextServices) {
    services = nextServices
    pendingServicesWrite = JSON.stringify({ services: nextServices })
    startServicesWrite()
    rebuild()
  }

  function requestServicesRead() {
    if (!dataReady) return
    if (servicesReadProcess.running) {
      servicesReadPending = true
      return
    }
    servicesReadTimeout.restart()
    servicesReadProcess.running = true
  }

  function startServicesWrite() {
    if (servicesWriteProcess.running || !pendingServicesWrite) return
    activeServicesWrite = pendingServicesWrite
    pendingServicesWrite = ""
    servicesWriteTimeout.restart()
    servicesWriteProcess.running = true
  }

  function toggleEditMode() {
    editMode = !editMode
    addOpen = false
    editingSourceIndex = -1
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
    editingSourceIndex = -1
    addOpen = true
    formError = ""
    nameField.text = ""
    urlField.text = ""
    iconField.text = ""
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function openEditDialog(sourceIndex) {
    if (sourceIndex < 0 || sourceIndex >= services.length) return
    var service = services[sourceIndex]
    editingSourceIndex = sourceIndex
    addOpen = true
    formError = ""
    nameField.text = String(service.name || "")
    urlField.text = String(service.url || "")
    iconField.text = String(service.icon || "")
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function closeAddDialog() {
    if (importingIcon) return
    addOpen = false
    editingSourceIndex = -1
    formError = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function saveService() {
    if (importingIcon) return
    var name = nameField.text.trim()
    var url = urlField.text.trim()
    var icon = iconField.text.trim()
    if (!name || !url || !icon) {
      formError = "Enter a name, address, and icon."
      return
    }
    if (name.length > maxNameLength) {
      formError = "Name must not exceed " + maxNameLength + " characters."
      return
    }
    if (!safeHttpUrl(url)) {
      formError = "Address must be an HTTP or HTTPS URL."
      return
    }
    if (icon.length > maxIconPathLength) {
      formError = "Icon path is too long."
      return
    }
    if (editingSourceIndex < 0 && services.length >= maxServices) {
      formError = "The launcher supports up to " + maxServices + " shortcuts."
      return
    }
    if (!safeIconInput(icon)) {
      formError = "Only local SVG/PNG icon paths are supported."
      return
    }
    for (var i = 0; i < services.length; i++) {
      if (i !== editingSourceIndex && String(services[i].url || "") === url) {
        formError = "This address already exists."
        return
      }
    }
    pendingService = ({ name: name, url: url, icon: icon, sourceIndex: editingSourceIndex })
    importingIcon = true
    iconImportTimedOut = false
    formError = "Importing icon…"
    iconImportProcess.command = [root.pluginDir + "/scripts/import-icon", icon,
                                 root.assetsDir, root.dataDir + "/icons"]
    iconImportTimeout.restart()
    iconImportProcess.running = true
  }

  ListModel { id: displayModel }

  Process {
    id: servicesReadProcess
    command: [root.pluginDir + "/scripts/services-store", "read", root.servicesPath]
    stdout: StdioCollector { id: servicesReadOutput; waitForEnd: true }
    stderr: StdioCollector { id: servicesReadError; waitForEnd: true }
    onExited: function(exitCode) {
      servicesReadTimeout.stop()
      root.dataReady = true
      if (exitCode === 0) root.loadServices(servicesReadOutput.text)
      else {
        console.warn("HomeLab Launcher:", String(servicesReadError.text || "Could not read services safely.").trim())
        root.loadServices("")
      }
      if (root.servicesReadPending) {
        root.servicesReadPending = false
        root.requestServicesRead()
      }
    }
  }

  Process {
    id: servicesWriteProcess
    command: [root.pluginDir + "/scripts/services-store", "write", root.servicesPath]
    stdinEnabled: true
    stderr: StdioCollector { id: servicesWriteError; waitForEnd: true }
    onStarted: write(root.activeServicesWrite + "\n")
    onExited: function(exitCode) {
      servicesWriteTimeout.stop()
      root.activeServicesWrite = ""
      if (exitCode !== 0)
        console.warn("HomeLab Launcher:", String(servicesWriteError.text || "Could not save services safely.").trim())
      root.startServicesWrite()
    }
  }

  Process {
    id: managedIconProcess
    stdout: StdioCollector { id: managedIconOutput; waitForEnd: true }
    stderr: StdioCollector { id: managedIconError; waitForEnd: true }
    onExited: function(exitCode) {
      managedIconTimeout.stop()
      var icon = root.activeManagedIcon
      var output = String(managedIconOutput.text || "").trim()
      var cache = Object.assign({}, root.iconCache)
      // 128 KiB becomes at most ~175 KiB after base64 encoding. Together
      // with maxServices this also bounds the aggregate in-shell icon cache.
      cache[icon] = exitCode === 0 && output.length <= 180000
        && /^data:image\/(?:png|svg\+xml);base64,/.test(output) ? output : ""
      root.iconCache = cache
      var pending = Object.assign({}, root.iconReadPending)
      delete pending[icon]
      root.iconReadPending = pending
      if (!cache[icon])
        console.warn("HomeLab Launcher:", String(managedIconError.text || "Could not load managed icon safely.").trim())
      root.activeManagedIcon = ""
      root.startManagedIconRead()
    }
  }

  Timer {
    id: managedIconTimeout
    interval: 3000
    onTriggered: if (managedIconProcess.running) managedIconProcess.running = false
  }

  Timer {
    id: servicesReadTimeout
    interval: 3000
    onTriggered: if (servicesReadProcess.running) servicesReadProcess.running = false
  }

  Timer {
    id: servicesWriteTimeout
    interval: 3000
    onTriggered: if (servicesWriteProcess.running) servicesWriteProcess.running = false
  }

  Process {
    id: iconImportProcess
    stdout: StdioCollector { id: iconImportOutput; waitForEnd: true }
    stderr: StdioCollector { id: iconImportError; waitForEnd: true }
    onExited: function(exitCode) {
      iconImportTimeout.stop()
      root.importingIcon = false
      if (root.iconImportTimedOut) {
        root.iconImportTimedOut = false
        root.pendingService = null
        return
      }
      if (exitCode !== 0 || !root.pendingService) {
        root.formError = String(iconImportError.text || "Could not import icon.").trim()
        root.pendingService = null
        return
      }
      var importedIcon = String(iconImportOutput.text || "").trim()
      if (!importedIcon) {
        root.formError = "Could not import icon."
        root.pendingService = null
        return
      }
      var pending = root.pendingService
      var next = root.services.slice()
      if (pending.sourceIndex >= 0 && pending.sourceIndex < next.length) {
        next[pending.sourceIndex] = Object.assign({}, next[pending.sourceIndex], {
          name: pending.name, url: pending.url, icon: importedIcon
        })
      } else {
        next.push({ name: pending.name, url: pending.url, icon: importedIcon, group: "HomeLab" })
      }
      root.pendingService = null
      root.addOpen = false
      root.editingSourceIndex = -1
      root.persistServices(next)
    }
  }

  Timer {
    id: iconImportTimeout
    interval: 10000
    onTriggered: {
      if (!root.importingIcon) return
      root.iconImportTimedOut = true
      root.formError = iconImportProcess.running
        ? "Icon import timed out."
        : "Could not start icon importer."
      if (iconImportProcess.running) {
        iconImportProcess.running = false
      } else {
        root.iconImportTimedOut = false
        root.importingIcon = false
        root.pendingService = null
      }
    }
  }

  Component.onCompleted: {
    servicesReadTimeout.restart()
    servicesReadProcess.running = true
  }

  FileView {
    path: root.dataReady ? root.servicesPath : ""
    watchChanges: true
    preload: false
    printErrors: false
    onFileChanged: root.requestServicesRead()
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
          height: Style.space(50)

          Column {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - editControl.width - root.gap
            spacing: Style.spacing.xs

            Text {
              width: parent.width
              text: root.searchMode ? ("HOMELAB  /  " + (root.filterText || "SEARCH…")) : "HOMELAB"
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
              elide: Text.ElideRight
            }

            Text {
              id: countLabel
              width: parent.width
              text: root.editMode ? "drag to reorder" : (root.services.length + " shortcuts")
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
            anchors.verticalCenterOffset: 4
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
                text: root.editMode ? "Exit edit mode" : "Edit shortcuts"
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
          topMargin: Style.space(8)
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
              anchors.rightMargin: root.editMode && !isAdd && !isSpacer ? Style.space(66) : Style.spacing.xxl
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
                text: isAdd ? "New shortcut" : name
                color: index === root.selectedIndex ? root.selectedText : root.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.Medium
                elide: Text.ElideRight
              }
            }

            Row {
              visible: root.editMode && !isAdd && !isSpacer
              z: 10
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.spacing.sm
              spacing: Style.spacing.xs

              PanelActionButton {
                iconText: "✎"
                tooltipText: "Edit shortcut"
                foreground: root.foreground
                hoverColor: Color.accent
                fontFamily: Style.font.menuFamily
                fontSize: Style.font.body
                size: Style.space(24)
                bordered: true
                onClicked: root.openEditDialog(sourceIndex)
              }

              PanelActionButton {
                iconText: "×"
                tooltipText: "Delete shortcut"
                foreground: root.foreground
                hoverColor: Color.urgent
                fontFamily: Style.font.menuFamily
                fontSize: Style.font.title
                size: Style.space(24)
                bordered: true
                onClicked: root.deleteService(sourceIndex)
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
              text: root.editingSourceIndex >= 0 ? "EDIT SHORTCUT" : "NEW SHORTCUT"
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
            }

            TextField {
              id: nameField
              width: parent.width
              placeholderText: "Name"
              onAccepted: urlField.forceActiveFocus()
            }

            TextField {
              id: urlField
              width: parent.width
              placeholderText: "Address — https://… or http://…"
              onAccepted: iconField.forceActiveFocus()
            }

            TextField {
              id: iconField
              width: parent.width
              placeholderText: "Icon — local path to SVG/PNG"
              onAccepted: root.saveService()
            }

            Text {
              width: parent.width
              text: root.formError || "The icon can be an absolute path or file name in assets/."
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
                text: "Cancel"
                enabled: !root.importingIcon
                bordered: true
                focusable: true
                onClicked: root.closeAddDialog()
              }

              Button {
                text: root.importingIcon ? "Importing…" : (root.editingSourceIndex >= 0 ? "Save" : "Add")
                enabled: !root.importingIcon
                selected: true
                bordered: true
                focusable: true
                onClicked: root.saveService()
              }
            }
          }
        }
      }
    }
  }
}

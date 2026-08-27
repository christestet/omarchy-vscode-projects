import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "christestet.vscode-projects"
  // Bar widgets are always loaded. Own a direct IPC target for action
  // commands; shell.call only routes to separately loaded panel plugins.
  ipcTarget: ""
  manageIpc: false

  property var pinnedProjects: []
  property var recentProjects: []
  property var rows: []
  property var actionProject: null
  property bool settingsOpen: false
  property bool shortcutsOpen: false
  property bool confirmUnpinAll: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property string output: ""
  readonly property int maxHelperOutputChars: 524288
  property string chooserOutput: ""
  readonly property int maxChooserOutputChars: 4096
  property string defaultEditor: "code"
  property string appVersion: ""
  property string copiedPath: ""
  property string pendingAction: ""
  property bool hasLoadedProjects: false
  property bool loaderTimedOut: false
  property string loadError: ""
  readonly property int maxProjects: boundedInt(setting("maxProjects", 10), 3, 30)
  readonly property int helperTimeoutMs: 1000
  readonly property bool newWindow: setting("openMode", "reuse") === "new"
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("bin/vsc-recent-projects")).replace(/^file:\/\//, ""))
  readonly property string repositoryUrl: "https://github.com/christestet/omarchy-vscode-projects"
  readonly property string repositoryName: repositoryUrl.substring(repositoryUrl.lastIndexOf("/") + 1)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function boundedInt(value, low, high) {
    var number = parseInt(String(value), 10)
    if (!isFinite(number)) number = low
    return Math.max(low, Math.min(high, number))
  }

  function parsePayload(raw) {
    try {
      var value = JSON.parse(String(raw || "{}"))
      return value && !Array.isArray(value) ? value : ({})
    } catch (_) { return ({}) }
  }

  function appendHelperOutput(data) {
    if (output.length >= maxHelperOutputChars) return
    var chunk = String(data || "")
    output += chunk.substring(0, maxHelperOutputChars - output.length)
  }

  function appendChooserOutput(data) {
    if (chooserOutput.length >= maxChooserOutputChars) return
    var chunk = String(data || "") + "\n"
    chooserOutput += chunk.substring(0, maxChooserOutputChars - chooserOutput.length)
  }

  function projectRow(project, pinned) {
    return { rowType: "project", name: String(project.name || project.path || "Project"), path: String(project.path || ""), editor: String(project.editor || "code"), kind: String(project.kind || "folder"), pinned: pinned === true }
  }

  function matches(project, query) {
    return (String(project.name || "") + " " + String(project.path || "")).toLowerCase().indexOf(query) >= 0
  }

  function rebuildRows() {
    var next = []
    var query = filterText.trim().toLowerCase()
    if (actionProject) {
      next = [
        {rowType: "command", command: "open", label: "Open", icon: "󰨞"},
        {rowType: "command", command: "open-new", label: "Open in new window", icon: "󰐕"},
        {rowType: "command", command: "terminal", label: "Open terminal here", icon: ""},
        {rowType: "command", command: "files", label: "Reveal in files", icon: ""},
        {rowType: "command", command: "copy", label: "Copy path", icon: "󰆏"},
        {rowType: "command", command: "pin", label: actionProject.pinned ? "Unpin project" : "Pin project", icon: actionProject.pinned ? "󰤱" : ""},
        {rowType: "command", command: "back", label: "Back to projects", icon: ""}
      ]
    } else if (shortcutsOpen) {
      next = [
        {rowType: "section", label: "OPTIONAL GLOBAL"},
        {rowType: "info", label: "Toggle projects panel", icon: "󰨞", shortcut: "Super Alt O"},
        {rowType: "info", label: "Open most recent project", icon: "󰐕", shortcut: "Super Ctrl Alt O"},
        {rowType: "section", label: "PANEL"},
        {rowType: "info", label: "Search projects", icon: "", shortcut: "Type"},
        {rowType: "info", label: "Navigate", icon: "", shortcut: "↑ / ↓"},
        {rowType: "info", label: "Open selected project", icon: "󰌑", shortcut: "Enter"},
        {rowType: "info", label: "Open in new window", icon: "󰐕", shortcut: "Shift Enter"},
        {rowType: "info", label: "Show project actions", icon: "󰜴", shortcut: "→"},
        {rowType: "info", label: "Quick-open visible project", icon: "󰎠", shortcut: "1–9"},
        {rowType: "info", label: "Open folder picker", icon: "", shortcut: "Ctrl O"},
        {rowType: "info", label: "New VS Code window", icon: "󰐕", shortcut: "Ctrl N"},
        {rowType: "info", label: "Refresh projects", icon: "󰑐", shortcut: "Ctrl R"},
        {rowType: "info", label: "Back or close", icon: "󰅖", shortcut: "Esc"},
        {rowType: "section", label: "MOUSE"},
        {rowType: "info", label: "Toggle panel / open project", icon: "󰍽", shortcut: "Left click"},
        {rowType: "info", label: "Refresh from bar / actions", icon: "󰍽", shortcut: "Right click"},
        {rowType: "info", label: "Open in new window", icon: "󰍽", shortcut: "Middle click"},
        {rowType: "command", command: "back", label: "Back to projects", icon: ""}
      ]
    } else if (settingsOpen) {
      next = [
        {rowType: "section", label: "PROJECT DEFAULTS"},
        {rowType: "slider", command: "recent-limit", label: "Recent projects", value: maxProjects},
        {rowType: "command", command: "open-mode", label: "Default open mode", detail: newWindow ? "New window" : "Reuse current window", icon: "", shortcut: newWindow ? "NEW" : "REUSE"},
        {rowType: "section", label: "MAINTENANCE"},
        {rowType: "command", command: "refresh", label: "Refresh projects", icon: "󰑐", shortcut: "Ctrl R"},
        {rowType: "command", command: "unpin-all", label: confirmUnpinAll ? ("Press again to unpin " + pinnedProjects.length + " projects") : "Unpin all projects", detail: pinnedProjects.length === 0 ? "No pinned projects" : "This keeps the projects in VS Code history", icon: confirmUnpinAll ? "" : "󰤱", disabled: pinnedProjects.length === 0},
        {rowType: "command", command: "back", label: "Back to projects", icon: ""}
      ]
    } else if (query) {
      for (var p = 0; p < pinnedProjects.length; p++) if (matches(pinnedProjects[p], query)) next.push(projectRow(pinnedProjects[p], true))
      for (var r = 0; r < recentProjects.length; r++) if (matches(recentProjects[r], query)) next.push(projectRow(recentProjects[r], false))
      if (next.length === 0) next.push({rowType: "empty", label: "No matches for “" + filterText + "”"})
    } else {
      if (pinnedProjects.length > 0) {
        next.push({rowType: "section", label: "PINNED"})
        for (var i = 0; i < pinnedProjects.length; i++) next.push(projectRow(pinnedProjects[i], true))
      }
      if (recentProjects.length > 0) {
        next.push({rowType: "section", label: "RECENT"})
        for (var j = 0; j < recentProjects.length; j++) next.push(projectRow(recentProjects[j], false))
      } else if (pinnedProjects.length === 0) {
        next.push({
          rowType: "empty",
          label: loadError ? "Could not load projects" : "No recent local projects",
          detail: loadError || "Open a folder in VS Code to get started"
        })
      }
      next.push({rowType: "section", label: "ACTIONS"})
      next.push({rowType: "command", command: "folder", label: "Open folder…", icon: "", shortcut: "Ctrl O"})
      next.push({rowType: "command", command: "new", label: "New VS Code window", icon: "󰐕", shortcut: "Ctrl N"})
    }
    rows = next
    selectedIndex = firstSelectable()
    cursorActive = false
  }

  function selectable(row) { return row && row.rowType !== "section" && row.rowType !== "empty" && row.rowType !== "slider" && row.rowType !== "info" && !row.disabled }
  function firstSelectable() {
    for (var i = 0; i < rows.length; i++) if (selectable(rows[i])) return i
    return 0
  }

  function move(delta) {
    if (rows.length === 0) return
    cursorActive = true
    var index = selectedIndex
    for (var tries = 0; tries < rows.length; tries++) {
      index = Math.max(0, Math.min(rows.length - 1, index + delta))
      if (selectable(rows[index])) break
      if ((index === 0 && delta < 0) || (index === rows.length - 1 && delta > 0)) break
    }
    if (selectable(rows[index])) selectedIndex = index
    list.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function refresh(notify) {
    if (loader.running) return
    if (notify === true) {
      Quickshell.execDetached(["omarchy", "notification", "send", "Refreshing VS Code projects", "Reading recent local projects", "-g", "󰑐"])
    }
    output = ""
    loaderTimedOut = false
    loader.command = [helperPath, "list", "--limit", String(maxProjects)]
    loader.running = true
  }

  function openRecent() {
    var project = recentProjects.length > 0 ? projectRow(recentProjects[0], false)
      : (pinnedProjects.length > 0 ? projectRow(pinnedProjects[0], true) : null)
    if (project) openProject(project, false)
    else if (!hasLoadedProjects) { pendingAction = "recent"; refresh() }
    else Quickshell.execDetached(["omarchy", "notification", "send", "No recent VS Code projects", "Open a local folder first", "-g", "󰨞"])
  }

  function openFolderChooser() {
    if (folderChooser.running) return
    chooserOutput = ""
    folderChooser.command = ["zenity", "--file-selection", "--directory", "--title=Open folder in VS Code"]
    folderChooser.running = true
  }

  function openNewWindow() {
    Quickshell.execDetached(["uwsm-app", "--", defaultEditor, "--new-window"])
    close()
  }

  function openProject(project, forceNew) {
    if (!project || !project.path) return
    var mode = forceNew || newWindow ? "--new-window" : "--reuse-window"
    Quickshell.execDetached(["uwsm-app", "--", project.editor || "code", mode, "--", project.path])
    close()
  }

  function showActions(project) { if (project && project.rowType === "project") { actionProject = project; settingsOpen = false; shortcutsOpen = false; filterText = ""; rebuildRows() } }
  function leaveActions() { actionProject = null; rebuildRows() }
  function showSettings() { actionProject = null; settingsOpen = true; shortcutsOpen = false; confirmUnpinAll = false; filterText = ""; rebuildRows() }
  function leaveSettings() { settingsOpen = false; confirmUnpinAll = false; rebuildRows() }
  function showShortcuts() { actionProject = null; settingsOpen = false; shortcutsOpen = true; confirmUnpinAll = false; filterText = ""; rebuildRows() }
  function leaveShortcuts() { shortcutsOpen = false; rebuildRows() }
  function saveSetting(key, value, jsonValue) {
    if (settingsRunner.running) return
    settingsRunner.command = ["omarchy", "bar", "set", moduleName, key, String(value)]
    if (jsonValue) settingsRunner.command.push("--json")
    settingsRunner.running = true
  }
  function togglePin(project) {
    actionRunner.command = [helperPath, project.pinned ? "unpin" : "pin", "--path", project.path, "--editor", project.editor, "--kind", project.kind]
    actionRunner.running = true
  }

  function copyPath(path) {
    if (!path || clipboardWriter.running) return
    copiedPath = String(path)
    clipboardWriter.command = ["wl-copy", "--", copiedPath]
    clipboardWriter.running = true
    close()
  }

  function projectDirectory(project) {
    var path = String(project.path || "")
    if (project.kind !== "workspace") return path
    var slash = path.lastIndexOf("/")
    return slash > 0 ? path.substring(0, slash) : path
  }

  function runCommand(row) {
    if (!row) return
    var project = actionProject
    if (row.command === "open") openProject(project, false)
    else if (row.command === "open-new") openProject(project, true)
    else if (row.command === "terminal") { Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "--dir=" + projectDirectory(project)]); close() }
    else if (row.command === "files") { Quickshell.execDetached(["uwsm-app", "--", "nautilus", projectDirectory(project)]); close() }
    else if (row.command === "copy") copyPath(project.path)
    else if (row.command === "pin") togglePin(project)
    else if (row.command === "back") { if (shortcutsOpen) leaveShortcuts(); else if (settingsOpen) leaveSettings(); else leaveActions() }
    else if (row.command === "folder") openFolderChooser()
    else if (row.command === "new") openNewWindow()
    else if (row.command === "refresh") refresh(true)
    else if (row.command === "open-mode") saveSetting("openMode", newWindow ? "reuse" : "new", false)
    else if (row.command === "unpin-all") {
      if (!confirmUnpinAll) { confirmUnpinAll = true; rebuildRows() }
      else {
        confirmUnpinAll = false
        actionRunner.command = [helperPath, "unpin-all"]
        actionRunner.running = true
      }
    }
  }

  function activate(index, forceNew) {
    var row = rows[index]
    if (!selectable(row)) return
    if (row.rowType === "project") openProject(row, forceNew)
    else runCommand(row)
  }

  function setFilter(value) { filterText = value; actionProject = null; settingsOpen = false; shortcutsOpen = false; rebuildRows() }

  onOpenedChanged: if (opened) {
    filterText = ""; actionProject = null; settingsOpen = false; shortcutsOpen = false; confirmUnpinAll = false; refresh()
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  IpcHandler {
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(true); return "ok" }
    function openRecent(): string { root.openRecent(); return "ok" }
    function openFolder(): string { root.openFolderChooser(); return "ok" }
    function newWindow(): string { root.openNewWindow(); return "ok" }
  }

  Process {
    id: loader
    stdout: SplitParser { onRead: data => root.appendHelperOutput(data) }
    onExited: function(code) {
      var succeeded = code === 0 && !root.loaderTimedOut
      var payload = succeeded ? root.parsePayload(root.output) : ({})
      var validPayload = succeeded && Array.isArray(payload.pinned) && Array.isArray(payload.recent)
      root.loadError = validPayload ? "" : (root.loaderTimedOut
        ? "Project helper timed out"
        : "Project helper missing or invalid; reinstall the release bundle or run scripts/build-helper from a source checkout")
      root.pinnedProjects = Array.isArray(payload.pinned) ? payload.pinned : []
      root.recentProjects = Array.isArray(payload.recent) ? payload.recent : []
      root.defaultEditor = String(payload.defaultEditor || "code")
      root.appVersion = String(payload.version || "")
      root.hasLoadedProjects = true
      root.rebuildRows()
      if (root.pendingAction === "recent") {
        root.pendingAction = ""
        root.openRecent()
      }
    }
  }
  // This helper reads externally replaceable editor state. Keep a hard wall
  // clock deadline outside the helper so no malformed SQLite state can leave the
  // long-running shell process waiting indefinitely.
  Timer {
    id: loaderDeadline
    interval: root.helperTimeoutMs
    repeat: false
    running: loader.running
    onTriggered: {
      root.loaderTimedOut = true
      loader.signal(9) // SIGKILL: a hard deadline even if the helper is stuck in I/O.
    }
  }
  Process { id: actionRunner; onExited: function(_) { root.actionProject = null; root.refresh() } }
  Process { id: settingsRunner; onExited: function(_) { root.rebuildRows() } }
  Process {
    id: clipboardWriter
    onExited: function(code) {
      if (code === 0) {
        Quickshell.execDetached(["omarchy", "notification", "send", "Path copied", root.copiedPath, "-g", "󰆏"])
      } else {
        Quickshell.execDetached(["omarchy", "notification", "send", "Could not copy path", root.copiedPath, "-g", "", "-u", "critical"])
      }
    }
  }
  // Keep GTK's folder chooser outside the long-running Quickshell process.
  Process {
    id: folderChooser
    stdout: SplitParser { onRead: data => root.appendChooserOutput(data) }
    onExited: function(code) {
      var folder = root.chooserOutput.trim()
      if (code === 0 && folder) {
        Quickshell.execDetached(["uwsm-app", "--", root.defaultEditor, "--reuse-window", "--", folder])
        root.close()
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰨞"
    tooltipText: "VS Code Projects  ·  Left click to open"
    onPressed: function(code) {
      if (code === Qt.RightButton) root.refresh(true)
      else if (code === Qt.MiddleButton) root.openNewWindow()
      else root.toggle()
    }
  }

  KeyboardPanel {
    anchorItem: button; owner: root; bar: root.bar; open: root.opened; focusTarget: keys
    contentWidth: fittedContentWidth(Style.space(380))
    contentHeight: fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_R) {
          root.refresh(true); event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_O) {
          root.openFolderChooser(); event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_N) {
          root.openNewWindow(); event.accepted = true
        } else if (root.settingsOpen && (event.key === Qt.Key_Minus || event.key === Qt.Key_Underscore)) {
          root.saveSetting("maxProjects", Math.max(3, root.maxProjects - 1), true); event.accepted = true
        } else if (root.settingsOpen && (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal)) {
          root.saveSetting("maxProjects", Math.min(30, root.maxProjects + 1), true); event.accepted = true
        } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9 && event.modifiers === Qt.NoModifier && !root.filterText && !root.actionProject) {
          var wanted = event.key - Qt.Key_1
          var found = 0
          for (var i = 0; i < root.rows.length; i++) {
            if (root.rows[i].rowType !== "project") continue
            if (found === wanted) { root.openProject(root.rows[i], false); break }
            found++
          }
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          if (root.actionProject) root.leaveActions(); else if (root.shortcutsOpen) root.leaveShortcuts(); else if (root.settingsOpen) root.leaveSettings(); else if (root.filterText) root.setFilter(""); else root.close()
          event.accepted = true
        } else if (!root.settingsOpen && !root.shortcutsOpen && Util.editsFilter(event, root.filterText)) {
          root.setFilter(Util.editedFilter(event, root.filterText)); event.accepted = true
        } else if (event.key === Qt.Key_Up) { root.move(-1); event.accepted = true
        } else if (event.key === Qt.Key_Down) { root.move(1); event.accepted = true
        } else if (event.key === Qt.Key_Right && root.rows[root.selectedIndex] && root.rows[root.selectedIndex].rowType === "project") {
          root.showActions(root.rows[root.selectedIndex]); event.accepted = true
        } else if (event.key === Qt.Key_Left && (root.actionProject || root.settingsOpen || root.shortcutsOpen)) {
          if (root.shortcutsOpen) root.leaveShortcuts(); else if (root.settingsOpen) root.leaveSettings(); else root.leaveActions(); event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activate(root.selectedIndex, (event.modifiers & Qt.ShiftModifier) !== 0); event.accepted = true
        } else if (!root.actionProject && !root.settingsOpen && !root.shortcutsOpen && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
          root.setFilter(root.filterText + event.text); event.accepted = true
        }
      }

      Column {
        id: panelColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)
        PanelHero {
          id: hero
          width: parent.width
          title: root.actionProject ? root.actionProject.name : "VS Code Projects"
          meta: root.actionProject ? "PROJECT ACTIONS" : (root.shortcutsOpen ? "SHORTCUTS" : (root.settingsOpen ? "SETTINGS" : (root.filterText ? "SEARCH: " + root.filterText : (root.pinnedProjects.length + " pinned · " + root.recentProjects.length + " recent"))))
          function toggleSettings() { if (root.settingsOpen) root.leaveSettings(); else root.showSettings() }
          function toggleShortcuts() { if (root.shortcutsOpen) root.leaveShortcuts(); else root.showShortcuts() }
          iconComponent: Component {
            Item {
              implicitWidth: Style.space(34); implicitHeight: Style.space(34)
              OpticalGlyph { anchors.fill: parent; text: "󰨞"; fontSize: Style.font.display; color: root.bar ? root.bar.foreground : Color.foreground; fontFamily: root.bar ? root.bar.fontFamily : Style.font.family }
            }
          }
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          trailingControl: Component {
            Row {
              visible: hero.meta !== "PROJECT ACTIONS"
              spacing: Style.space(3)
              PanelActionButton {
                iconText: ""
                tooltipText: hero.meta === "SHORTCUTS" ? "Back to projects" : "Show shortcuts"
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                fontSize: Style.font.icon
                size: Style.space(28)
                hasCursor: hero.meta === "SHORTCUTS"
                onClicked: hero.toggleShortcuts()
              }
              PanelActionButton {
                iconText: ""
                tooltipText: hero.meta === "SETTINGS" ? "Back to projects" : "Settings"
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                fontSize: Style.font.icon
                size: Style.space(28)
                hasCursor: hero.meta === "SETTINGS"
                onClicked: hero.toggleSettings()
              }
            }
          }
        }
        Rectangle {
          visible: !root.actionProject && !root.settingsOpen && !root.shortcutsOpen && !root.filterText
          width: parent.width
          height: Style.space(42)
          radius: Style.cornerRadius
          color: Qt.rgba((root.bar ? root.bar.foreground : Color.foreground).r,
                         (root.bar ? root.bar.foreground : Color.foreground).g,
                         (root.bar ? root.bar.foreground : Color.foreground).b, 0.055)
          Column {
            anchors.centerIn: parent
            spacing: Style.space(3)
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "TYPE TO SEARCH   ·   ↑↓ NAVIGATE   ·   ENTER OPEN"
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.25)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "1–9 QUICK OPEN   ·   → ACTIONS   ·   ESC CLOSE"
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.45)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
        ListView {
          id: list
          width: parent.width
          height: Math.min(contentHeight, Style.space(320))
          clip: true
          model: root.rows
          currentIndex: root.cursorActive ? root.selectedIndex : -1
          spacing: Style.space(3)
          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          delegate: Rectangle {
            required property int index
            required property var modelData
            readonly property var row: modelData
            readonly property bool selected: root.cursorActive && index === root.selectedIndex
            width: ListView.view.width
            height: row.rowType === "section" ? Style.space(38) : (row.rowType === "slider" ? Style.space(58) : (row.detail || row.rowType === "project" ? Style.space(44) : Style.space(38)))
            opacity: row.disabled ? 0.45 : 1
            radius: Style.cornerRadius
            color: (selected || mouse.containsMouse) && root.selectable(row) ? Color.menu.selectedBackground : "transparent"
            PanelSeparator {
              visible: row.rowType === "section"
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              foreground: root.bar ? root.bar.foreground : Color.foreground
            }
            PanelSectionHeader {
              visible: row.rowType === "section"
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              text: row.label || ""
              foreground: root.bar ? root.bar.foreground : Color.foreground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }
            Row {
              visible: row.rowType !== "section" && row.rowType !== "slider"
              anchors.fill: parent; anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)
              Text {
                width: Style.space(20); anchors.verticalCenter: parent.verticalCenter
                text: row.rowType === "project" ? (row.pinned ? "" : (row.kind === "workspace" ? "󰙅" : "")) : (row.icon || "")
                color: (parent.parent.selected || mouse.containsMouse) && root.selectable(row) ? Color.menu.selectedText : (root.bar ? root.bar.foreground : Color.foreground)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
              }
              Column {
                width: parent.width - Style.space(28) - (shortcutLabel.visible ? shortcutLabel.implicitWidth + Style.space(8) : 0); anchors.verticalCenter: parent.verticalCenter
                Text {
                  width: parent.width; elide: Text.ElideRight
                  text: row.rowType === "project" ? row.name : row.label
                  color: (parent.parent.parent.selected || mouse.containsMouse) && root.selectable(row) ? Color.menu.selectedText : (root.bar ? root.bar.foreground : Color.foreground)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  visible: row.rowType === "project" || Boolean(row.detail)
                  width: parent.width; elide: Text.ElideMiddle
                  text: row.rowType === "project" ? row.path : (row.detail || "")
                  color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.45)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
              Text {
                id: shortcutLabel
                visible: Boolean(row.shortcut)
                anchors.verticalCenter: parent.verticalCenter
                text: row.shortcut || ""
                color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
            Column {
              visible: row.rowType === "slider"
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(4)
              Row {
                width: parent.width
                Text {
                  text: row.label || ""
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
                Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - sliderValue.implicitWidth); height: 1 }
                Text {
                  id: sliderValue
                  text: String(Math.round(recentSlider.liveValue))
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
              }
              PanelSlider {
                id: recentSlider
                width: parent.width
                bar: root.bar
                minimum: 3
                maximum: 30
                step: 1
                integer: true
                value: Number(row.value || root.maxProjects)
                onReleased: function(value) { root.saveSetting("maxProjects", Math.round(value), true) }
              }
            }
            MouseArea {
              id: mouse
              anchors.fill: parent; hoverEnabled: true
              visible: row.rowType !== "slider"
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
              onClicked: function(event) {
                if (!root.selectable(row)) return
                root.selectedIndex = index; root.cursorActive = true
                if (row.rowType === "project" && event.button === Qt.RightButton) root.showActions(row)
                else root.activate(index, row.rowType === "project" && event.button === Qt.MiddleButton)
              }
            }
          }
        }
        Column {
          visible: !root.actionProject && !root.settingsOpen && !root.shortcutsOpen && !root.filterText
          width: parent.width
          spacing: Style.space(8)
          PanelSeparator {
            width: parent.width
            foreground: root.bar ? root.bar.foreground : Color.foreground
          }
          Item {
            id: repositoryFooter
            width: parent.width
            height: Style.space(22)
            Text {
              id: githubIcon
              anchors.left: parent.left
              anchors.leftMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              text: ""
              color: footerMouse.containsMouse ? (root.bar ? root.bar.foreground : Color.foreground) : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.35)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.iconSmall
            }
            Text {
              id: repositoryText
              anchors.left: githubIcon.right
              anchors.leftMargin: Style.space(7)
              anchors.right: versionText.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.repositoryName
              elide: Text.ElideMiddle
              color: footerMouse.containsMouse ? (root.bar ? root.bar.foreground : Color.foreground) : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.45)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              id: versionText
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              text: root.appVersion ? ("v" + root.appVersion) : ""
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.45)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            MouseArea {
              id: footerMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: Quickshell.execDetached(["uwsm-app", "--", "xdg-open", root.repositoryUrl])
            }
          }
        }
      }
    }
  }
}

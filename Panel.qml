import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "christestet.vscode-projects"
  ipcTarget: moduleName
  manageIpc: false

  property var pinnedProjects: []
  property var recentProjects: []
  property var rows: []
  property var actionProject: null
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property string output: ""
  property string chooserOutput: ""
  readonly property int maxProjects: boundedInt(setting("maxProjects", 10), 3, 30)
  readonly property bool newWindow: setting("openMode", "reuse") === "new"
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("recent_projects.py")).replace(/^file:\/\//, ""))

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
        next.push({rowType: "empty", label: "No recent local projects", detail: "Open a folder in VS Code to get started"})
      }
      next.push({rowType: "section", label: "ACTIONS"})
      next.push({rowType: "command", command: "folder", label: "Open folder…", icon: ""})
      next.push({rowType: "command", command: "new", label: "New VS Code window", icon: "󰐕"})
    }
    rows = next
    selectedIndex = firstSelectable()
    cursorActive = false
  }

  function selectable(row) { return row && row.rowType !== "section" && row.rowType !== "empty" }
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

  function refresh() {
    if (loader.running) return
    output = ""
    loader.command = ["/usr/bin/python3", helperPath, "list", "--limit", String(maxProjects)]
    loader.running = true
  }

  function openProject(project, forceNew) {
    if (!project || !project.path) return
    var mode = forceNew || newWindow ? "--new-window" : "--reuse-window"
    Quickshell.execDetached(["uwsm-app", "--", project.editor || "code", mode, "--", project.path])
    close()
  }

  function showActions(project) { if (project && project.rowType === "project") { actionProject = project; filterText = ""; rebuildRows() } }
  function leaveActions() { actionProject = null; rebuildRows() }
  function togglePin(project) {
    actionRunner.command = ["/usr/bin/python3", helperPath, project.pinned ? "unpin" : "pin", "--path", project.path, "--editor", project.editor, "--kind", project.kind]
    actionRunner.running = true
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
    else if (row.command === "copy") Quickshell.execDetached(["wl-copy", "--", project.path])
    else if (row.command === "pin") togglePin(project)
    else if (row.command === "back") leaveActions()
    else if (row.command === "folder") {
      chooserOutput = ""
      folderChooser.command = ["zenity", "--file-selection", "--directory", "--title=Open folder in VS Code"]
      folderChooser.running = true
    } else if (row.command === "new") { Quickshell.execDetached(["uwsm-app", "--", "code", "--new-window"]); close() }
  }

  function activate(index, forceNew) {
    var row = rows[index]
    if (!selectable(row)) return
    if (row.rowType === "project") openProject(row, forceNew)
    else runCommand(row)
  }

  function setFilter(value) { filterText = value; actionProject = null; rebuildRows() }

  onOpenedChanged: if (opened) {
    filterText = ""; actionProject = null; refresh()
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  Process {
    id: loader
    stdout: SplitParser { onRead: data => root.output += data }
    onExited: function(code) {
      var payload = code === 0 ? root.parsePayload(root.output) : ({})
      root.pinnedProjects = Array.isArray(payload.pinned) ? payload.pinned : []
      root.recentProjects = Array.isArray(payload.recent) ? payload.recent : []
      root.rebuildRows()
    }
  }
  Process { id: actionRunner; onExited: function(_) { root.actionProject = null; root.refresh() } }
  Process {
    id: folderChooser
    stdout: SplitParser { onRead: data => root.chooserOutput += data + "\n" }
    onExited: function(code) {
      var folder = root.chooserOutput.trim()
      if (code === 0 && folder) { Quickshell.execDetached(["uwsm-app", "--", "code", "--reuse-window", "--", folder]); root.close() }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰨞"
    tooltipText: "Left: projects · Right: refresh · Middle: new window"
    onPressed: function(code) {
      if (code === Qt.RightButton) root.refresh()
      else if (code === Qt.MiddleButton) Quickshell.execDetached(["uwsm-app", "--", "code", "--new-window"])
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
        if (event.key === Qt.Key_Escape) {
          if (root.actionProject) root.leaveActions(); else if (root.filterText) root.setFilter(""); else root.close()
          event.accepted = true
        } else if (Util.editsFilter(event, root.filterText)) {
          root.setFilter(Util.editedFilter(event, root.filterText)); event.accepted = true
        } else if (event.key === Qt.Key_Up) { root.move(-1); event.accepted = true
        } else if (event.key === Qt.Key_Down) { root.move(1); event.accepted = true
        } else if (event.key === Qt.Key_Right && root.rows[root.selectedIndex] && root.rows[root.selectedIndex].rowType === "project") {
          root.showActions(root.rows[root.selectedIndex]); event.accepted = true
        } else if (event.key === Qt.Key_Left && root.actionProject) { root.leaveActions(); event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activate(root.selectedIndex, (event.modifiers & Qt.ShiftModifier) !== 0); event.accepted = true
        } else if (!root.actionProject && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
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
          width: parent.width
          title: root.actionProject ? root.actionProject.name : "VS Code Projects"
          meta: root.actionProject ? "PROJECT ACTIONS" : (root.filterText ? "SEARCH: " + root.filterText : (root.pinnedProjects.length + " pinned · " + root.recentProjects.length + " recent"))
          iconComponent: Component {
            Item {
              implicitWidth: Style.space(34); implicitHeight: Style.space(34)
              OpticalGlyph { anchors.fill: parent; text: "󰨞"; fontSize: Style.font.display; color: root.bar ? root.bar.foreground : Color.foreground; fontFamily: root.bar ? root.bar.fontFamily : Style.font.family }
            }
          }
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
        Text {
          visible: !root.actionProject
          width: parent.width
          text: root.filterText ? ("SEARCH  " + root.filterText) : "LEFT OPEN  ·  RIGHT ACTIONS  ·  MIDDLE NEW WINDOW"
          color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 0.6
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
            height: row.rowType === "section" ? Style.space(38) : (row.detail || row.rowType === "project" ? Style.space(44) : Style.space(38))
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
              visible: row.rowType !== "section"
              anchors.fill: parent; anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)
              Text {
                width: Style.space(20); anchors.verticalCenter: parent.verticalCenter
                text: row.rowType === "project" ? (row.pinned ? "" : (row.kind === "workspace" ? "󰙅" : "")) : (row.icon || "")
                color: (parent.parent.selected || mouse.containsMouse) && root.selectable(row) ? Color.menu.selectedText : (root.bar ? root.bar.foreground : Color.foreground)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
              }
              Column {
                width: parent.width - Style.space(28); anchors.verticalCenter: parent.verticalCenter
                Text {
                  width: parent.width; elide: Text.ElideRight
                  text: row.rowType === "project" ? row.name : row.label
                  color: (parent.parent.parent.selected || mouse.containsMouse) && root.selectable(row) ? Color.menu.selectedText : (root.bar ? root.bar.foreground : Color.foreground)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
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
            }
            MouseArea {
              id: mouse
              anchors.fill: parent; hoverEnabled: true
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
      }
    }
  }
}

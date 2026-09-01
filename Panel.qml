import QtQuick
import QtQuick.Controls
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

  // --- theme ---------------------------------------------------------------
  // Resolve every theme token once at the root. Delegates read these instead
  // of repeating `bar ? bar.foreground : Color.foreground`, so a theme change
  // re-evaluates one binding rather than one per visible row.
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color faint: Qt.darker(foreground, 1.7)
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // --- state ---------------------------------------------------------------
  property var pinnedProjects: []
  property var recentProjects: []
  property var rows: []
  property var actionProject: null
  // One view token instead of three booleans that could disagree with each
  // other: "projects" | "actions" | "settings" | "shortcuts".
  property string view: "projects"
  property string filterText: ""
  property int selectedIndex: 0
  // The cursor lives in one of two places: the row list, or the action bar
  // above the search field. Bluetooth's panel models its hero toggle the same
  // way, as a section the keyboard can reach without a row to land on.
  property string focusSection: "list"
  property int actionIndex: 0
  property bool cursorActive: false
  property bool caretOn: true
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
  readonly property int panelMaxHeight: Style.space(560)
  // Quick-open is a single keystroke, so it stops at the last single digit.
  // Row badges and the key handler both derive from this: a tenth project can
  // never be labelled "10" and then refuse to open.
  readonly property int maxQuickKeys: 9
  readonly property bool newWindow: setting("openMode", "reuse") === "new"
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("bin/vsc-recent-projects")).replace(/^file:\/\//, ""))
  readonly property string repositoryUrl: "https://github.com/christestet/omarchy-vscode-projects"
  readonly property string repositoryName: repositoryUrl.substring(repositoryUrl.lastIndexOf("/") + 1)
  readonly property string homeDir: String(Quickshell.env("HOME") || "")
  readonly property int projectCount: pinnedProjects.length + recentProjects.length
  readonly property bool listingProjects: view === "projects"
  // Promoted out of the row list: these two are the panel's only entry points
  // when the history is empty, and burying them under a scroll made them the
  // hardest things to reach.
  readonly property var quickActions: [
    {command: "folder", label: "Open folder…", icon: "", shortcut: "Ctrl O"},
    {command: "new", label: "New window", icon: "󰐕", shortcut: "Ctrl N"}
  ]
  readonly property bool actionsVisible: listingProjects
  readonly property bool actionsFocused: cursorActive && focusSection === "actions" && actionsVisible
  readonly property int matchCount: {
    var n = 0
    for (var i = 0; i < rows.length; i++) if (rows[i].rowType === "project") n++
    return n
  }
  readonly property bool loadingFirstResults: !hasLoadedProjects && loader.running

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

  // Home-relative paths read faster in a 380px panel and drop the least
  // informative 12 characters of every row. Computed once per row build
  // rather than per delegate paint.
  function displayPath(path) {
    var value = String(path || "")
    if (!homeDir) return value
    if (value === homeDir) return "~"
    if (value.indexOf(homeDir + "/") === 0) return "~" + value.substring(homeDir.length)
    return value
  }

  function projectRow(project, pinned) {
    var path = String(project.path || "")
    return {
      rowType: "project",
      name: String(project.name || path || "Project"),
      path: path,
      displayPath: displayPath(path),
      editor: String(project.editor || "code"),
      kind: String(project.kind || "folder"),
      pinned: pinned === true,
      quickKey: ""
    }
  }

  function matches(project, query) {
    return (String(project.name || "") + " " + String(project.path || "")).toLowerCase().indexOf(query) >= 0
  }

  // Digits stay bound to the unfiltered list only: while a filter is active
  // the same keys are search input, so a visible badge would promise a
  // shortcut that cannot fire.
  function assignQuickKeys(list) {
    var assigned = 0
    for (var i = 0; i < list.length && assigned < maxQuickKeys; i++) {
      if (list[i].rowType !== "project") continue
      list[i].quickKey = String(assigned + 1)
      assigned++
    }
  }

  function actionRows() {
    return [
      {rowType: "command", command: "open", label: "Open", icon: "󰨞", shortcut: "Enter"},
      {rowType: "command", command: "open-new", label: "Open in new window", icon: "󰐕", shortcut: "Shift Enter"},
      {rowType: "command", command: "terminal", label: "Open terminal here", icon: ""},
      {rowType: "command", command: "files", label: "Reveal in files", icon: ""},
      {rowType: "command", command: "copy", label: "Copy path", icon: "󰆏"},
      {rowType: "command", command: "pin", label: actionProject && actionProject.pinned ? "Unpin project" : "Pin project", icon: actionProject && actionProject.pinned ? "󰤱" : ""},
      {rowType: "command", command: "back", label: "Back to projects", icon: "", shortcut: "Esc"}
    ]
  }

  function shortcutRows() {
    return [
      {rowType: "section", label: "OPTIONAL GLOBAL"},
      {rowType: "info", label: "Toggle projects panel", icon: "󰨞", shortcut: "Super Alt O"},
      {rowType: "info", label: "Open most recent project", icon: "󰐕", shortcut: "Super Ctrl Alt O"},
      {rowType: "section", label: "PANEL"},
      {rowType: "info", label: "Search projects", icon: "", shortcut: "Type"},
      {rowType: "info", label: "Navigate", icon: "", shortcut: "↑ / ↓"},
      {rowType: "info", label: "Jump to first / last", icon: "", shortcut: "Home / End"},
      {rowType: "info", label: "Open selected project", icon: "󰌑", shortcut: "Enter"},
      {rowType: "info", label: "Open in new window", icon: "󰐕", shortcut: "Shift Enter"},
      {rowType: "info", label: "Show project actions", icon: "󰜴", shortcut: "→"},
      {rowType: "info", label: "Quick-open numbered project", icon: "󰎠", shortcut: "1–9"},
      {rowType: "info", label: "Open folder picker", icon: "", shortcut: "Ctrl O"},
      {rowType: "info", label: "New VS Code window", icon: "󰐕", shortcut: "Ctrl N"},
      {rowType: "info", label: "Refresh projects", icon: "󰑐", shortcut: "Ctrl R"},
      {rowType: "info", label: "Settings", icon: "", shortcut: "Ctrl ,"},
      {rowType: "info", label: "This list", icon: "", shortcut: "F1"},
      {rowType: "info", label: "Switch bar panel", icon: "󰓡", shortcut: "Tab"},
      {rowType: "info", label: "Back or close", icon: "󰅖", shortcut: "Esc"},
      {rowType: "section", label: "MOUSE"},
      {rowType: "info", label: "Toggle panel / open project", icon: "󰍽", shortcut: "Left click"},
      {rowType: "info", label: "Refresh from bar / actions", icon: "󰍽", shortcut: "Right click"},
      {rowType: "info", label: "Open in new window", icon: "󰍽", shortcut: "Middle click"},
      {rowType: "command", command: "back", label: "Back to projects", icon: "", shortcut: "Esc"}
    ]
  }

  function settingsRows() {
    return [
      {rowType: "section", label: "PROJECT DEFAULTS"},
      {rowType: "slider", command: "recent-limit", label: "Recent projects", detail: "How many entries the helper reads from VS Code history", value: maxProjects},
      {rowType: "toggle", command: "open-mode", label: "Open in new window", detail: newWindow ? "Every project opens its own window" : "Projects reuse the current window", checked: newWindow},
      {rowType: "section", label: "MAINTENANCE"},
      {rowType: "command", command: "refresh", label: "Refresh projects", icon: "󰑐", shortcut: "Ctrl R"},
      {rowType: "command", command: "unpin-all", label: "Unpin all projects", detail: pinnedProjects.length === 0 ? "No pinned projects" : "Keeps every project in VS Code history", icon: "󰤱", danger: true, disabled: pinnedProjects.length === 0},
      {rowType: "command", command: "back", label: "Back to projects", icon: "", shortcut: "Esc"}
    ]
  }

  function projectRows() {
    var next = []
    var query = filterText.trim().toLowerCase()
    var i = 0

    if (query) {
      for (i = 0; i < pinnedProjects.length; i++)
        if (matches(pinnedProjects[i], query)) next.push(projectRow(pinnedProjects[i], true))
      for (i = 0; i < recentProjects.length; i++)
        if (matches(recentProjects[i], query)) next.push(projectRow(recentProjects[i], false))
      if (next.length === 0)
        next.push({rowType: "empty", icon: "", label: "No matches", detail: "Nothing here matches “" + filterText + "”"})
      return next
    }

    if (pinnedProjects.length > 0) {
      next.push({rowType: "section", label: "PINNED"})
      for (i = 0; i < pinnedProjects.length; i++) next.push(projectRow(pinnedProjects[i], true))
    }
    if (recentProjects.length > 0) {
      next.push({rowType: "section", label: "RECENT"})
      for (i = 0; i < recentProjects.length; i++) next.push(projectRow(recentProjects[i], false))
    } else if (pinnedProjects.length === 0) {
      next.push(loadingFirstResults
        ? {rowType: "empty", icon: "󰑐", label: "Reading VS Code history…", detail: ""}
        : {
          rowType: "empty",
          icon: loadError ? "" : "󰨞",
          label: loadError ? "Could not load projects" : "No recent local projects",
          detail: loadError || "Open a folder in VS Code to get started"
        })
    }

    assignQuickKeys(next)
    return next
  }

  function rebuildRows() {
    if (view === "actions") rows = actionRows()
    else if (view === "shortcuts") rows = shortcutRows()
    else if (view === "settings") rows = settingsRows()
    else rows = projectRows()

    selectedIndex = firstSelectable()
    focusSection = "list"
    actionIndex = 0
    cursorActive = false
    pointerGate.reset()
    list.positionViewAtBeginning()
  }

  function selectable(row) {
    return row
      && row.rowType !== "section"
      && row.rowType !== "empty"
      && row.rowType !== "info"
      && row.rowType !== "slider"
      && !row.disabled
  }

  function firstSelectable() {
    for (var i = 0; i < rows.length; i++) if (selectable(rows[i])) return i
    return 0
  }

  function lastSelectable() {
    for (var i = rows.length - 1; i >= 0; i--) if (selectable(rows[i])) return i
    return 0
  }

  function selectIndex(index) {
    if (index < 0 || index >= rows.length || !selectable(rows[index])) return
    cursorActive = true
    focusSection = "list"
    selectedIndex = index
    list.positionViewAtIndex(index, ListView.Contain)
  }

  function focusActions(index) {
    if (!actionsVisible) return
    cursorActive = true
    focusSection = "actions"
    actionIndex = Math.max(0, Math.min(quickActions.length - 1, index))
    pointerGate.reset()
  }

  function revealCursor() {
    list.positionViewAtIndex(selectedIndex, ListView.Contain)
    pointerGate.reset()
  }

  // Up and down walk one ring: action bar, then every selectable row, then
  // back to the action bar.
  function move(delta) {
    if (rows.length === 0 && !actionsVisible) return

    // The first arrow press reveals the cursor without stepping past what the
    // user was looking at: down enters the list at the top, up reaches the
    // action bar that sits above it.
    if (!cursorActive) {
      if (delta < 0 && actionsVisible) { focusActions(0); return }
      cursorActive = true
      focusSection = "list"
      selectedIndex = delta < 0 ? lastSelectable() : firstSelectable()
      revealCursor()
      return
    }

    if (focusSection === "actions") {
      focusSection = "list"
      selectedIndex = delta < 0 ? lastSelectable() : firstSelectable()
      revealCursor()
      return
    }

    var index = selectedIndex
    for (var tries = 0; tries < rows.length; tries++) {
      var next = index + delta
      if (next < 0 || next >= rows.length) {
        if (actionsVisible) { focusActions(0); return }
        next = (next + rows.length) % rows.length
      }
      index = next
      if (selectable(rows[index])) {
        selectedIndex = index
        break
      }
    }
    revealCursor()
  }

  // Delegates move under a stationary pointer whenever the filter narrows the
  // list. Route mouse selection through the gate so only real pointer travel
  // moves the cursor.
  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    selectIndex(index)
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

  function openQuickKey(key) {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].rowType === "project" && rows[i].quickKey === key) {
        openProject(rows[i], false)
        return true
      }
    }
    return false
  }

  function showView(next) {
    view = next
    if (next !== "actions") actionProject = null
    if (next !== "projects") filterText = ""
    rebuildRows()
  }

  function showActions(project) {
    if (!project || project.rowType !== "project") return
    actionProject = project
    view = "actions"
    filterText = ""
    rebuildRows()
  }

  function toggleView(next) { showView(view === next ? "projects" : next) }

  function goBack() {
    if (view !== "projects") showView("projects")
    else if (filterText) setFilter("")
    else close()
  }

  function saveSetting(key, value, jsonValue) {
    if (settingsRunner.running) return
    settingsRunner.command = ["omarchy", "bar", "set", moduleName, key, String(value)]
    if (jsonValue) settingsRunner.command.push("--json")
    settingsRunner.running = true
  }

  function togglePin(project) {
    if (!project || actionRunner.running) return
    actionRunner.command = [helperPath, project.pinned ? "unpin" : "pin", "--path", project.path, "--editor", project.editor, "--kind", project.kind]
    actionRunner.running = true
  }

  function unpinAll() {
    if (actionRunner.running) return
    actionRunner.command = [helperPath, "unpin-all"]
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

  readonly property var projectCommands: ["open", "open-new", "terminal", "files", "copy", "pin"]

  function runCommand(row) {
    if (!row) return
    var project = actionProject
    if (projectCommands.indexOf(row.command) >= 0 && !project) return
    if (row.command === "open") openProject(project, false)
    else if (row.command === "open-new") openProject(project, true)
    else if (row.command === "terminal") { Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "--dir=" + projectDirectory(project)]); close() }
    else if (row.command === "files") { Quickshell.execDetached(["uwsm-app", "--", "nautilus", projectDirectory(project)]); close() }
    else if (row.command === "copy") copyPath(project.path)
    else if (row.command === "pin") togglePin(project)
    else if (row.command === "back") goBack()
    else if (row.command === "folder") openFolderChooser()
    else if (row.command === "new") openNewWindow()
    else if (row.command === "refresh") refresh(true)
    else if (row.command === "open-mode") saveSetting("openMode", newWindow ? "reuse" : "new", false)
    else if (row.command === "unpin-all") unpinConfirm.opened = true
  }

  function runQuickAction(index) {
    if (index < 0 || index >= quickActions.length) return
    runCommand(quickActions[index])
  }

  function activate(index, forceNew) {
    if (actionsFocused) { runQuickAction(actionIndex); return }
    var row = rows[index]
    if (!selectable(row)) return
    if (row.rowType === "project") openProject(row, forceNew)
    else runCommand(row)
  }

  function setFilter(value) {
    filterText = value
    caretOn = true
    rebuildRows()
    // Enter opens the first match, so the first match has to look selected.
    // With no filter the list is back to browsing and nothing is pre-armed.
    focusSection = "list"
    cursorActive = filterText !== "" && selectable(rows[selectedIndex])
  }

  // Ordered so panel-wide shortcuts win over filter input, and filter input
  // wins over the single-key fallbacks a text field would otherwise swallow.
  function handleKey(event) {
    if (unpinConfirm.handleKey(event)) { event.accepted = true; return }

    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    if (ctrl && event.key === Qt.Key_R) { refresh(true); event.accepted = true; return }
    if (ctrl && event.key === Qt.Key_O) { openFolderChooser(); event.accepted = true; return }
    if (ctrl && event.key === Qt.Key_N) { openNewWindow(); event.accepted = true; return }
    if (ctrl && event.key === Qt.Key_Comma) { toggleView("settings"); event.accepted = true; return }
    if (event.key === Qt.Key_F1) { toggleView("shortcuts"); event.accepted = true; return }

    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Escape) { goBack(); event.accepted = true; return }

    if (view === "settings" && (event.key === Qt.Key_Minus || event.key === Qt.Key_Underscore)) {
      saveSetting("maxProjects", Math.max(3, maxProjects - 1), true); event.accepted = true; return
    }
    if (view === "settings" && (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal)) {
      saveSetting("maxProjects", Math.min(30, maxProjects + 1), true); event.accepted = true; return
    }

    if (listingProjects && !filterText && event.modifiers === Qt.NoModifier
        && event.key >= Qt.Key_1 && event.key <= Qt.Key_0 + maxQuickKeys) {
      openQuickKey(String(event.key - Qt.Key_0)); event.accepted = true; return
    }

    if (listingProjects && Util.editsFilter(event, filterText)) {
      setFilter(Util.editedFilter(event, filterText)); event.accepted = true; return
    }

    if (event.key === Qt.Key_Up) { move(-1); event.accepted = true; return }
    if (event.key === Qt.Key_Down) { move(1); event.accepted = true; return }
    if (event.key === Qt.Key_Home) {
      if (actionsVisible) focusActions(0); else selectIndex(firstSelectable())
      event.accepted = true; return
    }
    if (event.key === Qt.Key_End) { selectIndex(lastSelectable()); event.accepted = true; return }

    if (event.key === Qt.Key_Right) {
      if (actionsFocused) { focusActions(actionIndex + 1); event.accepted = true; return }
      if (rows[selectedIndex] && rows[selectedIndex].rowType === "project") {
        showActions(rows[selectedIndex]); event.accepted = true; return
      }
    }
    if (event.key === Qt.Key_Left) {
      if (actionsFocused) { focusActions(actionIndex - 1); event.accepted = true; return }
      if (view !== "projects") { goBack(); event.accepted = true; return }
    }

    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      activate(selectedIndex, (event.modifiers & Qt.ShiftModifier) !== 0); event.accepted = true; return
    }

    if (listingProjects && event.text && event.text.length === 1
        && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
        && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
      setFilter(filterText + event.text); event.accepted = true
    }
  }

  onOpenedChanged: if (opened) {
    filterText = ""
    actionProject = null
    view = "projects"
    unpinConfirm.opened = false
    caretOn = true
    rebuildRows()
    refresh()
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: keys
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
  Process {
    id: actionRunner
    onExited: function(_) {
      // Pinning rewrites the list this action view was opened from, so the
      // view has nothing left to act on: fall back to the projects list.
      root.actionProject = null
      if (root.view === "actions") root.view = "projects"
      root.rebuildRows()
      root.refresh()
    }
  }
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

  // The caret only animates while the panel is on screen; a closed panel
  // leaves no timer running in the shared shell process.
  Timer {
    interval: 530
    repeat: true
    running: root.opened && root.listingProjects
    onTriggered: root.caretOn = !root.caretOn
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰨞"
    tooltipText: root.hasLoadedProjects && root.projectCount > 0
      ? (root.recentProjects.length + " recent · " + root.pinnedProjects.length + " pinned")
      : "VS Code Projects"
    onPressed: function(code) {
      if (code === Qt.RightButton) root.refresh(true)
      else if (code === Qt.MiddleButton) root.openNewWindow()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, root.panelMaxHeight)

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { root.handleKey(event) }

      Column {
        id: panelColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHero {
          id: hero
          width: parent.width
          title: root.view === "actions" && root.actionProject ? root.actionProject.name : "VS Code Projects"
          meta: {
            if (root.view === "actions") return "Project actions"
            if (root.view === "shortcuts") return "Shortcuts"
            if (root.view === "settings") return "Settings"
            if (root.loadingFirstResults) return "Loading"
            if (root.loadError) return "Helper unavailable"
            return root.pinnedProjects.length + " pinned · " + root.recentProjects.length + " recent"
          }
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Item {
              implicitWidth: Style.font.display
              implicitHeight: Style.font.display
              OpticalGlyph {
                anchors.fill: parent
                text: "󰨞"
                fontSize: Style.font.display
                color: root.foreground
                fontFamily: root.fontFamily
              }
            }
          }

          trailingControl: Component {
            Row {
              visible: root.view !== "actions"
              spacing: Style.spacing.xs

              PanelActionButton {
                iconText: ""
                tooltipText: root.view === "shortcuts" ? "Back to projects" : "Shortcuts  ·  F1"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.icon
                size: Style.space(28)
                hasCursor: root.view === "shortcuts"
                onClicked: root.toggleView("shortcuts")
              }
              PanelActionButton {
                iconText: ""
                tooltipText: root.view === "settings" ? "Back to projects" : "Settings  ·  Ctrl ,"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.icon
                size: Style.space(28)
                hasCursor: root.view === "settings"
                onClicked: root.toggleView("settings")
              }
            }
          }
        }

        // Compact chips rather than list rows: these two are always relevant,
        // so they sit above the search field where they cannot scroll away,
        // and stay small enough not to compete with the project list.
        Row {
          id: quickActionBar
          visible: root.actionsVisible
          width: parent.width
          spacing: Style.spacing.md

          readonly property real cellWidth: root.quickActions.length > 0
            ? (width - spacing * (root.quickActions.length - 1)) / root.quickActions.length
            : 0

          Repeater {
            model: root.quickActions

            Button {
              required property var modelData
              required property int index

              width: quickActionBar.cellWidth
              text: modelData.label
              iconText: modelData.icon
              tooltipText: modelData.shortcut
              bordered: true
              hasCursor: root.actionsFocused && index === root.actionIndex
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              iconSize: Style.font.iconSmall
              // Deliberately tighter than a form button: this bar sits above
              // the search field and must not out-weigh the project list.
              verticalPadding: Style.spacing.sm
              onClicked: {
                root.focusActions(index)
                root.runQuickAction(index)
              }
              onHovered: function(isHovered) { if (isHovered) root.focusActions(index) }
            }
          }
        }

        // Search surface. Typing anywhere in the panel lands here, so it is
        // painted like a focused text field rather than a hint strip: the
        // panel has no real editor to focus without stealing the arrow keys
        // the list needs.
        BorderSurface {
          id: search
          visible: root.listingProjects
          width: parent.width
          height: Math.max(Style.spacing.controlHeight, searchLabel.implicitHeight + Style.spacing.inputPaddingY * 2)
          radius: Style.cornerRadius
          color: Style.controlFill(root.filterText !== "", searchMouse.containsMouse, root.foreground, Color.accent)
          borderSpec: Border.controlSpec(root.filterText !== "" ? "focus" : "normal", root.foreground, Color.accent)

          // Declared first so it sits under the clear button, which owns its
          // own clicks. Hover only: there is no editor here to focus.
          MouseArea {
            id: searchMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            cursorShape: Qt.IBeamCursor
          }

          Text {
            id: searchGlyph
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: ""
            color: root.filterText ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconSmall
          }

          Text {
            id: searchCount
            textFormat: Text.PlainText
            anchors.right: searchClear.visible ? searchClear.left : parent.right
            anchors.rightMargin: searchClear.visible ? Style.spacing.sm : Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            visible: root.filterText !== ""
            text: root.matchCount + (root.matchCount === 1 ? " match" : " matches")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelActionButton {
            id: searchClear
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            visible: root.filterText !== ""
            iconText: "󰅖"
            tooltipText: "Clear search"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.iconSmall
            size: Style.space(20)
            onClicked: root.setFilter("")
          }

          Row {
            id: searchLabel
            anchors.left: searchGlyph.right
            anchors.leftMargin: Style.spacing.lg
            anchors.right: searchCount.visible ? searchCount.left : parent.right
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              id: searchText
              textFormat: Text.PlainText
              width: Math.min(implicitWidth, parent.width - caret.width - parent.spacing)
              text: root.filterText || "Search projects…"
              color: root.filterText ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideLeft
            }

            Rectangle {
              id: caret
              width: Math.max(1, Style.space(1))
              height: Math.round(searchText.font.pixelSize * 1.1)
              anchors.verticalCenter: parent.verticalCenter
              color: root.foreground
              opacity: root.caretOn ? 0.85 : 0
              Behavior on opacity { NumberAnimation { duration: 90 } }
            }
          }
        }

        // Which project the action list belongs to. Kept out of the hero
        // because PanelHero upper-cases `meta`, and an upper-cased path is
        // unreadable.
        Text {
          id: actionPath
          textFormat: Text.PlainText
          visible: root.view === "actions" && root.actionProject !== null
          width: parent.width
          text: root.actionProject ? root.actionProject.displayPath : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }

        ListView {
          id: list
          width: parent.width
          // Everything above and below the list has a height that does not
          // depend on the list, so the remaining budget is computable
          // without a binding loop.
          readonly property real chromeHeight: hero.height
            + (quickActionBar.visible ? quickActionBar.height + panelColumn.spacing : 0)
            + (search.visible ? search.height + panelColumn.spacing : 0)
            + (actionPath.visible ? actionPath.height + panelColumn.spacing : 0)
            + footerRule.height + repositoryFooter.height + panelColumn.spacing * 3
          // fittedContentHeight() caps the *card*, so the column only ever gets
          // the cap minus the card's own padding and border. Budgeting against
          // the raw cap overflowed by exactly that inset and clipped the footer.
          readonly property real cardBudget: Math.min(root.panelMaxHeight,
            panel.availableCardHeight > 0 ? panel.availableCardHeight : root.panelMaxHeight)
          height: Math.min(contentHeight,
            Math.max(Style.space(120), cardBudget - panel.verticalContentInset - chromeHeight))
          clip: true
          model: root.rows
          spacing: Style.spacing.xxs
          reuseItems: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: CursorSurface {
            id: rowItem
            required property int index
            required property var modelData
            readonly property var row: modelData
            readonly property bool selectableRow: root.selectable(row)
            readonly property bool rowCursor: root.cursorActive && index === root.selectedIndex && selectableRow

            width: ListView.view.width
            implicitHeight: content.implicitHeight
            height: implicitHeight
            opacity: row.disabled ? 0.45 : 1

            hasCursor: rowCursor
            foreground: root.foreground
            fill: root.hoverFill
            currentFill: root.selectedFill

            // One subtree per row type instead of every subtree on every row:
            // the settings slider alone is a dozen items, and building it for
            // each of thirty project rows is what made the list stutter while
            // filtering.
            Loader {
              id: content
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              sourceComponent: {
                if (rowItem.row.rowType === "section") return sectionContent
                if (rowItem.row.rowType === "slider") return sliderContent
                if (rowItem.row.rowType === "toggle") return toggleContent
                if (rowItem.row.rowType === "empty") return emptyContent
                return entryContent
              }
            }

            Component {
              id: sectionContent
              Item {
                implicitHeight: sectionHeader.implicitHeight + Style.spacing.huge

                PanelSeparator {
                  visible: rowItem.index > 0
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  foreground: root.foreground
                }

                PanelSectionHeader {
                  id: sectionHeader
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.xxs
                  anchors.bottom: parent.bottom
                  text: rowItem.row.label || ""
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }
              }
            }

            Component {
              id: emptyContent
              Column {
                topPadding: Style.spacing.huge
                bottomPadding: Style.spacing.huge
                leftPadding: Style.spacing.xl
                rightPadding: Style.spacing.xl
                spacing: Style.spacing.lg

                Text {
                  textFormat: Text.PlainText
                  width: content.width - Style.spacing.xl * 2
                  horizontalAlignment: Text.AlignHCenter
                  text: rowItem.row.icon || ""
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.displayLarge
                }
                Text {
                  textFormat: Text.PlainText
                  width: content.width - Style.spacing.xl * 2
                  horizontalAlignment: Text.AlignHCenter
                  text: rowItem.row.label || ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  visible: text !== ""
                  width: content.width - Style.spacing.xl * 2
                  horizontalAlignment: Text.AlignHCenter
                  text: rowItem.row.detail || ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }

            Component {
              id: entryContent
              Item {
                implicitHeight: Math.max(entryIcon.implicitHeight, entryLabels.implicitHeight) + Style.spacing.rowPaddingX

                readonly property bool isProject: rowItem.row.rowType === "project"
                readonly property color tint: rowItem.row.danger && !rowItem.row.disabled ? root.urgent : root.foreground

                Text {
                  id: entryIcon
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.xl
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  horizontalAlignment: Text.AlignHCenter
                  text: parent.isProject
                    ? (rowItem.row.pinned ? "" : (rowItem.row.kind === "workspace" ? "󰙅" : ""))
                    : (rowItem.row.icon || "")
                  color: parent.tint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }

                // Quick-open digit and keyboard hints share the trailing slot:
                // a row never carries both.
                Text {
                  id: entryTrailing
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.xl
                  anchors.verticalCenter: parent.verticalCenter
                  visible: text !== ""
                  text: rowItem.row.quickKey || rowItem.row.shortcut || ""
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Column {
                  id: entryLabels
                  anchors.left: entryIcon.right
                  anchors.leftMargin: Style.spacing.xl
                  anchors.right: entryTrailing.visible ? entryTrailing.left : parent.right
                  anchors.rightMargin: entryTrailing.visible ? Style.spacing.lg : Style.spacing.xl
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    elide: Text.ElideRight
                    text: parent.parent.isProject ? rowItem.row.name : (rowItem.row.label || "")
                    color: parent.parent.tint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: text !== ""
                    width: parent.width
                    elide: Text.ElideMiddle
                    text: parent.parent.isProject ? rowItem.row.displayPath : (rowItem.row.detail || "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Component {
              id: toggleContent
              Item {
                implicitHeight: Math.max(toggleLabels.implicitHeight, openModeSwitch.implicitHeight) + Style.spacing.rowPaddingX

                ToggleSwitch {
                  id: openModeSwitch
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.xl
                  anchors.verticalCenter: parent.verticalCenter
                  checked: rowItem.row.checked === true
                  // The row owns the click and the keyboard cursor; the switch
                  // only paints state.
                  interactive: false
                  hasCursor: rowItem.rowCursor
                  foreground: root.foreground
                }

                Column {
                  id: toggleLabels
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.xl
                  anchors.right: openModeSwitch.left
                  anchors.rightMargin: Style.spacing.lg
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    elide: Text.ElideRight
                    text: rowItem.row.label || ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    elide: Text.ElideRight
                    text: rowItem.row.detail || ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Component {
              id: sliderContent
              Column {
                topPadding: Style.spacing.lg
                bottomPadding: Style.spacing.lg
                leftPadding: Style.spacing.xl
                rightPadding: Style.spacing.xl
                spacing: Style.spacing.sm

                Item {
                  width: parent.width - parent.leftPadding - parent.rightPadding
                  implicitHeight: Math.max(sliderLabel.implicitHeight, sliderValue.implicitHeight)

                  Text {
                    id: sliderLabel
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.right: sliderValue.left
                    anchors.rightMargin: Style.spacing.lg
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowItem.row.label || ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    id: sliderValue
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(Math.round(recentSlider.liveValue))
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }

                PanelSlider {
                  id: recentSlider
                  width: parent.width - parent.leftPadding - parent.rightPadding
                  bar: root.bar
                  minimum: 3
                  maximum: 30
                  step: 1
                  integer: true
                  value: Number(rowItem.row.value || root.maxProjects)
                  onReleased: function(value) { root.saveSetting("maxProjects", Math.round(value), true) }
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width - parent.leftPadding - parent.rightPadding
                  text: rowItem.row.detail || ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              // The slider owns its own drag surface; a row-wide handler above
              // it would eat every press.
              visible: rowItem.row.rowType !== "slider"
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
              cursorShape: rowItem.selectableRow ? Qt.PointingHandCursor : Qt.ArrowCursor
              onPositionChanged: function(mouse) {
                if (rowItem.selectableRow) root.selectFromPointer(rowItem.index, rowItem, mouse)
              }
              onClicked: function(event) {
                if (!rowItem.selectableRow) return
                root.selectIndex(rowItem.index)
                if (rowItem.row.rowType === "project" && event.button === Qt.RightButton) root.showActions(rowItem.row)
                else root.activate(rowItem.index, rowItem.row.rowType === "project" && event.button === Qt.MiddleButton)
              }
            }
          }
        }

        PanelSeparator {
          id: footerRule
          width: parent.width
          foreground: root.foreground
        }

        // Footer stays mounted in every view so the panel does not change
        // height just because the user opened settings.
        Item {
          id: repositoryFooter
          width: parent.width
          height: Style.space(22)

          Text {
            id: githubIcon
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            text: ""
            color: footerMouse.containsMouse ? root.foreground : root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconSmall
          }
          Text {
            id: repositoryText
            textFormat: Text.PlainText
            anchors.left: githubIcon.right
            anchors.leftMargin: Style.spacing.md
            anchors.right: versionText.left
            anchors.rightMargin: Style.spacing.xl
            anchors.verticalCenter: parent.verticalCenter
            text: root.repositoryName
            elide: Text.ElideMiddle
            color: footerMouse.containsMouse ? root.foreground : root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            id: versionText
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            text: root.appVersion ? ("v" + root.appVersion) : ""
            color: root.faint
            font.family: root.fontFamily
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

      ConfirmDialog {
        id: unpinConfirm
        anchors.fill: parent
        z: 10
        message: root.pinnedProjects.length === 1
          ? "Unpin the pinned project?"
          : ("Unpin all " + root.pinnedProjects.length + " pinned projects?")
        confirmText: "Unpin all"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: opened = false
        onConfirmed: {
          opened = false
          root.unpinAll()
        }
      }
    }
  }
}

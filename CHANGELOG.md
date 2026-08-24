# Changelog

## 0.3.3 — 2026-08-24

- Show an Omarchy confirmation notification for explicit project-history refreshes from the panel, bar, shortcut, or IPC action.

## 0.3.2 — 2026-08-24

- Read current VS Code's shared, ordered Open Recent database first, with legacy database and JSON fallbacks.
- Remove `workspaceStorage` cache discovery so stale cache entries cannot appear as recent projects.
- Make SQLite database and sidecar access descriptor-bound, closing the path replacement gap in the previous size/type checks.
- Force-kill the QML helper after one second if it stalls on replaceable editor state.

## 0.3.1 — 2026-08-24

- Bound regular-file and SQLite reads, query work, recursive history traversal, workspace discovery, result counts, and helper/QML output.
- Reject oversized, malformed, deeply nested, or symlinked editor state without disrupting the panel.
- Bound persisted pin fields and folder-chooser output.

## 0.3.0 — 2026-08-24

- Add native panel and open-recent IPC commands for Omarchy keybindings.
- Add keyboard navigation, quick-open keys, action shortcuts, and an in-panel shortcut reference.
- Add a header settings menu with a persistent recent-project slider and default open-mode control.
- Add refresh and guarded unpin-all maintenance actions.
- Add a concise bar tooltip and system-relative compact typography.
- Add a clickable repository and manifest-sourced version footer.
- Improve the panel layout, action hints, and empty-history behavior.

## 0.2.1

- Initial public release.

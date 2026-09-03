# Changelog

## [0.5.0](https://github.com/christestet/omarchy-vscode-projects/compare/v0.4.0...v0.5.0) (2026-09-03)


### Features

* **panel:** rework the projects panel ([1476e7a](https://github.com/christestet/omarchy-vscode-projects/commit/1476e7ad7d37064326f9859a705d361ac94331a5))
* **panel:** rework the projects panel ([9c2115c](https://github.com/christestet/omarchy-vscode-projects/commit/9c2115cd5520d49a07291c2a53f6a11dc7ecbdd5))

## [0.4.0](https://github.com/christestet/omarchy-vscode-projects/compare/v0.3.4...v0.4.0) (2026-08-27)


### Features

* release Rust helper rewrite as v0.4.0 ([33c2885](https://github.com/christestet/omarchy-vscode-projects/commit/33c288585235b186acab8b69b4d5f20252fffb27))

## [0.3.4](https://github.com/christestet/omarchy-vscode-projects/compare/v0.3.3...v0.3.4) (2026-08-27)


### Bug Fixes

* **ci: qmllint:** added git workspace on arch container image ([f412c89](https://github.com/christestet/omarchy-vscode-projects/commit/f412c89c4a8f32b195265ba2bab125760b05e0d4))

## 0.4.0 — 2026-08-27

- Replace the Python helper with an optimized Rust binary while preserving the JSON command contract.
- Keep editor-state reads bounded and descriptor-bound, including SQLite WAL/SHM sidecars.
- Add a release build helper with LTO, stripped symbols, and atomic binary replacement.
- Report a clear panel error when the Rust helper has not been built or fails.

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

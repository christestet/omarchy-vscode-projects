# VS Code Projects for Omarchy

A compact, keyboard-friendly Omarchy bar widget for opening recent and pinned VS Code projects.

Current version: [`0.4.0`](./manifest.json) <!-- x-release-please-version -->

License: [MIT](./LICENSE) · Requires Omarchy 4.0+

[![CI](https://github.com/christestet/omarchy-vscode-projects/actions/workflows/ci.yml/badge.svg)](https://github.com/christestet/omarchy-vscode-projects/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/christestet/omarchy-vscode-projects)](https://github.com/christestet/omarchy-vscode-projects/releases)

![VS Code Projects panel showing pinned, recent, actions, and header controls](./preview.png)

## Features

- Reads recent local folders and `.code-workspace` files from VS Code, Insiders, VSCodium, and Code OSS.
- Keeps pinned projects above the recent-project history.
- Filters projects immediately as you type.
- Opens projects in the current window or a new window.
- Opens a terminal in the project, reveals its folder, or copies its path.
- Includes a settings view for project limits, default open mode, refresh, and pin cleanup.
- Shows a clickable repository link and release version in the default panel footer.
- Uses Omarchy's native panel components, theme colors, spacing, typography, keyboard focus, and bar behavior.
- Stores pins locally and performs no background network requests or telemetry.

Remote workspaces are intentionally hidden because reopening them reliably depends on their remote provider. Missing local paths and individual recent files are filtered out.

## Requirements

- Omarchy 4.0 or newer
- Zenity (`zenity`) for the external folder picker
- Wayland clipboard tools (`wl-clipboard`) for **Copy path**
- Nautilus (`nautilus`) for **Reveal in files**
- At least one supported editor command: `code`, `code-insiders`, `codium`, or `code-oss`

Install the runtime dependencies with:

```bash
omarchy pkg add sqlite zenity wl-clipboard nautilus
```

## Installation

### Prebuilt release bundle

The x86_64 release bundle is the simplest installation path and does not require a Rust toolchain. The example uses GitHub CLI (`gh`); the same two assets can also be downloaded from the [Releases page](https://github.com/christestet/omarchy-vscode-projects/releases):

```bash
release_dir=$(mktemp -d)
trap 'rm -rf -- "$release_dir"' EXIT
gh release download --repo christestet/omarchy-vscode-projects \
  --pattern '*-x86_64-unknown-linux-gnu.tar.gz' \
  --pattern SHA256SUMS \
  --dir "$release_dir"
(cd "$release_dir" && sha256sum --check SHA256SUMS)
gh attestation verify "$release_dir"/*.tar.gz \
  --repo christestet/omarchy-vscode-projects
mkdir -p "$HOME/.config/omarchy/plugins"
tar -xzf "$release_dir"/*-x86_64-unknown-linux-gnu.tar.gz \
  -C "$HOME/.config/omarchy/plugins"
omarchy plugin validate "$HOME/.config/omarchy/plugins/christestet.vscode-projects"
omarchy-shell shell rescanPlugins
omarchy plugin enable christestet.vscode-projects --section right
rm -rf -- "$release_dir"
trap - EXIT
```

The checksum detects a damaged download, while `gh attestation verify` confirms that GitHub Actions built the archive from this repository. The archive contains exactly the runtime plugin directory: `manifest.json`, `Panel.qml`, the compiled helper, README, and license. Use this procedure for a fresh bundle installation; bundle installations are not git-managed checkouts and therefore cannot be updated with `omarchy plugin update`.

### Build from source

```bash
omarchy plugin add https://github.com/christestet/omarchy-vscode-projects.git
cd ~/.config/omarchy/plugins/christestet.vscode-projects
omarchy pkg add rust pkgconf sqlite
./scripts/build-helper
omarchy plugin enable christestet.vscode-projects --section right
```

Omarchy validates and clones plugin repositories but deliberately does not execute build hooks. If `omarchy plugin add` asks whether to enable the plugin, leave it disabled until `./scripts/build-helper` has installed the helper. The explicit build step compiles the auditable Rust source in release mode and installs the binary inside the plugin directory. The default bar placement is the right section.

### Omarchy compatibility

| Omarchy version | Support | Installation |
|---|---|---|
| 4.0 or newer | Supported | Release bundle or source checkout |
| Earlier than 4.0 | Not supported | No compatible plugin API |

Omarchy 3.x used Waybar and did not provide the Quickshell manifest/plugin API this widget targets. A bundle containing this QML plugin cannot make it work on `<4.0.0`; supporting that line would require a separate Waybar module rather than a different package layout.

To enable or move it later:

```bash
omarchy plugin enable christestet.vscode-projects --section right
omarchy bar move christestet.vscode-projects --section right
```

## Usage

### Bar icon

| Input | Action |
|---|---|
| Left click | Open or close the projects panel |
| Right click | Refresh recent projects and show a confirmation notification |
| Middle click | Open a new VS Code window |

Hovering the icon shows a concise native Omarchy tooltip. The plugin does not install a global shortcut; optional bindings are documented below.

### Project list

| Input | Action |
|---|---|
| Type | Filter projects by name or path |
| Up / Down | Move the selection |
| Enter / Left click | Open the selected project |
| Shift+Enter / Middle click | Open the project in a new window |
| Right Arrow / Right click | Show project actions |
| Escape | Clear search, return from actions, or close the panel |
| 1–9 | Open the corresponding visible project |
| Ctrl+O | Open a folder picker |
| Ctrl+N | Open a new VS Code window |
| Ctrl+R | Refresh recent projects and show a confirmation notification |

### Project actions

- Open
- Open in new window
- Open terminal here
- Reveal in files
- Copy path
- Pin or unpin project

### Settings

Select the gear button beside **VS Code Projects** to open Settings. From there you can:

- Set the number of recent projects shown with a slider (3–30).
- Choose whether projects reuse the current editor window or open a new one.
- Refresh the project history with a confirmation notification.
- Unpin all projects with a second-press confirmation.

The slider supports dragging, clicking, and mouse-wheel adjustments. `−` and `+` remain available for keyboard adjustment. Changes are persisted through Omarchy's native bar configuration.

Select the keyboard button beside **VS Code Projects** for a complete, scrollable reference of keyboard and mouse shortcuts. Select it again, press `Left`, or press `Escape` to return.

Pinned projects are stored in:

```text
~/.config/omarchy/vscode-projects.json
```

## Configuration

The widget exposes these settings through Omarchy's bar configuration:

| Setting | Default | Description |
|---|---:|---|
| `maxProjects` | `10` | Maximum number of recent projects, from 3 to 30 |
| `openMode` | `reuse` | Open projects in the existing window (`reuse`) or a new window (`new`) |

Example widget entry inside the desired `bar.layout` section of `~/.config/omarchy/shell.json`:

```json
{
  "id": "christestet.vscode-projects",
  "maxProjects": 10,
  "openMode": "reuse"
}
```

## IPC and keybindings

The panel provides Omarchy's standard plugin IPC surface:

```bash
omarchy-shell shell toggle christestet.vscode-projects
omarchy-shell shell summon christestet.vscode-projects
omarchy-shell shell hide christestet.vscode-projects
omarchy-shell christestet.vscode-projects refresh
omarchy-shell christestet.vscode-projects openRecent
omarchy-shell christestet.vscode-projects openFolder
omarchy-shell christestet.vscode-projects newWindow
```

These commands can be used from personal Hyprland keybindings. The plugin does not add or remove global keybindings itself.

Before adding one, run `omarchy menu keybindings --print`. If a chord is already in use, choose another chord or explicitly unbind the existing action with `hl.unbind("...")` before the new `o.bind(...)` entry.

For example, add optional native Omarchy/Hyprland bindings to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + O", "VS Code projects", "omarchy-shell shell toggle christestet.vscode-projects")
o.bind("SUPER + CTRL + ALT + O", "Open recent VS Code project", "omarchy-shell christestet.vscode-projects openRecent")
```

## How it works

`Panel.qml` renders the native bar button and popup. The folder picker runs as a separate Zenity process so GTK is kept outside the long-running Quickshell process. The `vsc-recent-projects` Rust helper reads the ordered `history.recentlyOpenedPathsList` value from each editor's shared `state.vscdb` database (used by current VS Code) and falls back to the editor-local database and then legacy `storage.json`. It intentionally does not scan `workspaceStorage`, which is a cache rather than the Open Recent list. SQLite is opened read-only through the system library. Global actions automatically use the first available editor, preferring the editor associated with a pinned or recent project.

The helper is a short-lived native process rather than a library loaded into the long-running shell. That matches the isolation pattern used by Omarchy's built-in plugins: QML owns presentation and IPC while bounded external work runs through `Quickshell.Io.Process`. A malformed editor database can therefore be killed by the panel's one-second deadline without taking down `omarchy-shell`.

Editor state is treated as untrusted, replaceable input. JSON values and SQLite values are limited to 1 MiB; SQLite databases and sidecars to 64 MiB; and canonical history entries to 500. The helper opens the database and any WAL/SHM/journal sidecars as non-symlinked descriptors and presents those descriptors through a private SQLite namespace, preventing a path replacement from changing the checked files. SQLite work, returned projects, pin data, helper output, and QML output accumulation are bounded. The panel also force-kills a stalled helper after one second, so malformed state cannot leave the long-running shell process waiting indefinitely.

Supported editor data directories:

| Editor | Configuration directory |
|---|---|
| VS Code | `~/.config/Code` |
| VS Code Insiders | `~/.config/Code - Insiders` |
| VSCodium | `~/.config/VSCodium` |
| Code OSS | `~/.config/Code - OSS` |

For current VS Code releases, the preferred MRU sources are `~/.vscode-shared/sharedStorage/state.vscdb`, `~/.vscode-insiders-shared/sharedStorage/state.vscdb`, and the equivalent VSCodium or Code OSS shared-data directories. The editor-local paths above remain compatibility fallbacks.

## Updating and removal

For a source checkout:

```bash
omarchy plugin update christestet.vscode-projects
cd ~/.config/omarchy/plugins/christestet.vscode-projects
./scripts/build-helper
```

`omarchy plugin update` only updates git-managed source checkouts. For a release-bundle installation, remove the installed bundle and repeat the verified installation procedure above. Omarchy backs up a manually installed plugin directory during removal and prints the exact backup path.

To remove it:

```bash
omarchy plugin remove christestet.vscode-projects
```

Removing the plugin does not delete the optional pin file at `~/.config/omarchy/vscode-projects.json`.

What happens to the helper binary depends on the installation method:

- For a source checkout, Omarchy removes the complete git checkout, including `bin/vsc-recent-projects` and local build output inside it.
- For a release bundle, Omarchy moves the complete plugin directory, including the binary, to the timestamped backup path printed by the command. After reviewing that path, delete that exact backup manually if you no longer need it.

For a complete personal cleanup, also remove the pin file if you do not want to keep it:

```bash
rm -f -- "$HOME/.config/omarchy/vscode-projects.json"
```

Delete any optional `o.bind(...)` entries you copied into `~/.config/hypr/bindings.lua`. Reload and check Hyprland after changing bindings:

```bash
hyprctl reload
hyprctl configerrors
```

The runtime and build packages installed above may be shared by other software, so the plugin removal command deliberately leaves them installed.

## Troubleshooting

Validate a checkout:

```bash
omarchy plugin validate .
```

Refresh plugin discovery and open the panel:

```bash
omarchy-shell shell rescanPlugins
omarchy-shell shell summon christestet.vscode-projects
```

If no recent projects appear, open a local folder in a supported editor first. Remote-only workspaces and missing paths are intentionally omitted.

If the panel reports that its helper is missing or invalid, run `./scripts/build-helper` in a source checkout. For a bundle installation, remove it and repeat the checksum- and provenance-verified installation instead of copying an unverified binary into `bin/`.

## Development

```bash
omarchy plugin validate .
./scripts/lint-qml
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
./scripts/build-helper
./scripts/check-release bin/vsc-recent-projects
./scripts/package-release bin/vsc-recent-projects dist x86_64-unknown-linux-gnu
```

Files below `~/.config/omarchy/plugins/` hot-reload during development. Release Please keeps `Cargo.toml`, `Cargo.lock`, `manifest.json`, the linked README version, and `CHANGELOG.md` in sync from Conventional Commits. See [CONTRIBUTING.md](./CONTRIBUTING.md) for commit and release rules.

## Privacy and security

The plugin reads editor history only from local configuration files. It performs no background network requests and sends no telemetry. Selecting the repository link explicitly opens the project page in your browser. Like every Omarchy shell plugin, it runs unsandboxed inside `omarchy-shell`; review third-party plugin code before installing it. Please report vulnerabilities as described in [SECURITY.md](./SECURITY.md).

## License

[MIT](./LICENSE)

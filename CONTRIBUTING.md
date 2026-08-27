# Contributing

Thanks for improving VS Code Projects. Changes should stay focused, preserve Omarchy's native shell behavior, and keep editor-state processing bounded.

## Local checks

Install the build dependencies, then run:

```bash
omarchy plugin validate .
./scripts/lint-qml
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo build --locked --release
./scripts/check-release target/release/vsc-recent-projects
```

The QML lint uses the installed Omarchy shell modules by default. Set `OMARCHY_SHELL_ROOT` to another shell source tree when checking compatibility with a specific version. Test `Panel.qml` changes inside the current Omarchy shell as well; user plugins below `~/.config/omarchy/plugins/` hot-reload when saved.

## Conventional Commits

PR titles and commits merged to `main` use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

- `fix: ...` creates a patch release.
- `feat: ...` creates a minor release.
- `fix!: ...`, `feat!: ...`, or a `BREAKING CHANGE:` footer creates a major release.
- `docs:`, `test:`, `refactor:`, `chore:`, and `ci:` describe non-release changes unless they carry a breaking-change marker.

Use a short optional scope when it helps, for example `fix(helper): reject oversized history entries`.

## Release flow

Release Please maintains a release PR from conventional commits. Merging that PR updates `Cargo.toml`, `Cargo.lock`, `manifest.json`, the README version, and `CHANGELOG.md`, then creates a `vX.Y.Z` GitHub release. The release workflow builds the helper, produces the Omarchy runtime bundle and `SHA256SUMS`, attests their provenance, and attaches them to the release.

For the first automated release only, the bootstrap manifest records the previous source version `0.3.3`. Commit the release automation with the following subject and footer so Release Please opens the already-prepared `0.4.0` release PR instead of calculating another version:

```text
feat(release): add verified native plugin bundles

Release-As: 0.4.0
```

After that release PR is merged, Release Please writes `0.4.0` to the manifest itself. Future `feat:`, `fix:`, and breaking-change commits calculate versions normally and do not need a `Release-As` footer.

The workflow falls back to `GITHUB_TOKEN`. Before the first run, either enable **Settings → Actions → General → Allow GitHub Actions to create and approve pull requests**, or configure a fine-grained `RELEASE_PLEASE_TOKEN` repository secret with contents, pull-request, and issue write access. A separate token is also required when release PRs must trigger other GitHub Actions workflows automatically; GitHub deliberately suppresses workflow runs caused by the default token.

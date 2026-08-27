## Summary

Describe the user-visible change and why it is needed.

## Validation

- [ ] `omarchy plugin validate .`
- [ ] `./scripts/lint-qml`
- [ ] `cargo fmt --all -- --check`
- [ ] `cargo clippy --locked --all-targets -- -D warnings`
- [ ] `cargo test --locked`
- [ ] I tested the widget in the current Omarchy shell when QML behavior changed.

## Release impact

- [ ] The PR title follows Conventional Commits (`fix:`, `feat:`, or `type!:` for a breaking change).
- [ ] Documentation and screenshots are updated when user-facing behavior changed.

# Changelog

All notable changes to NOVA COMPUTER USE will be documented here.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). No stable release has been published yet.

## [Unreleased]

### Added

- Native Swift computer-control engine for macOS 15 and newer.
- Six-tool MCP interface: `list_apps`, `get_app_state`, `click`, `type_text`, `press_key`, and `scroll`.
- Universal `x86_64` and `arm64` build output containing the MCP adapter and `NovaComputerUseService.app` helper.
- Bounded Accessibility snapshots, main-display captures, input validation, frontmost-app verification, and stable service error codes.
- Automated Swift tests, packaging fixtures, release verification, and reversible local install/uninstall scripts.
- AGPL-3.0-only licensing with preserved derivation attribution in `THIRD_PARTY_NOTICES.md`.

### Security

- Requests and responses moved from regular files to an owner-only Unix-domain socket with in-memory framed payloads.
- Typed text and Accessibility trees are not persisted by Nova; temporary PNG captures are replaced and cleaned on shutdown or a later stale-file sweep.
- Installation validates manifests, architectures, code signatures, and the stable helper identifier before publication.

[Unreleased]: https://github.com/theodorebeaupre-prog/nova-computer-use/commits/main

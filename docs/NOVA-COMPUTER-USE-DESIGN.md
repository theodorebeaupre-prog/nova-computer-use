# NOVA COMPUTER USE — Design Specification

> Public copy of the approved design specification from `sentient-os` commit `2e304df`.

**Date:** 2026-07-21
**Status:** Approved for implementation
**Repository:** `theodorebeaupre-prog/nova-computer-use`

## Product definition

NOVA COMPUTER USE is a native macOS installer and configuration app that gives Codex local computer-control capabilities. It is designed for inexperienced users who should not need Terminal knowledge to install, authorize, test, repair, or remove the integration.

Nova is an independent open-source product, not a Sentient OS component. All public symbols, executables, bundle identifiers, plugin metadata, documentation, and visible copy will use the Nova name.

The first release is an installer and health dashboard, not a chat client and not an autonomous agent.

## Supported systems

- macOS 15 or newer.
- Intel `x86_64` and Apple Silicon `arm64` from one universal distribution.
- Codex CLI and the Codex desktop app where their plugin configuration is compatible.
- Signed and notarized distribution through a DMG attached to GitHub Releases.

The initial real-hardware acceptance baseline is an Intel MacBookPro16,1. Apple Silicon must pass compilation, automated tests, architecture checks, and a real-hardware acceptance run before the first stable release.

## User experience

Nova presents a short guided setup:

1. **Welcome:** “Give Codex hands and eyes.”
2. **System check:** detect the Mac architecture, macOS version, Codex CLI, and current plugin state.
3. **Codex setup:** recognize an existing Codex installation or provide clear installation guidance.
4. **Permissions:** explain and request Accessibility and Screen Recording for the exact signed Nova helper. Buttons open the relevant System Settings panes.
5. **Plugin installation:** copy and enable the bundled Nova plugin while preserving unrelated Codex settings.
6. **Safe test:** use a temporary, non-sensitive TextEdit document to verify app discovery, screen capture, accessibility inspection, clicking, typing, keyboard input, and scrolling.
7. **Ready:** show a green status for every component and a concise next step for using Nova from Codex.

After onboarding, the app becomes a health dashboard with repair, reinstall, diagnostics, log viewing, and uninstall actions. Errors use plain language and one precise recovery action. Raw technical details remain available behind a disclosure control.

## Visual direction

The approved direction is **Aurora Breathing Orbit**:

- a dark, restrained macOS interface;
- a full-spectrum gradient that travels continuously around important window or card contours;
- a slow breathing outer glow layered over the orbital motion;
- cyan, violet, pink, and warm amber accents;
- motion that feels calm and trustworthy, not gamer-RGB;
- reduced-motion support that replaces animation with a static gradient border;
- strong contrast, keyboard navigation, VoiceOver labels, and scalable type.

The wordmark is **NOVA**, while the full product name is **NOVA COMPUTER USE**. Nova is conceptually positioned as a friendly counterpart to “Sky,” but public documentation must describe Nova on its own merits and avoid implying endorsement or affiliation.

## Architecture

### Nova app

A SwiftUI macOS app owns onboarding, health status, installation, repair, diagnostics, and uninstall flows. It never controls other apps directly and never edits the macOS TCC database.

### NovaComputerUseService

A signed helper app owns macOS Accessibility and Screen Recording permissions. It performs app discovery, verified app activation, bounded accessibility snapshots, ScreenCaptureKit capture, clicks, Unicode typing, keyboard shortcuts, and scrolling.

The helper keeps a stable bundle identifier and designated requirement across releases so macOS permissions survive normal updates.

### NovaComputerUseMCP

A small stdio MCP adapter launches one signed helper through LaunchServices for the lifetime of the MCP session. It translates bounded newline-delimited MCP messages into framed JSON requests on an owner-only Unix-domain socket. The persistent helper retains the latest Accessibility snapshot so a subsequent tool call can use its element indexes. It exposes six tools:

- `list_apps`
- `get_app_state`
- `click`
- `type_text`
- `press_key`
- `scroll`

### Codex plugin

The app bundles a self-contained Codex plugin with its MCP manifest and Computer Use skill. Installation uses an atomic staging directory, validates expected hashes and architectures, preserves unrelated configuration, enables Nova, and removes only configuration owned by Nova during uninstall.

## Data and security boundaries

- Nova makes no network requests for computer-control operations.
- Accessibility trees and typed text are not persisted.
- Captures are stored only in a process-specific temporary directory.
- A returned capture remains available until a successfully finalized replacement exists. Failed capture or PNG finalization preserves it and removes the partial candidate; orderly MCP/helper shutdown removes all remaining tracked captures.
- The MCP and helper mutually verify the exact bundled peer process path and valid code signature before dispatch. Fresh 32-byte session challenges stay in memory/on the connected socket and never appear in arguments or regular files.
- The production helper rejects direct stdio requests. A heartbeat preserves active MCP sessions, while a 120-second authenticated-traffic idle bound cleans abandoned helpers.
- Requests, responses, strings, accessibility traversal, and screenshots have explicit size and work bounds.
- Input is sent only after the requested app is resolved and verified as frontmost.
- Snapshot element indexes are local to the latest snapshot; stale references fail closed.
- Nova never scripts permission toggles and never modifies TCC.
- Logs redact typed content, accessibility text, file paths containing usernames where practical, and screenshot contents.
- The README documents the power and risk of computer control in plain language.

## Installation and updates

The distribution is a universal, signed, notarized DMG. The app and helper are signed with Developer ID Application credentials associated with the developer’s Apple Developer account. Notarization is performed in CI without committing credentials.

GitHub Releases hosts the DMG, checksums, release notes, and update metadata. Automatic updates may be added using Sparkle, but the first implementation may ship a “Check for updates” link if a secure signed feed would delay the initial release.

## Open-source repository

The public repository is `theodorebeaupre-prog/nova-computer-use`. It contains:

- the Nova app;
- the universal Swift package and native helper;
- the Codex plugin and skill;
- build, install, verification, packaging, and notarization scripts;
- automated tests;
- contribution and security policies;
- architecture and troubleshooting documentation;
- an AGPL-3.0 license inherited from the source project.

The README leads with a polished product explanation and visual demo, followed by a three-step installation path, compatibility, permissions, security model, tools, architecture, local development, testing, troubleshooting, contribution, roadmap, and license. It distinguishes verified behavior from planned behavior and does not claim Apple Silicon hardware acceptance before it occurs.

## Failure handling

Nova detects and explains at least these cases:

- unsupported macOS version or architecture;
- missing or outdated Codex CLI;
- malformed or conflicting Codex configuration;
- plugin files missing, modified, or built for the wrong architecture;
- Accessibility or Screen Recording not granted to the current signed helper;
- helper launch, timeout, crash, or malformed response;
- target application absent or unable to become frontmost;
- stale accessibility snapshot;
- signing, notarization, quarantine, or update verification failure.

Repair operations are idempotent. They preserve a recoverable backup before changing user configuration and clearly report what changed.

## Verification strategy

- Unit tests cover protocol validation, app resolution, activation, accessibility bounds, capture cleanup, input validation, configuration migration, and error shaping.
- MCP integration tests cover initialization, tool listing, persistent cross-call snapshot use, capture lifetime, mutual authentication, peer rejection, idle timeout/heartbeat behavior, malformed frames, cancellation, and bounded child cleanup.
- Build verification checks both `x86_64` and `arm64`, then creates and inspects a universal binary.
- Bundle verification checks identifiers, manifests, signatures, designated requirements, plugin discovery, and absence of unintended dependencies.
- UI tests cover onboarding state transitions and repair flows without altering real TCC state.
- Manual acceptance runs the safe TextEdit flow twice from fresh Codex sessions on both Intel and Apple Silicon hardware.
- Completion requires zero remaining helper processes, session IPC directories, and temporary capture files after MCP shutdown.

## Initial scope exclusions

- Built-in chat or model hosting.
- Autonomous scheduling or unattended workflows.
- Remote control or cloud relay.
- Drag-and-drop, advanced text selection, and arbitrary secondary Accessibility actions.
- iOS, iPadOS, Windows, or Linux support.
- Editing macOS permission databases or bypassing system consent.

These exclusions keep the first release understandable, auditable, and safe.

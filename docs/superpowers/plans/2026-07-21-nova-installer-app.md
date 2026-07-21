# Nova Installer App Implementation Plan

**Goal:** Ship a universal native SwiftUI installer and health dashboard that installs, verifies, repairs, tests, and removes the bundled Nova Codex plugin without requiring Terminal knowledge.

**Architecture:** Add a testable `NovaInstallerCore` library for environment inspection and bounded process execution, plus a `NovaApp` SwiftUI executable. Package the executable as a universal `.app` containing the already verified plugin and installer scripts, then produce a DMG. The app opens macOS permission panes but never edits TCC.

**Tech stack:** Swift 6, SwiftUI/AppKit, Swift Package Manager, XCTest, shell packaging scripts, codesign, hdiutil.

---

## Task 1: Installer core and tests

- Add `NovaInstallerCore` models for system, Codex, plugin, and permission health.
- Add an injectable process runner and resource locator.
- Add install, repair, uninstall, permission-settings, diagnostics, and safe-test operations.
- Write unit tests first for inspection, command arguments, status shaping, and redaction.
- Run `swift test`.

## Task 2: Native SwiftUI app

- Add a `NovaApp` executable product and target.
- Build onboarding and dashboard state transitions around `NovaInstallerCore`.
- Add the Aurora Breathing Orbit border, breathing glow, reduced-motion fallback, keyboard focus, VoiceOver labels, and scalable layouts.
- Add plain-language errors with optional technical details.
- Compile both architectures.

## Task 3: Universal app and DMG packaging

- Add `scripts/build-app.sh` to build Intel and Apple Silicon slices, create `Nova.app`, embed the plugin/scripts, and sign nested code in the correct order.
- Add `scripts/package-dmg.sh` and verification checks for bundle identifiers, resources, signatures, and architectures.
- Keep ad-hoc signing as the local-development default and support Developer ID through environment variables.
- Verify the app bundle and DMG locally.

## Task 4: CI and public documentation

- Extend CI to test and build the universal app.
- Update README installation, screenshots/visual status, limitations, and developer instructions without claiming notarization or Apple Silicon hardware acceptance prematurely.
- Add app packaging tests and run the full verification suite.

## Task 5: GitHub delivery

- Review the diff and run release verification.
- Commit the feature branch and push it.
- Open a pull request with exact verification evidence and remaining manual acceptance steps.

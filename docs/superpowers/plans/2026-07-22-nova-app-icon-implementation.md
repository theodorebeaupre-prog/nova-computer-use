# Nova App Icon Implementation Plan

**Goal:** Generate, package, integrate, and verify the approved exploding-Nova macOS icon.

## Tasks

1. Generate a square 1024px exploding-Nova master and inspect it at full and thumbnail sizes.
2. Add a deterministic icon builder that validates the source, creates every required iconset size, and compiles `Nova.icns`.
3. Embed `Nova.icns` in `Nova.app`, declare `CFBundleIconFile`, and extend app verification.
4. Rebuild the universal app and custom DMG, visually inspect the mounted 96-point icon, run tests, commit, and push PR #3.

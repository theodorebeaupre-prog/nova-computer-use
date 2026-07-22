# Custom Nova DMG Implementation Plan

**Goal:** Produce a branded spatial Nova DMG with a reliable drag-to-Applications Finder layout.

## Tasks

1. Generate a text-free dark Nova nebula background, crop it to 660 × 420, then add exact title and orbital installation guidance deterministically.
2. Replace the simple source-folder DMG script with a writable-image workflow that mounts, configures Finder icon view, writes `.DS_Store`, detaches, compresses, and checksums the final image.
3. Add a verifier for mounted contents, background dimensions, Finder metadata, universal app architectures, and signature validity.
4. Build, mount, visually inspect, run all tests, commit, push, and update PR #2.

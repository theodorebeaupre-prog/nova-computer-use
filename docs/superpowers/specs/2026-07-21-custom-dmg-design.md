# Nova Custom DMG Design

**Status:** Approved visual direction, pending written-spec review  
**Date:** 2026-07-21

## Goal

Replace the plain Finder presentation in Nova’s DMG with a polished, beginner-friendly installation window that clearly communicates dragging Nova into Applications.

## Visual direction

The background uses the approved **Nova spatial** direction:

- 660 × 420 pixel Finder canvas;
- very dark navy and black space backdrop;
- restrained blue, violet, magenta, and cyan nebula lighting;
- a luminous Nova-like orbital focal point near the center;
- subtle stars and atmospheric depth without visual noise;
- `NOVA COMPUTER USE` title near the top;
- a clean orbital path or arrow moving from Nova on the left toward Applications on the right;
- no text or bright detail directly behind either Finder icon.

The image must feel premium and trustworthy rather than like gaming RGB artwork. It must contain no third-party logos, watermark, fake app icons, or extra interface elements.

## Finder layout

- Window size: 660 × 420.
- Icon view with toolbar and status bar hidden.
- Nova app icon positioned on the left at approximately `(170, 235)`.
- Applications alias positioned on the right at approximately `(490, 235)`.
- Icon size approximately 96 points with labels visible.
- Background stored inside the image as `.background/nova-dmg-background.png`.
- Finder metadata is written to the writable staging image before conversion to the final compressed DMG.

## Packaging flow

`scripts/package-dmg.sh` will:

1. verify or build `dist/Nova.app`;
2. create a writable temporary disk image;
3. mount it and copy Nova plus an Applications symlink;
4. copy the generated background into the hidden `.background` directory;
5. apply the approved Finder window, icon, and background layout using Finder scripting;
6. detach the image cleanly;
7. convert it to the final compressed universal DMG;
8. generate and verify its SHA-256 checksum.

If Finder scripting fails, packaging fails instead of silently publishing a plain DMG.

## Verification

- Mount the resulting DMG read-only.
- Confirm Nova.app, Applications, and the hidden background asset exist.
- Confirm the background image is exactly 660 × 420.
- Confirm `.DS_Store` exists and records an icon-view window.
- Confirm Nova remains a universal `x86_64 arm64` application with a valid local signature.
- Visually inspect the mounted DMG once on the Intel development Mac.

## Scope boundary

This change customizes presentation only. Developer ID signing, notarization, the final Nova app icon, and Apple Silicon physical acceptance remain separate release tasks.

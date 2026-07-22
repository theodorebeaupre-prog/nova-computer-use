# Nova App Icon Design

**Status:** Approved visual direction, pending written-spec review  
**Date:** 2026-07-22

## Goal

Create a distinctive macOS application icon for Nova that remains recognizable from Finder’s largest icon view down to the smallest system presentation.

## Approved direction

The icon uses the approved **exploding Nova** concept:

- one brilliant white stellar core centered in the composition;
- energetic cyan, violet, and magenta plasma expanding around the core;
- convincing dimensional depth with a polished, premium finish;
- a deep midnight-blue spatial backdrop;
- a controlled silhouette that remains readable at small sizes;
- no letters, words, external logos, watermark, spacecraft, or planets.

The result should feel powerful and modern without becoming visually noisy or gamer-RGB.

## macOS construction

- Master artwork: 1024 × 1024 PNG.
- Artwork composed for the macOS rounded-square icon mask with generous edge safety.
- Important light and plasma remain inside the central 70% safe region.
- Subtle edge falloff prevents clipping under the system mask.
- The source image remains full-bleed; macOS applies the final icon silhouette.

## Deliverables

- project master at `Assets/AppIcon/nova-app-icon-1024.png`;
- complete `Nova.iconset` raster sizes from 16 × 16 through 1024 × 1024;
- compiled `Assets/AppIcon/Nova.icns`;
- `Nova.app` configured through `CFBundleIconFile`;
- packaging verification confirming the icon exists inside the bundle;
- rebuilt custom DMG showing the new icon.

## Verification

- Validate master and every iconset dimension.
- Compile successfully with `iconutil`.
- Rebuild and verify the universal app.
- Rebuild and verify the custom DMG.
- Mount the DMG and visually inspect the icon at Finder’s 96-point size.
- Confirm the icon is still recognizable at 16 × 16.

## Scope boundary

This change creates and integrates the visual icon only. Developer ID signing, notarization, and Apple Silicon physical acceptance remain separate release tasks.

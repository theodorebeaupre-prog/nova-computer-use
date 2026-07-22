#!/usr/bin/env bash
set -euo pipefail

dmg="${1:-dist/Nova-1.0.0-universal.dmg}"
mount_root="$(mktemp -d "${TMPDIR:-/tmp}/nova-dmg-verify.XXXXXX")"
device=""
cleanup() {
    if [[ -n "$device" ]]; then hdiutil detach "$device" -quiet || true; fi
    rm -rf -- "$mount_root"
}
trap cleanup EXIT

[[ -f "$dmg" ]]
device="$(hdiutil attach "$dmg" -readonly -noverify -noautoopen -mountpoint "$mount_root" | awk '/^\/dev\// {print $1; exit}')"
[[ -n "$device" ]]
[[ -d "$mount_root/Nova.app" ]]
[[ -L "$mount_root/Applications" ]]
[[ -f "$mount_root/.background/nova-dmg-background.png" ]]
[[ -f "$mount_root/.DS_Store" ]]
dimensions="$(sips -g pixelWidth -g pixelHeight "$mount_root/.background/nova-dmg-background.png" 2>/dev/null)"
grep -Fq 'pixelWidth: 660' <<< "$dimensions"
grep -Fq 'pixelHeight: 420' <<< "$dimensions"
architectures="$(lipo -archs "$mount_root/Nova.app/Contents/MacOS/Nova")"
[[ "$architectures" == 'x86_64 arm64' || "$architectures" == 'arm64 x86_64' ]]
xattr -cr "$mount_root/Nova.app" 2>/dev/null || true
codesign --verify --deep --strict "$mount_root/Nova.app"
hdiutil detach "$device" -quiet
device=""
printf 'Verified custom Nova DMG (%s, 660x420 background).\n' "$architectures"

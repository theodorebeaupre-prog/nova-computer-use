#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
app="$repository_root/dist/Nova.app"
dmg="$repository_root/dist/Nova-1.0.0-universal.dmg"
source_background="$repository_root/Assets/DMG/nova-space-source.png"
rendered_background="$repository_root/Assets/DMG/nova-dmg-background.png"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/nova-dmg.XXXXXX")"
stage="$work_root/stage"
mount_point="/Volumes/NOVA COMPUTER USE"
read_write_image="$work_root/Nova-rw.dmg"
device=""

cleanup() {
    if [[ -n "$device" ]]; then hdiutil detach "$device" -quiet || true; fi
    rm -rf -- "$work_root"
}
trap cleanup EXIT

[[ -d "$app" ]] || "$repository_root/scripts/build-app.sh"
[[ -f "$source_background" ]]
if mount | grep -Fq 'on /Volumes/NOVA COMPUTER USE '; then
    hdiutil detach '/Volumes/NOVA COMPUTER USE' -quiet
fi
mkdir -p "$stage/.background"
xcrun swift "$repository_root/scripts/render-dmg-background.swift" "$source_background" "$rendered_background"
cp -R "$app" "$stage/Nova.app"
xattr -cr "$stage/Nova.app"
cp "$rendered_background" "$stage/.background/nova-dmg-background.png"
ln -s /Applications "$stage/Applications"

hdiutil create -quiet -volname 'NOVA COMPUTER USE' -srcfolder "$stage" -ov -format UDRW "$read_write_image"
device="$(hdiutil attach "$read_write_image" -readwrite -noverify -noautoopen | awk '/^\/dev\// {print $1; exit}')"
[[ -n "$device" ]]

open "$mount_point"
sleep 2
osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "NOVA COMPUTER USE"
        open
        set dmgWindow to container window
        set current view of dmgWindow to icon view
        set toolbar visible of dmgWindow to false
        set statusbar visible of dmgWindow to false
        set pathbar visible of dmgWindow to false
        set sidebar width of dmgWindow to 0
        set the bounds of dmgWindow to {120, 120, 780, 540}
        set viewOptions to the icon view options of dmgWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:nova-dmg-background.png"
        set position of item "Nova.app" of container window to {170, 235}
        set position of item "Applications" of container window to {490, 235}
        update without registering applications
        delay 2
        close dmgWindow
    end tell
end tell
APPLESCRIPT

sync
[[ -f "$mount_point/.DS_Store" ]] || {
    printf 'Finder did not write the custom DMG layout.\n' >&2
    exit 1
}
hdiutil detach "$device" -quiet
device=""

rm -f -- "$dmg" "$dmg.sha256"
hdiutil convert -quiet "$read_write_image" -format UDZO -imagekey zlib-level=9 -o "$dmg"
if [[ -n "${CODE_SIGN_IDENTITY:-}" && "${CODE_SIGN_IDENTITY}" != "-" ]]; then
    codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp "$dmg"
fi
shasum -a 256 "$dmg" > "$dmg.sha256"
"$repository_root/scripts/verify-dmg.sh" "$dmg"
printf 'Packaged custom Nova DMG: %s\n' "$dmg"

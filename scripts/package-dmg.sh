#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
app="$repository_root/dist/Nova.app"
dmg="$repository_root/dist/Nova-1.0.0-universal.dmg"
stage="$(mktemp -d "${TMPDIR:-/tmp}/nova-dmg.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT

[[ -d "$app" ]] || "$repository_root/scripts/build-app.sh"
cp -R "$app" "$stage/Nova.app"
ln -s /Applications "$stage/Applications"
rm -f -- "$dmg"
hdiutil create -quiet -volname 'NOVA COMPUTER USE' -srcfolder "$stage" -ov -format UDZO "$dmg"
shasum -a 256 "$dmg" > "$dmg.sha256"
printf 'Packaged Nova DMG: %s\n' "$dmg"

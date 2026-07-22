#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
icon="${1:-$repository_root/Assets/AppIcon/Nova.icns}"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/nova-icon-verify.XXXXXX")"
trap 'rm -rf -- "$work_root"' EXIT

[[ -f "$icon" ]]
iconutil --convert iconset --output "$work_root/Nova.iconset" "$icon"
for expected in \
    'icon_16x16.png:16' 'icon_16x16@2x.png:32' \
    'icon_32x32.png:32' 'icon_32x32@2x.png:64' \
    'icon_128x128.png:128' 'icon_128x128@2x.png:256' \
    'icon_256x256.png:256' 'icon_256x256@2x.png:512' \
    'icon_512x512.png:512' 'icon_512x512@2x.png:1024'; do
    file="${expected%%:*}"
    pixels="${expected##*:}"
    dimensions="$(sips -g pixelWidth -g pixelHeight "$work_root/Nova.iconset/$file" 2>/dev/null)"
    grep -Fq "pixelWidth: $pixels" <<< "$dimensions"
    grep -Fq "pixelHeight: $pixels" <<< "$dimensions"
done
printf 'Verified Nova app icon (16 through 1024 pixels).\n'

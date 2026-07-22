#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_icon="$repository_root/Assets/AppIcon/nova-app-icon-1024.png"
iconset="$repository_root/Assets/AppIcon/Nova.iconset"
output="$repository_root/Assets/AppIcon/Nova.icns"

[[ -f "$source_icon" ]]
dimensions="$(sips -g pixelWidth -g pixelHeight "$source_icon" 2>/dev/null)"
grep -Fq 'pixelWidth: 1024' <<< "$dimensions"
grep -Fq 'pixelHeight: 1024' <<< "$dimensions"

rm -rf -- "$iconset"
mkdir -p "$iconset"
render() {
    local pixels="$1"
    local filename="$2"
    sips -z "$pixels" "$pixels" "$source_icon" --out "$iconset/$filename" >/dev/null
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

rm -f -- "$output"
iconutil --convert icns --output "$output" "$iconset"
[[ -f "$output" ]]
printf 'Built Nova app icon: %s\n' "$output"

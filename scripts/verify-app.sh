#!/usr/bin/env bash
set -euo pipefail

app="${1:-dist/Nova.app}"
[[ -d "$app" ]]
xattr -cr "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == 'dev.theodorebeaupre.Nova' ]]
architectures="$(lipo -archs "$app/Contents/MacOS/Nova")"
[[ "$architectures" == 'x86_64 arm64' || "$architectures" == 'arm64 x86_64' ]]
[[ -x "$app/Contents/Resources/scripts/install-local.sh" ]]
[[ -x "$app/Contents/Resources/dist/NovaComputerUsePlugin/bin/NovaComputerUseMCP" ]]
codesign --verify --deep --strict "$app"
printf 'Verified Nova app (%s).\n' "$architectures"

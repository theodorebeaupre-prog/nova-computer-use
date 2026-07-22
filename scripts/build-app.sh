#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
dist_root="$repository_root/dist"
app_path="$dist_root/Nova.app"
scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/nova-app-build.XXXXXX")"
identity="${CODE_SIGN_IDENTITY:--}"
sign_args=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
    sign_args+=(--options runtime --timestamp)
fi

cleanup() { rm -rf -- "$scratch_root"; }
trap cleanup EXIT

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    swift build -c release --arch x86_64 --product NovaApp --scratch-path "$scratch_root/x86_64"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    swift build -c release --arch arm64 --product NovaApp --scratch-path "$scratch_root/arm64"

find_product() {
    find "$scratch_root/$1" -type f -path '*/release/NovaApp' -perm -111 -print -quit
}

x86_binary="$(find_product x86_64)"
arm_binary="$(find_product arm64)"
[[ -x "$x86_binary" && -x "$arm_binary" ]]

if [[ ! -x "$dist_root/NovaComputerUsePlugin/bin/NovaComputerUseMCP" || \
      ! -x "$dist_root/NovaComputerUsePlugin/bin/NovaComputerUseService.app/Contents/MacOS/NovaComputerUseService" ]]; then
    "$repository_root/scripts/build-universal.sh"
fi

stage="$scratch_root/Nova.app"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources/scripts" "$stage/Contents/Resources/dist"
lipo -create "$x86_binary" "$arm_binary" -output "$stage/Contents/MacOS/Nova"
"$repository_root/scripts/build-app-icon.sh"
cp "$repository_root/Assets/AppIcon/Nova.icns" "$stage/Contents/Resources/Nova.icns"
cp -R "$dist_root/NovaComputerUsePlugin" "$stage/Contents/Resources/dist/"
cp "$repository_root/scripts/install-local.sh" "$stage/Contents/Resources/scripts/"
cp "$repository_root/scripts/uninstall-local.sh" "$stage/Contents/Resources/scripts/"
chmod +x "$stage/Contents/Resources/scripts/"*.sh

plutil -create xml1 "$stage/Contents/Info.plist"
plutil -insert CFBundleExecutable -string Nova "$stage/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string dev.theodorebeaupre.Nova "$stage/Contents/Info.plist"
plutil -insert CFBundleName -string Nova "$stage/Contents/Info.plist"
plutil -insert CFBundleDisplayName -string 'NOVA COMPUTER USE' "$stage/Contents/Info.plist"
plutil -insert CFBundleIconFile -string Nova "$stage/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$stage/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 1.0.0 "$stage/Contents/Info.plist"
plutil -insert CFBundleVersion -string 1 "$stage/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 15.0 "$stage/Contents/Info.plist"
plutil -insert NSHighResolutionCapable -bool YES "$stage/Contents/Info.plist"
plutil -insert NSHumanReadableCopyright -string 'Copyright © 2026 Théodore Beaupré' "$stage/Contents/Info.plist"

xattr -cr "$stage"
codesign "${sign_args[@]}" "$stage/Contents/Resources/dist/NovaComputerUsePlugin/bin/NovaComputerUseMCP"
codesign "${sign_args[@]}" "$stage/Contents/Resources/dist/NovaComputerUsePlugin/bin/NovaComputerUseService.app/Contents/MacOS/NovaComputerUseService"
codesign "${sign_args[@]}" "$stage/Contents/Resources/dist/NovaComputerUsePlugin/bin/NovaComputerUseService.app"
codesign "${sign_args[@]}" "$stage"
codesign --verify --deep --strict "$stage"

rm -rf -- "$app_path"
mv "$stage" "$app_path"
xattr -cr "$app_path"
codesign --verify --deep --strict "$app_path"
printf 'Built universal Nova app: %s\n' "$app_path"

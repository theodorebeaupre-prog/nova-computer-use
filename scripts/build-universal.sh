#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
dist_root="$repository_root/dist"
output_root="$dist_root/NovaComputerUsePlugin"
scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/nova-computer-use-build.XXXXXX")"
stage_root=""
previous_output=""

cleanup() {
    if [[ -n "$previous_output" && -d "$previous_output" && ! -e "$output_root" ]]; then
        mv "$previous_output" "$output_root"
        previous_output=""
    fi
    rm -rf -- "$scratch_root"
    if [[ -n "$stage_root" && -d "$stage_root" ]]; then
        rm -rf -- "$stage_root"
    fi
}
trap cleanup EXIT

build_product() {
    local architecture="$1"
    local scratch_path="$scratch_root/$architecture"
    swift build -c release --arch "$architecture" --scratch-path "$scratch_path"
}

require_product() {
    local architecture="$1"
    local product="$2"
    local product_path
    product_path="$(find "$scratch_root/$architecture" -type f -path "*/release/$product" -perm -111 -print -quit)"
    if [[ -z "$product_path" || ! -x "$product_path" ]]; then
        printf 'Missing %s build for %s.\n' "$architecture" "$product" >&2
        exit 1
    fi
    printf '%s\n' "$product_path"
}

make_universal_binary() {
    local product="$1"
    local x86_binary
    local arm_binary
    local universal_binary="$stage_root/bin/$product"
    x86_binary="$(require_product x86_64 "$product")"
    arm_binary="$(require_product arm64 "$product")"

    lipo -create "$x86_binary" "$arm_binary" -output "$universal_binary"
    local architectures
    architectures="$(lipo -archs "$universal_binary")"
    if [[ "$architectures" != "x86_64 arm64" && "$architectures" != "arm64 x86_64" ]]; then
        printf 'Expected universal %s, got architectures: %s\n' "$product" "$architectures" >&2
        exit 1
    fi
}

build_product x86_64
build_product arm64

mkdir -p "$dist_root"
stage_root="$scratch_root/NovaComputerUsePlugin"
mkdir -p "$stage_root/bin/NovaComputerUseService.app/Contents/MacOS"

make_universal_binary NovaComputerUseService
make_universal_binary NovaComputerUseMCP

mv "$stage_root/bin/NovaComputerUseService" "$stage_root/bin/NovaComputerUseService.app/Contents/MacOS/NovaComputerUseService"
cat > "$stage_root/bin/NovaComputerUseService.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>NovaComputerUseService</string>
    <key>CFBundleIdentifier</key>
    <string>dev.theodorebeaupre.NovaComputerUse.Service</string>
    <key>CFBundleName</key>
    <string>NovaComputerUseService</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

cp -R "$repository_root/Plugin/." "$stage_root/"
xattr -cr "$stage_root"

service_application="$stage_root/bin/NovaComputerUseService.app"
service_executable="$service_application/Contents/MacOS/NovaComputerUseService"
xattr -cr "$service_executable"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$service_executable"
xattr -cr "$service_application"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$service_application"
xattr -cr "$stage_root/bin/NovaComputerUseMCP"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$stage_root/bin/NovaComputerUseMCP"

publish_root="$(mktemp -d "$dist_root/.NovaComputerUsePlugin.staging.XXXXXX")"
rmdir "$publish_root"
mv "$stage_root" "$publish_root"
stage_root="$publish_root"
xattr -cr "$stage_root"

if [[ -e "$output_root" ]]; then
    previous_output="$(mktemp -d "$dist_root/.NovaComputerUsePlugin.previous.XXXXXX")"
    rmdir "$previous_output"
    mv "$output_root" "$previous_output"
fi
mv "$stage_root" "$output_root"
stage_root=""
xattr -cr "$output_root"
if [[ -n "$previous_output" ]]; then
    rm -rf -- "$previous_output"
    previous_output=""
fi

printf 'Built universal Nova Computer Use plugin: %s\n' "$output_root"

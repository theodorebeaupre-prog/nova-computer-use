#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_plugin="$repository_root/dist/NovaComputerUsePlugin"
codex_root="${CODEX_HOME:-$HOME/.codex}"
cache_root="$codex_root/plugins/cache/nova/computer-use"
plugin_target="$cache_root/1.0.0"
config_path="$codex_root/config.toml"
backup_path="$codex_root/config.toml.nova-computer-use.backup"
begin_marker='# BEGIN NOVA COMPUTER USE (managed)'
end_marker='# END NOVA COMPUTER USE (managed)'
stage_plugin=""
stage_config=""
previous_plugin=""
plugin_published=false
install_complete=false

cleanup() {
    if [[ -n "$stage_plugin" && -d "$stage_plugin" ]]; then rm -rf -- "$stage_plugin"; fi
    if [[ -n "$stage_config" && -f "$stage_config" ]]; then rm -f -- "$stage_config"; fi
    if [[ "$install_complete" != true && "$plugin_published" == true && -d "$plugin_target" ]]; then
        rm -rf -- "$plugin_target"
    fi
    if [[ "$install_complete" != true && -n "$previous_plugin" && -d "$previous_plugin" && ! -e "$plugin_target" ]]; then
        mv "$previous_plugin" "$plugin_target"
        previous_plugin=""
    fi
}
trap cleanup EXIT

require_source_plugin() {
    [[ -x "$source_plugin/bin/NovaComputerUseMCP" ]]
    [[ -x "$source_plugin/bin/NovaComputerUseService.app/Contents/MacOS/NovaComputerUseService" ]]
    [[ -f "$source_plugin/.codex-plugin/plugin.json" ]]
    [[ -f "$source_plugin/.mcp.json" ]]
}

remove_managed_block() {
    local source="$1"
    local destination="$2"
    awk -v begin="$begin_marker" -v end="$end_marker" '
        $0 == begin { if (inside) exit 2; inside = 1; next }
        $0 == end { if (!inside) exit 2; inside = 0; next }
        !inside { print }
        END { if (inside) exit 2 }
    ' "$source" > "$destination"
}

validate_plugin() {
    local plugin="$1"
    local mcp_binary="$plugin/bin/NovaComputerUseMCP"
    local service_application="$plugin/bin/NovaComputerUseService.app"
    local service_binary="$service_application/Contents/MacOS/NovaComputerUseService"
    local info_plist="$service_application/Contents/Info.plist"
    python3 - "$plugin" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for relative in (".codex-plugin/plugin.json", ".mcp.json"):
    with (root / relative).open(encoding="utf-8") as file:
        json.load(file)
PY
    [[ -x "$mcp_binary" ]]
    [[ -x "$service_binary" ]]
    plutil -lint "$info_plist" >/dev/null
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" == 'dev.theodorebeaupre.NovaComputerUse.Service' ]]
    local binary
    for binary in "$mcp_binary" "$service_binary"; do
        local architectures
        architectures="$(lipo -archs "$binary")"
        [[ "$architectures" == 'x86_64 arm64' || "$architectures" == 'arm64 x86_64' ]]
    done
    codesign --verify --strict "$mcp_binary"
    codesign --verify --deep --strict "$service_application"
}

require_source_plugin || { printf 'Run scripts/build-universal.sh first.\n' >&2; exit 1; }
mkdir -p "$cache_root" "$codex_root"
stage_plugin="$(mktemp -d "$cache_root/.1.0.0.staging.XXXXXX")"
cp -R "$source_plugin/." "$stage_plugin/"
xattr -cr "$stage_plugin"
validate_plugin "$stage_plugin"

if [[ ! -e "$backup_path" ]]; then
    if [[ -f "$config_path" ]]; then
        cp -p "$config_path" "$backup_path"
    else
        : > "$backup_path"
    fi
fi
stage_config="$(mktemp "$codex_root/.config.toml.nova-computer-use.XXXXXX")"
if [[ -f "$config_path" ]]; then
    remove_managed_block "$config_path" "$stage_config"
fi
{
    printf '\n%s\n' "$begin_marker"
    printf '[plugins."computer-use@nova"]\n'
    printf 'enabled = true\n'
    printf '%s\n' "$end_marker"
} >> "$stage_config"
grep -Fqx -- "$begin_marker" "$stage_config"
grep -Fqx -- "$end_marker" "$stage_config"

if [[ -e "$plugin_target" ]]; then
    previous_plugin="$(mktemp -d "$cache_root/.1.0.0.previous.XXXXXX")"
    rmdir "$previous_plugin"
    mv "$plugin_target" "$previous_plugin"
fi
mv "$stage_plugin" "$plugin_target"
stage_plugin=""
plugin_published=true
mv "$stage_config" "$config_path"
stage_config=""
install_complete=true
if [[ -n "$previous_plugin" ]]; then rm -rf -- "$previous_plugin"; fi

printf 'Installed Nova Computer Use locally.\n'
printf 'Grant Accessibility and Screen Recording permission to NovaComputerUseService when macOS asks.\n'

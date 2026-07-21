#!/usr/bin/env bash
set -euo pipefail

codex_root="${CODEX_HOME:-$HOME/.codex}"
cache_root="$codex_root/plugins/cache/nova/computer-use"
plugin_target="$cache_root/1.0.0"
config_path="$codex_root/config.toml"
begin_marker='# BEGIN NOVA COMPUTER USE (managed)'
end_marker='# END NOVA COMPUTER USE (managed)'
stage_config=""

cleanup() {
    if [[ -n "$stage_config" && -f "$stage_config" ]]; then rm -f -- "$stage_config"; fi
}
trap cleanup EXIT

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

if [[ -f "$config_path" ]]; then
    stage_config="$(mktemp "$codex_root/.config.toml.nova-computer-use.XXXXXX")"
    remove_managed_block "$config_path" "$stage_config"
    mv "$stage_config" "$config_path"
    stage_config=""
fi

if [[ -d "$plugin_target" ]]; then
    rm -rf -- "$plugin_target"
fi
rmdir "$cache_root" 2>/dev/null || true

printf 'Removed Nova Computer Use files and managed configuration. The config backup was preserved.\n'

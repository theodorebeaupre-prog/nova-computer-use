#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
plugin_root="${1:-}"
if [[ -z "$plugin_root" ]]; then
    printf 'Usage: %s path/to/NovaComputerUsePlugin\n' "$0" >&2
    exit 64
fi
requested_plugin_root="$(cd "$plugin_root" && pwd -P)"
verification_scratch="$(mktemp -d "${TMPDIR:-/tmp}/nova-computer-use-verify.XXXXXX")"
cleanup() {
    rm -rf -- "$verification_scratch"
}
trap cleanup EXIT
plugin_root="$verification_scratch/NovaComputerUsePlugin"
mkdir -p "$plugin_root"
cp -R "$requested_plugin_root/." "$plugin_root/"
xattr -cr "$plugin_root"
mcp_binary="$plugin_root/bin/NovaComputerUseMCP"
service_application="$plugin_root/bin/NovaComputerUseService.app"
service_binary="$service_application/Contents/MacOS/NovaComputerUseService"
info_plist="$service_application/Contents/Info.plist"

[[ -x "$mcp_binary" ]]
[[ -x "$service_binary" ]]
[[ -f "$info_plist" ]]
cmp "$repository_root/LICENSE" "$plugin_root/LICENSE"
cmp "$repository_root/THIRD_PARTY_NOTICES.md" "$plugin_root/THIRD_PARTY_NOTICES.md"

python3 - "$plugin_root" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for relative in (".codex-plugin/plugin.json", ".mcp.json"):
    with (root / relative).open(encoding="utf-8") as file:
        json.load(file)
PY
plutil -lint "$info_plist" >/dev/null

for binary in "$mcp_binary" "$service_binary"; do
    architectures="$(lipo -archs "$binary")"
    if [[ "$architectures" != "x86_64 arm64" && "$architectures" != "arm64 x86_64" ]]; then
        printf 'Expected universal binary, got: %s\n' "$architectures" >&2
        exit 1
    fi
done

codesign --verify --deep --strict "$service_application"
codesign --verify --strict "$mcp_binary"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
[[ "$identifier" == 'dev.theodorebeaupre.NovaComputerUse.Service' ]]

NOVA_MCP_BINARY="$mcp_binary" python3 - <<'PY'
import json
import os
import select
import subprocess

process = subprocess.Popen(
    [os.environ["NOVA_MCP_BINARY"]],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)

def request(payload):
    process.stdin.write(json.dumps(payload) + "\n")
    process.stdin.flush()
    ready, _, _ = select.select([process.stdout], [], [], 10)
    if not ready:
        raise RuntimeError("MCP request timed out")
    line = process.stdout.readline()
    if not line:
        raise RuntimeError("MCP server exited")
    return json.loads(line)

try:
    initialize = request({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "release-verifier", "version": "1"},
        },
    })
    if initialize.get("result", {}).get("protocolVersion") != "2025-03-26":
        raise RuntimeError("MCP initialize handshake failed")
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
    process.stdin.flush()
    listing = request({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    names = {tool["name"] for tool in listing.get("result", {}).get("tools", [])}
    required = {"list_apps", "get_app_state", "click", "type_text", "press_key", "scroll"}
    if names != required:
        raise RuntimeError(f"Unexpected MCP tools: {sorted(names)}")
    result = request({
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "list_apps", "arguments": {}},
    })
    call_result = result.get("result")
    if not isinstance(call_result, dict) or call_result.get("isError") is not False:
        raise RuntimeError("bounded list_apps call failed")
finally:
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)
PY

printf 'Release verification passed: %s\n' "$requested_plugin_root"

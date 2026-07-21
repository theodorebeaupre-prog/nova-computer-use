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

NOVA_MCP_BINARY="$mcp_binary" NOVA_SERVICE_BINARY="$service_binary" python3 - <<'PY'
import json
import os
import pathlib
import select
import shlex
import subprocess
import time

mcp_binary = str(pathlib.Path(os.environ["NOVA_MCP_BINARY"]).resolve())
service_binary = str(pathlib.Path(os.environ["NOVA_SERVICE_BINARY"]).resolve())

direct_service = subprocess.run(
    [service_binary],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    timeout=2,
)
if direct_service.returncode == 0:
    raise RuntimeError("service accepted unauthenticated direct launch")

def service_processes():
    output = subprocess.check_output(["ps", "-axo", "pid=,command=", "-ww"], text=True)
    matches = []
    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, command = stripped.partition(" ")
        try:
            arguments = shlex.split(command)
        except ValueError:
            continue
        if arguments and arguments[0] == service_binary:
            matches.append((int(pid_text), arguments))
    return matches

process = subprocess.Popen(
    [mcp_binary],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)
ipc_root = None

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
    first_processes = service_processes()
    if len(first_processes) != 1:
        raise RuntimeError(f"expected one persistent service, found {first_processes}")
    first_pid, service_arguments = first_processes[0]
    if "--ipc-token" in service_arguments:
        raise RuntimeError("session secret leaked into service argv")
    try:
        socket_index = service_arguments.index("--ipc-socket")
        socket_path = pathlib.Path(service_arguments[socket_index + 1])
    except (ValueError, IndexError):
        raise RuntimeError("service socket argument is missing")
    ipc_root = socket_path.parent.parent
    regular_files = [path for path in ipc_root.rglob("*") if path.is_file()]
    if regular_files:
        raise RuntimeError(f"regular IPC files found: {regular_files}")

    second = request({
        "jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": {"name": "list_apps", "arguments": {}},
    })
    second_result = second.get("result")
    if not isinstance(second_result, dict) or second_result.get("isError") is not False:
        raise RuntimeError("second bounded list_apps call failed")
    second_processes = service_processes()
    if [pid for pid, _ in second_processes] != [first_pid]:
        raise RuntimeError("service process was replaced between MCP calls")
finally:
    if process.poll() is None:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
    deadline = time.monotonic() + 3
    while service_processes() and time.monotonic() < deadline:
        time.sleep(0.05)
    remaining = service_processes()
    if remaining:
        raise RuntimeError(f"service survived MCP shutdown: {remaining}")
    if ipc_root is not None and ipc_root.exists():
        raise RuntimeError(f"IPC root survived MCP shutdown: {ipc_root}")
PY

printf 'Release verification passed: %s\n' "$requested_plugin_root"

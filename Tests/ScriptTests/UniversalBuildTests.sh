#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/nova-universal-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

assert_contains() {
    local needle="$1"
    local file="$2"
    if ! grep -Fq -- "$needle" "$file"; then
        printf 'Expected %s in %s\n' "$needle" "$file" >&2
        exit 1
    fi
}

make_shims() {
    mkdir -p "$fixture_root/bin"

    cat > "$fixture_root/bin/swift" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$NOVA_FIXTURE_LOG"
arch=""
scratch=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) arch="$2"; shift 2 ;;
        --scratch-path) scratch="$2"; shift 2 ;;
        *) shift ;;
    esac
done
mkdir -p "$scratch/release"
for product in NovaComputerUseService NovaComputerUseMCP; do
    if [[ "$NOVA_FIXTURE_MISSING_ARCH" != "$arch:$product" ]]; then
        printf '%s\n' "$arch $product" > "$scratch/release/$product"
        chmod +x "$scratch/release/$product"
    fi
done
SHIM

    cat > "$fixture_root/bin/lipo" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$NOVA_FIXTURE_LOG"
case "$1" in
    -create)
        x86="$2"
        arm="$3"
        [[ "$4" == "-output" ]]
        cp "$x86" "$5"
        printf '\nx86_64 arm64\n' >> "$5"
        ;;
    -archs)
        printf 'x86_64 arm64\n'
        ;;
    *) exit 64 ;;
esac
SHIM

    for tool in codesign xattr; do
        cat > "$fixture_root/bin/$tool" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\\n' "$tool" "\$*" >> "\$NOVA_FIXTURE_LOG"
if [[ "$tool" == "codesign" && "\${*: -1}" == *'/dist/.NovaComputerUsePlugin.'* ]]; then
    printf 'fixture rejects signing in FileProvider-backed dist staging\n' >&2
    exit 1
fi
SHIM
    done
    chmod +x "$fixture_root/bin/"*
}

run_build() {
    local missing_architecture="${1:-}"
    : > "$fixture_root/log"
    NOVA_FIXTURE_LOG="$fixture_root/log" \
    NOVA_FIXTURE_MISSING_ARCH="$missing_architecture" \
    PATH="$fixture_root/bin:$PATH" \
    "$repository_root/scripts/build-universal.sh"
}

make_shims
run_build

assert_contains 'build -c release --arch x86_64 --product NovaComputerUseService --scratch-path' "$fixture_root/log"
assert_contains 'build -c release --arch x86_64 --product NovaComputerUseMCP --scratch-path' "$fixture_root/log"
assert_contains 'build -c release --arch arm64 --product NovaComputerUseService --scratch-path' "$fixture_root/log"
assert_contains 'build -c release --arch arm64 --product NovaComputerUseMCP --scratch-path' "$fixture_root/log"
grep -Fq -- '-create ' "$fixture_root/log"
grep -Fq -- 'CFBundleIdentifier' "$repository_root/dist/NovaComputerUsePlugin/bin/NovaComputerUseService.app/Contents/Info.plist"
grep -Fq -- 'dev.theodorebeaupre.NovaComputerUse.Service' "$repository_root/dist/NovaComputerUsePlugin/bin/NovaComputerUseService.app/Contents/Info.plist"
cmp "$repository_root/LICENSE" "$repository_root/dist/NovaComputerUsePlugin/LICENSE"
cmp "$repository_root/THIRD_PARTY_NOTICES.md" "$repository_root/dist/NovaComputerUsePlugin/THIRD_PARTY_NOTICES.md"
grep -Fq -- 'codesign --force --sign -' "$fixture_root/log"
grep -Eq '^xattr -cr .*/NovaComputerUseService\.app/Contents/MacOS/NovaComputerUseService$' "$fixture_root/log"
grep -Eq '^xattr -cr .*/NovaComputerUseService\.app$' "$fixture_root/log"
assert_contains "xattr -cr $repository_root/dist/NovaComputerUsePlugin" "$fixture_root/log"

if run_build 'arm64:NovaComputerUseMCP'; then
    printf 'Expected build to reject a missing arm64 product\n' >&2
    exit 1
fi

installation_home="$fixture_root/codex"
mkdir -p "$installation_home"
printf '[plugins."unrelated@fixture"]\nenabled = true\n' > "$installation_home/config.toml"
cp "$installation_home/config.toml" "$fixture_root/original-config.toml"
PATH="$fixture_root/bin:$PATH" NOVA_FIXTURE_LOG="$fixture_root/log" CODEX_HOME="$installation_home" "$repository_root/scripts/install-local.sh" >/dev/null
PATH="$fixture_root/bin:$PATH" NOVA_FIXTURE_LOG="$fixture_root/log" CODEX_HOME="$installation_home" "$repository_root/scripts/install-local.sh" >/dev/null
grep -Fqx -- '[plugins."computer-use@nova"]' "$installation_home/config.toml"
grep -Fqx -- '[plugins."unrelated@fixture"]' "$installation_home/config.toml"
test -f "$installation_home/config.toml.nova-computer-use.backup"
cmp "$fixture_root/original-config.toml" "$installation_home/config.toml.nova-computer-use.backup"
grep -Fq -- "xattr -cr $installation_home/plugins/cache/nova/computer-use/.1.0.0.staging." "$fixture_root/log"
grep -Fq -- "codesign --verify --deep --strict $installation_home/plugins/cache/nova/computer-use/.1.0.0.staging." "$fixture_root/log"
grep -Fq -- "-archs $installation_home/plugins/cache/nova/computer-use/.1.0.0.staging." "$fixture_root/log"
printf 'existing installation\n' > "$installation_home/plugins/cache/nova/computer-use/1.0.0/existing-install"
cat > "$fixture_root/bin/mv" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == */.config.toml.nova-computer-use.* ]]; then
    exit 1
fi
exec /bin/mv "$@"
SHIM
chmod +x "$fixture_root/bin/mv"
if PATH="$fixture_root/bin:$PATH" NOVA_FIXTURE_LOG="$fixture_root/log" CODEX_HOME="$installation_home" "$repository_root/scripts/install-local.sh" >/dev/null; then
    printf 'Expected failed config publication to roll back the existing plugin\n' >&2
    exit 1
fi
test -f "$installation_home/plugins/cache/nova/computer-use/1.0.0/existing-install"
CODEX_HOME="$installation_home" "$repository_root/scripts/uninstall-local.sh" >/dev/null
grep -Fqx -- '[plugins."unrelated@fixture"]' "$installation_home/config.toml"
if grep -Fq -- 'computer-use@nova' "$installation_home/config.toml"; then
    printf 'Expected uninstall to remove only the Nova-managed plugin registration\n' >&2
    exit 1
fi
test -f "$installation_home/config.toml.nova-computer-use.backup"

printf 'UniversalBuildTests: PASS\n'

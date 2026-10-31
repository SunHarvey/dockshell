#!/bin/sh
# M10.0 has no GUI, installed-app replacement, personal connection or user-log access.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${1:-debug}
case "$configuration" in debug|release) ;; *) printf '%s\n' 'Usage: sh Scripts/test-terminal-logging.sh [debug|release]' >&2; exit 2 ;; esac
export CLANG_MODULE_CACHE_PATH="$root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/swift-module-cache"
probe_build() {
    if [ "${DOCKSHELL_DISABLE_SPM_SANDBOX:-0}" = 1 ]; then set -- --disable-sandbox "$@"; fi
    xcrun swift build --build-system native --package-path "$root/M10/TerminalLogging" \
        --scratch-path "$root/.build/m10-logging" --cache-path "$root/.build/cache" \
        --config-path "$root/.build/configuration" --security-path "$root/.build/security" \
        --disable-keychain --disable-netrc -c "$configuration" "$@"
}
probe_build --product dockshell-log-probe
bin=$(probe_build --show-bin-path)
log=$(mktemp "${TMPDIR:-/tmp}/dockshell-log-probe-output.XXXXXX")
trap 'rm -f "$log"' EXIT HUP INT TERM
if ! "$bin/dockshell-log-probe" > "$log"; then cat "$log" >&2; exit 1; fi
cat "$log"
/usr/bin/grep -Fqx 'PASS M10.0 terminal logging probe completed' "$log"

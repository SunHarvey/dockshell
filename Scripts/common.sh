#!/bin/sh
# Shared paths are derived from this checkout, including paths containing spaces.
# Callers set DOCKSHELL_ROOT before sourcing this file.
set -eu

export CLANG_MODULE_CACHE_PATH="$DOCKSHELL_ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$DOCKSHELL_ROOT/.build/swift-module-cache"

swift_build() {
    if [ "${DOCKSHELL_DISABLE_SPM_SANDBOX:-0}" = "1" ]; then
        set -- --disable-sandbox "$@"
    fi
    xcrun swift build \
        --build-system native \
        --package-path "$DOCKSHELL_ROOT" \
        --scratch-path "$DOCKSHELL_ROOT/.build/app" \
        --cache-path "$DOCKSHELL_ROOT/.build/cache" \
        --config-path "$DOCKSHELL_ROOT/.build/configuration" \
        --security-path "$DOCKSHELL_ROOT/.build/security" \
        --disable-keychain --disable-netrc "$@"
}

check_configuration() {
    case "$1" in
        debug|release) ;;
        *) printf '%s\n' 'Configuration must be debug or release.' >&2; exit 2 ;;
    esac
}

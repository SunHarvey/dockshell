#!/bin/sh
set -eu
DOCKSHELL_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DOCKSHELL_ROOT
. "$DOCKSHELL_ROOT/Scripts/common.sh"
configuration=${1:-debug}
check_configuration "$configuration"
application_output="${DOCKSHELL_APP_OUTPUT_ROOT:-$DOCKSHELL_ROOT/Build}/$configuration/DockShell.app"
verification_logs=$(mktemp -d "${TMPDIR:-/tmp}/dockshell-verification.XXXXXX")
verification_number=0
holding=
relocated=
cleanup() {
    if [ -n "$holding" ] && [ -d "$holding/app" ]; then
        mv "$holding/app" "$DOCKSHELL_ROOT/.build/app"
    fi
    if [ -n "$holding" ]; then rm -rf "$holding"; fi
    if [ -n "$relocated" ]; then rm -rf "$relocated"; fi
    rm -rf "$verification_logs"
}
trap cleanup EXIT HUP INT TERM

# A native event-tracking fixture can end its process before async main returns.
# Require the final success marker as well as exit 0, including for a relocated verifier.
run_verification() {
    verification_number=$((verification_number + 1))
    verification_log="$verification_logs/$verification_number.log"
    if ! "$@" >"$verification_log"; then
        cat "$verification_log" >&2
        return 1
    fi
    cat "$verification_log"
    if ! /usr/bin/grep -Fqx 'PASS verification completed' "$verification_log"; then
        printf '%s\n' 'Verification stopped before its final completion marker.' >&2
        return 1
    fi
}

sh "$DOCKSHELL_ROOT/Scripts/build.sh" "$configuration"
bin_path=$(swift_build -c "$configuration" --show-bin-path)
"$bin_path/catalog-compiler" --self-test
run_verification "$bin_path/dockshell-verify" "$application_output"
if [ "${DOCKSHELL_UI_SMOKE:-0}" = "1" ]; then
    run_verification "$bin_path/dockshell-verify" "$application_output" --ui-smoke
fi

# Hide the original resources while checking a copy outside the checkout.
# The app and verifier must resolve translations without .build or source-tree fallbacks.
relocated=$(mktemp -d "${TMPDIR:-/tmp}/dockshell-m1-relocation.XXXXXX")
holding=$(mktemp -d "$DOCKSHELL_ROOT/.build/.relocation.XXXXXX")
cp -R "$application_output" "$relocated/"
cp "$bin_path/dockshell-verify" "$relocated/verify"
/usr/bin/codesign --verify --strict "$relocated/DockShell.app"
mv "$DOCKSHELL_ROOT/.build/app" "$holding/app"
(
    cd "$relocated"
    run_verification ./verify "$relocated/DockShell.app"
)
printf '%s\n' 'PASS relocated app: explicit bundle resources and local signature'

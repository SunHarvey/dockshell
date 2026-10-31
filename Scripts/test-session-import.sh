#!/bin/sh
# Disposable fixtures only; no personal config, network or Keychain access.
set -eu
DOCKSHELL_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DOCKSHELL_ROOT
DOCKSHELL_APP_OUTPUT_ROOT=${DOCKSHELL_APP_OUTPUT_ROOT:-$DOCKSHELL_ROOT/Build/M12.noindex}
export DOCKSHELL_APP_OUTPUT_ROOT
. "$DOCKSHELL_ROOT/Scripts/common.sh"
configuration=${1:-debug}
check_configuration "$configuration"
sh "$DOCKSHELL_ROOT/Scripts/build.sh" "$configuration"
bin_path=$(swift_build -c "$configuration" --show-bin-path)
app="$DOCKSHELL_APP_OUTPUT_ROOT/$configuration/DockShell.app"
log=$(mktemp "${TMPDIR:-/tmp}/dockshell-session-import.XXXXXX")
trap 'rm -f "$log"' EXIT HUP INT TERM
if ! DOCKSHELL_SESSION_IMPORT_TEST=1 "$bin_path/dockshell-verify" "$app" --ui-smoke > "$log"; then
    cat "$log" >&2
    exit 1
fi
cat "$log"
/usr/bin/grep -Fqx 'PASS M12.1 session import completed' "$log"
/usr/bin/grep -Fqx 'PASS verification completed' "$log"

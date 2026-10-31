#!/bin/sh
# Batch commands run only against synthetic connections and disposable local PTYs.
set -eu
DOCKSHELL_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DOCKSHELL_ROOT
DOCKSHELL_APP_OUTPUT_ROOT=${DOCKSHELL_APP_OUTPUT_ROOT:-$DOCKSHELL_ROOT/Build/M11.noindex}
export DOCKSHELL_APP_OUTPUT_ROOT
. "$DOCKSHELL_ROOT/Scripts/common.sh"
configuration=${1:-debug}
check_configuration "$configuration"
sh "$DOCKSHELL_ROOT/Scripts/build.sh" "$configuration"
bin_path=$(swift_build -c "$configuration" --show-bin-path)
app="$DOCKSHELL_APP_OUTPUT_ROOT/$configuration/DockShell.app"
log=$(mktemp "${TMPDIR:-/tmp}/dockshell-batch-commands.XXXXXX")
trap 'rm -f "$log"' EXIT HUP INT TERM
if ! DOCKSHELL_BATCH_COMMAND_TEST=1 "$bin_path/dockshell-verify" "$app" --ui-smoke > "$log"; then
    cat "$log" >&2
    exit 1
fi
cat "$log"
/usr/bin/grep -Fqx 'PASS M11 batch commands completed' "$log"
/usr/bin/grep -Fqx 'PASS verification completed' "$log"

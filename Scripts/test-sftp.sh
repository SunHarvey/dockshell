#!/bin/sh
# M9.0: private loopback daemon, generated keys, protocol and process verification.
# No personal authorized_keys, agent, password, or system Remote Login changes.
set -eu
DOCKSHELL_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DOCKSHELL_ROOT
. "$DOCKSHELL_ROOT/Scripts/common.sh"
configuration=${1:-debug}
check_configuration "$configuration"
sh "$DOCKSHELL_ROOT/Scripts/build.sh" "$configuration"
bin_path=$(swift_build -c "$configuration" --show-bin-path)
app="${DOCKSHELL_APP_OUTPUT_ROOT:-$DOCKSHELL_ROOT/Build}/$configuration/DockShell.app"
log=$(mktemp "${TMPDIR:-/tmp}/dockshell-sftp-verification.XXXXXX")
trap 'rm -f "$log"' EXIT HUP INT TERM
if ! DOCKSHELL_SFTP_TEST=1 "$bin_path/dockshell-verify" "$app" > "$log"; then
    cat "$log" >&2
    exit 1
fi
cat "$log"
/usr/bin/grep -Fqx 'PASS verification completed' "$log"

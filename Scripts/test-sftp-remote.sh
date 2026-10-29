#!/bin/sh
# Explicit authorized-host acceptance. Manual input uses foreground standard
# input without echo; explicit automation accepts only an anonymous stdin FIFO.
# Only non-secret endpoint metadata belongs in the environment.
set -eu
DOCKSHELL_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DOCKSHELL_ROOT
. "$DOCKSHELL_ROOT/Scripts/common.sh"
configuration=${1:-debug}
check_configuration "$configuration"
if [ "${DOCKSHELL_SFTP_REMOTE_TEST:-0}" != 1 ] ||
   [ -z "${DOCKSHELL_SFTP_REMOTE_HOST:-}" ] ||
   [ -z "${DOCKSHELL_SFTP_REMOTE_USER:-}" ] ||
   [ -z "${DOCKSHELL_SFTP_REMOTE_AUTH:-}" ] ||
   [ -z "${DOCKSHELL_SFTP_REMOTE_FINGERPRINT:-}" ]; then
    printf '%s\n' 'Explicit opt-in, an authorized endpoint, authentication kind and independently verified host fingerprint are required.' >&2
    exit 2
fi
sh "$DOCKSHELL_ROOT/Scripts/build.sh" "$configuration"
bin_path=$(swift_build -c "$configuration" --show-bin-path)
app="${DOCKSHELL_APP_OUTPUT_ROOT:-$DOCKSHELL_ROOT/Build}/$configuration/DockShell.app"
exec "$bin_path/dockshell-verify" "$app"

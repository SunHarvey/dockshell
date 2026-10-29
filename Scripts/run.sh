#!/bin/sh
set -eu
DOCKSHELL_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
language=${1:-system}
case "$language" in
    system|en|zh-Hans) ;;
    *) printf '%s\n' 'Usage: sh Scripts/run.sh [system|en|zh-Hans]' >&2; exit 2 ;;
esac
if /usr/bin/pgrep -x DockShell >/dev/null 2>&1; then
    printf '%s\n' 'DockShell is already running. Quit it with Cmd+Q, then run this script again to load the new build and language.' >&2
    exit 1
fi
sh "$DOCKSHELL_ROOT/Scripts/build.sh" debug
app="$DOCKSHELL_ROOT/Build/debug/DockShell.app"
if [ "$language" = "system" ]; then
    /usr/bin/open "$app"
else
    # Per-process language override. Does not change the user's system preferences.
    /usr/bin/open "$app" --args -AppleLanguages "($language)"
fi

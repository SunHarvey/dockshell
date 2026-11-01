#!/bin/sh
# Public installer names are independent of internal build numbers and signing modes.
set -eu
[ "$#" -eq 2 ] || { printf '%s\n' 'Usage: sh Scripts/dmg-name.sh VERSION arm64|x86_64|universal' >&2; exit 2; }
case "$1" in ''|*[!0-9.]*) printf '%s\n' 'Invalid installer version.' >&2; exit 2 ;; esac
printf '%s\n' "$1" | LC_ALL=C /usr/bin/grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    || { printf '%s\n' 'Invalid installer version.' >&2; exit 2; }
case "$2" in arm64|x86_64|universal) ;; *) printf '%s\n' 'Invalid installer architecture.' >&2; exit 2 ;; esac
printf 'DockShell-%s-%s.dmg\n' "$1" "$2"

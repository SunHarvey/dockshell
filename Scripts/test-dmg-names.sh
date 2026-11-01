#!/bin/sh
# Naming is a release contract: malformed metadata must never become a path or output injection.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for architecture in arm64 x86_64 universal; do
    actual=$(sh "$root/Scripts/dmg-name.sh" 0.4.0 "$architecture")
    [ "$actual" = "DockShell-0.4.0-$architecture.dmg" ]
done
for version in '' 0.4 00.4.0 0.4.0-preview.1 '0.4.0/../../outside' '0.4.0;touch PWNED' "$(printf '0.4.0\nname=injected')"; do
    if sh "$root/Scripts/dmg-name.sh" "$version" arm64 >/dev/null 2>&1; then
        printf '%s\n' 'Invalid version was accepted.' >&2; exit 1
    fi
done
for architecture in '' amd64 '../arm64'; do
    if sh "$root/Scripts/dmg-name.sh" 0.4.0 "$architecture" >/dev/null 2>&1; then
        printf '%s\n' 'Invalid architecture was accepted.' >&2; exit 1
    fi
done
printf '%s\n' 'PASS installer names: version/architecture only, arm64/x86_64/universal, invalid metadata rejected'

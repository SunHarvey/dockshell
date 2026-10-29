#!/bin/sh
# Installs the approved artwork into explicit app resources before the bundle is signed.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail() { printf 'Branding installation failed: %s\n' "$1" >&2; exit 1; }
[ "$#" -eq 1 ] || { printf '%s\n' 'Usage: sh Scripts/install-branding.sh APP' >&2; exit 2; }
app=$1
[ -d "$app" ] && [ ! -L "$app" ] || fail 'Expected a real application bundle.'
app=$(CDPATH= cd -- "$app" && pwd)
resources="$app/Contents/Resources"
bundle="$resources/DockShellResources.bundle"
[ -d "$resources" ] && [ ! -L "$resources" ] || fail 'Application resources directory is missing.'
[ -d "$bundle" ] && [ ! -L "$bundle" ] && [ -f "$bundle/Info.plist" ] || fail 'Generate the explicit resource bundle before installing artwork.'
source="$root/Packaging/Branding"
for file in DockShell.icns DockShellMark.png; do
    [ -f "$source/$file" ] && [ ! -L "$source/$file" ] && [ -s "$source/$file" ] || fail 'Approved branding resources are missing or invalid.'
done
[ ! -L "$bundle/Branding" ] || fail 'Branding resource directory must not be a symlink.'
mkdir -p "$bundle/Branding"
install -m 644 "$source/DockShell.icns" "$resources/DockShell.icns"
install -m 644 "$source/DockShellMark.png" "$bundle/Branding/DockShellMark.png"

#!/bin/sh
# Re-exports the approved master at standard icon sizes; no redesign or dependency download.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source="$root/Packaging/Branding/Source/DockShell-49.png"
destination="$root/Packaging/Branding"
if [ ! -f "$source" ] || [ -L "$source" ]; then
    printf '%s\n' 'Approved icon master is missing.' >&2
    exit 1
fi
temporary=$(mktemp -d "${TMPDIR:-/tmp}/dockshell-icon-export.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$root/.build/icon-module-cache"
# ImageIO is available with CLT. Some CLT iconutil versions reject valid iconsets.
xcrun swift -swift-version 6 -module-cache-path "$root/.build/icon-module-cache" \
    "$root/Tools/IconExporter/IconExporter.swift" "$source" \
    "$temporary/DockShell.icns" "$temporary/DockShellMark.png"
# 256 pixels cover the largest 72-point in-app mark at Retina resolution.
install -m 644 "$temporary/DockShellMark.png" "$destination/DockShellMark.png"
install -m 644 "$temporary/DockShell.icns" "$destination/DockShell.icns"
printf '%s\n' 'Exported approved concept 49: DockShell.icns (16–1024 px), DockShellMark.png (256 px).'

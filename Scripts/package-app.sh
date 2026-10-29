#!/bin/sh
set -eu
DOCKSHELL_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DOCKSHELL_ROOT
. "$DOCKSHELL_ROOT/Scripts/common.sh"
configuration=${1:-debug}
check_configuration "$configuration"

bin_path=$(swift_build -c "$configuration" --show-bin-path)
resources="$DOCKSHELL_ROOT/Build/Generated/DockShellResources.bundle"
if [ ! -x "$bin_path/DockShell" ] || [ ! -f "$resources/Info.plist" ]; then
    printf '%s\n' 'Run sh Scripts/build.sh first.' >&2
    exit 1
fi

# Verification may package a separate copy while the user's development app is open.
destination="${DOCKSHELL_APP_OUTPUT_ROOT:-$DOCKSHELL_ROOT/Build}/$configuration"
mkdir -p "$destination"
staging=$(mktemp -d "$destination/.package.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
app="$staging/DockShell.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
install -m 755 "$bin_path/DockShell" "$app/Contents/MacOS/DockShell"
install -m 755 "$bin_path/dockshell-ssh-helper" "$app/Contents/Helpers/dockshell-ssh-helper"
cp "$DOCKSHELL_ROOT/Packaging/Info.plist" "$app/Contents/Info.plist"
cp -R "$resources" "$app/Contents/Resources/"
sh "$DOCKSHELL_ROOT/Scripts/install-branding.sh" "$app"
cp "$DOCKSHELL_ROOT/Packaging/ThirdPartyNotices.txt" "$app/Contents/Resources/ThirdPartyNotices.txt"
if [ ! -f "$bin_path/SwiftTerm_SwiftTerm.bundle/Shaders.metal" ]; then
    printf '%s\n' 'SwiftTerm resources are missing. Run the full build before packaging.' >&2
    exit 1
fi
cp -R "$bin_path/SwiftTerm_SwiftTerm.bundle" "$app/Contents/Resources/"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
# Ad-hoc signing is for local development only. It uses no identity or account.
/usr/bin/codesign --force --sign - "$app/Contents/Helpers/dockshell-ssh-helper"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
rm -rf "$destination/DockShell.app"
mv "$app" "$destination/DockShell.app"
printf 'Application: %s\n' "$destination/DockShell.app"

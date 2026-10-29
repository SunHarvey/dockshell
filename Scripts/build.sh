#!/bin/sh
set -eu
DOCKSHELL_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DOCKSHELL_ROOT
. "$DOCKSHELL_ROOT/Scripts/common.sh"
configuration=${1:-debug}
check_configuration "$configuration"

sh "$DOCKSHELL_ROOT/Scripts/check-environment.sh"
swift_build -c "$configuration"
bin_path=$(swift_build -c "$configuration" --show-bin-path)
mkdir -p "$DOCKSHELL_ROOT/Build/Generated"
"$bin_path/catalog-compiler" \
    "$DOCKSHELL_ROOT/Localization/Localizable.xcstrings" \
    "$DOCKSHELL_ROOT/Build/Generated/DockShellResources.bundle"
sh "$DOCKSHELL_ROOT/Scripts/package-app.sh" "$configuration"

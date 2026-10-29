#!/bin/sh
# Creates and reopens a read-only installer image without launching Finder or the app.
# The application is copied intact; this script neither signs nor notarizes any code.
set -eu
export LC_ALL=C

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
usage() {
    printf '%s\n' 'Usage: sh Scripts/package-dmg.sh APP OUTPUT.dmg --mode local-preview|developer-id --architectures arm64|x86_64|universal' >&2
    exit 2
}
fail() { printf 'DMG packaging failed: %s\n' "$1" >&2; exit 1; }
single_line() {
    case "$1" in
        *'
'*|*"$(printf '\r')"*) fail 'Application and output paths must not contain line breaks.' ;;
    esac
}

[ "$#" -ge 6 ] || usage
app=$1; output=$2; shift 2
mode=; architectures=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode) [ -z "$mode" ] && [ "$#" -ge 2 ] || usage; mode=$2; shift 2 ;;
        --architectures) [ -z "$architectures" ] && [ "$#" -ge 2 ] || usage; architectures=$2; shift 2 ;;
        *) usage ;;
    esac
done
case "$mode" in local-preview|developer-id) ;; *) usage ;; esac
case "$architectures" in arm64|x86_64|universal) ;; *) usage ;; esac
single_line "$app"; single_line "$output"
[ "$(uname -s)" = Darwin ] || fail 'DMG packaging requires macOS.'
[ -d "$app" ] && [ ! -L "$app" ] || fail 'Expected a real application directory, not a symlink.'
app=$(CDPATH= cd -- "$app" && pwd -P)
case "$output" in *.dmg) ;; *) fail 'The output filename must end in .dmg.' ;; esac
[ ! -e "$output" ] && [ ! -L "$output" ] || fail 'The output image must not already exist.'
output_parent=$(CDPATH= cd -- "$(dirname -- "$output")" && pwd -P) || fail 'The output directory must exist.'
output="$output_parent/$(basename -- "$output")"
case "$output" in "$app"/*) fail 'The output image must be outside the source application.' ;; esac

sh "$root/Scripts/audit-release.sh" "$app" --mode "$mode" --architectures "$architectures"

# Keep the partial image on the destination filesystem so the final hard-link handoff
# can refuse an existing target atomically, without overwriting a file or symlink.
temporary=$(mktemp -d "$output_parent/.dockshell-dmg.XXXXXX")
payload="$temporary/payload"
staging_mount="$temporary/staging-volume"
verified_mount="$temporary/verified-volume"
scratch="$temporary/scratch.dmg"
partial="$temporary/installer.dmg"
attach_report="$temporary/attach.plist"
layout_tool="$temporary/DMGLayout"
device=
mounted=0
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$mounted" -eq 1 ]; then
        if ! /usr/bin/hdiutil detach "$device" -quiet; then
            printf 'DMG packaging cleanup could not detach its own image: %s\nTemporary files preserved at: %s\n' "$device" "$temporary" >&2
            exit 1
        fi
    fi
    rm -rf "$temporary"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir "$payload" "$staging_mount" "$verified_mount"
mkdir -p "$root/.build/dmg-layout-module-cache"
xcrun --sdk macosx swiftc -swift-version 6 -O -parse-as-library \
    -module-cache-path "$root/.build/dmg-layout-module-cache" \
    -import-objc-header "$root/Tools/DMGLayout/NativeAlias.h" \
    "$root/Tools/DMGLayout/DMGLayoutTool.swift" \
    "$root/Tools/DMGLayout/FinderLayout.swift" \
    "$root/Tools/DMGLayout/InstallerArtwork.swift" \
    -framework AppKit -framework CoreServices -o "$layout_tool"
/usr/bin/ditto "$app" "$payload/DockShell.app"
# This standard install shortcut is outside the signed application bundle.
ln -s /Applications "$payload/Applications"
"$layout_tool" artwork "$payload" "$root/Packaging/Branding/DockShellMark.png" \
    "$root/Packaging/Installer/Localizable.xcstrings"

# Finder's picture reference must be created on the image's actual filesystem.
# A scratch image preserves its volume/file IDs when converted to read-only UDZO.
payload_kib=$(/usr/bin/du -sk "$payload" | /usr/bin/awk '{print $1}')
case "$payload_kib" in ''|*[!0-9]*) fail 'Could not determine the installer payload size.' ;; esac
image_kib=$((payload_kib + 16384))
/usr/bin/hdiutil create -srcfolder "$payload" -volname DockShell -fs HFS+ \
    -size "${image_kib}k" -format UDRW -nospotlight "$scratch"

attach_own_image() {
    image=$1; mountpoint=$2; access=$3
    device=; mounted=0; attach_status=0
    /usr/bin/hdiutil attach "$image" "$access" -nobrowse -noautoopen \
        -mountpoint "$mountpoint" -plist > "$attach_report" || attach_status=$?
    # Parse only this operation's own report, including partially successful mounts.
    if /usr/bin/plutil -lint "$attach_report" >/dev/null 2>&1; then
        device=$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$attach_report" 2>/dev/null) || device=
        case "$device" in /dev/disk[0-9]*) mounted=1 ;; *) device= ;; esac
    fi
    [ "$attach_status" -eq 0 ] && [ "$mounted" -eq 1 ] || fail 'The installer image could not be mounted.'
}
detach_own_image() {
    /usr/bin/hdiutil detach "$device" -quiet || fail 'The installer image could not be detached.'
    mounted=0; device=
}

attach_own_image "$scratch" "$staging_mount" -readwrite
"$layout_tool" write "$staging_mount"
detach_own_image
/usr/bin/hdiutil convert "$scratch" -format UDZO -o "$partial"
/usr/bin/hdiutil verify "$partial"

# Reopen at a different path with the scratch image detached. This catches an
# artwork alias that accidentally points at the build folder or old mountpoint.
attach_own_image "$partial" "$verified_mount" -readonly
[ -d "$verified_mount/DockShell.app" ] && [ ! -L "$verified_mount/DockShell.app" ] \
    || fail 'The mounted image does not contain the application.'
[ -L "$verified_mount/Applications" ] && [ "$(readlink "$verified_mount/Applications")" = /Applications ] \
    || fail 'The mounted image has no valid Applications shortcut.'
"$layout_tool" verify "$verified_mount"
cmp "$payload/.background/installer.tiff" "$verified_mount/.background/installer.tiff"
sh "$root/Scripts/audit-release.sh" "$verified_mount/DockShell.app" --mode "$mode" --architectures "$architectures"
cmp "$app/Contents/MacOS/DockShell" "$verified_mount/DockShell.app/Contents/MacOS/DockShell"
cmp "$app/Contents/Helpers/dockshell-ssh-helper" "$verified_mount/DockShell.app/Contents/Helpers/dockshell-ssh-helper"
detach_own_image

[ ! -e "$output" ] && [ ! -L "$output" ] || fail 'The output path appeared during packaging; no existing file was overwritten.'
/bin/ln -h "$partial" "$output" || fail 'The completed image could not be placed at the output path.'
[ -f "$output" ] && [ ! -L "$output" ] && [ "$partial" -ef "$output" ] \
    || fail 'The output path is not the completed installer image.'
printf 'Prepared DMG: %s\n' "$output"
printf '%s\n' 'PASS DMG: compact branded Finder layout, portable Retina background, intact signed application, Applications shortcut'

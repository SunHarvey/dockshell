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
mountpoint="$temporary/mounted"
partial="$temporary/installer.dmg"
attach_report="$temporary/attach.plist"
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

mkdir "$payload" "$mountpoint"
/usr/bin/ditto "$app" "$payload/DockShell.app"
# This standard install shortcut is outside the signed application bundle.
ln -s /Applications "$payload/Applications"
/usr/bin/hdiutil create -srcfolder "$payload" -volname DockShell -fs HFS+ \
    -format UDZO -nospotlight "$partial"
/usr/bin/hdiutil verify "$partial"

attach_status=0
/usr/bin/hdiutil attach "$partial" -readonly -nobrowse -noautoopen \
    -mountpoint "$mountpoint" -plist > "$attach_report" || attach_status=$?
# Device identifiers are taken only from this attach operation's own report. A
# partially successful attach can then be cleaned up without touching other disks.
if /usr/bin/plutil -lint "$attach_report" >/dev/null 2>&1; then
    device=$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$attach_report" 2>/dev/null) || device=
    case "$device" in
        /dev/disk[0-9]*) mounted=1 ;;
        *) device= ;;
    esac
fi
[ "$attach_status" -eq 0 ] && [ "$mounted" -eq 1 ] || fail 'The installer image could not be mounted for verification.'
[ -d "$mountpoint/DockShell.app" ] && [ ! -L "$mountpoint/DockShell.app" ] \
    || fail 'The mounted image does not contain the application.'
[ -L "$mountpoint/Applications" ] && [ "$(readlink "$mountpoint/Applications")" = /Applications ] \
    || fail 'The mounted image has no valid Applications shortcut.'
sh "$root/Scripts/audit-release.sh" "$mountpoint/DockShell.app" --mode "$mode" --architectures "$architectures"
cmp "$app/Contents/MacOS/DockShell" "$mountpoint/DockShell.app/Contents/MacOS/DockShell"
cmp "$app/Contents/Helpers/dockshell-ssh-helper" "$mountpoint/DockShell.app/Contents/Helpers/dockshell-ssh-helper"
/usr/bin/hdiutil detach "$device" -quiet || fail 'The verified installer image could not be detached.'
mounted=0

[ ! -e "$output" ] && [ ! -L "$output" ] || fail 'The output path appeared during packaging; no existing file was overwritten.'
/bin/ln -h "$partial" "$output" || fail 'The completed image could not be placed at the output path.'
[ -f "$output" ] && [ ! -L "$output" ] && [ "$partial" -ef "$output" ] \
    || fail 'The output path is not the completed installer image.'
printf 'Prepared DMG: %s\n' "$output"
printf '%s\n' 'PASS DMG: verified read-only image, intact signed application, Applications install shortcut'

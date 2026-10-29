#!/bin/sh
# Guard tests do not build, sign, mount images or use personal data. Supplying an
# existing preview app additionally exercises real image creation, a normal
# /Volumes read-only remount, and verification of artwork and root metadata.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
[ "$#" -le 1 ] || { printf '%s\n' 'Usage: sh Scripts/test-dmg-packaging.sh [LOCAL_PREVIEW_APP]' >&2; exit 2; }
temporary=$(mktemp -d "${TMPDIR:-/tmp}/dockshell-dmg-tests.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir -p "$temporary/input with spaces/DockShell.app" "$temporary/output with spaces"
dummy="$temporary/input with spaces/DockShell.app"
output="$temporary/output with spaces/DockShell.dmg"
expect_failure() {
    label=$1; expected=$2; shift 2
    if "$@" > "$temporary/output.log" 2>&1; then
        printf 'FAIL DMG guard: %s unexpectedly succeeded\n' "$label" >&2; exit 1
    fi
    if ! /usr/bin/grep -Fq "$expected" "$temporary/output.log"; then
        printf 'FAIL DMG guard: %s failed for another reason\n' "$label" >&2
        cat "$temporary/output.log" >&2; exit 1
    fi
}
/bin/sh -n "$root/Scripts/package-dmg.sh"
expect_failure 'missing arguments' 'Usage:' sh "$root/Scripts/package-dmg.sh"
expect_failure 'invalid mode' 'Usage:' sh "$root/Scripts/package-dmg.sh" "$dummy" "$output" --mode unsigned --architectures arm64
expect_failure 'invalid architecture' 'Usage:' sh "$root/Scripts/package-dmg.sh" "$dummy" "$output" --mode local-preview --architectures wrong
expect_failure 'duplicate mode' 'Usage:' sh "$root/Scripts/package-dmg.sh" "$dummy" "$output" --mode local-preview --mode developer-id --architectures arm64
expect_failure 'missing source' 'Expected a real application' sh "$root/Scripts/package-dmg.sh" "$temporary/missing.app" "$output" --mode local-preview --architectures arm64
ln -s "$dummy" "$temporary/linked.app"
expect_failure 'source symlink' 'Expected a real application' sh "$root/Scripts/package-dmg.sh" "$temporary/linked.app" "$output" --mode local-preview --architectures arm64
expect_failure 'wrong extension' 'must end in .dmg' sh "$root/Scripts/package-dmg.sh" "$dummy" "$temporary/plain.zip" --mode local-preview --architectures arm64
expect_failure 'output inside application' 'outside the source application' sh "$root/Scripts/package-dmg.sh" "$dummy" "$dummy/installer.dmg" --mode local-preview --architectures arm64
printf '%s\n' 'existing image sentinel' > "$output"
expect_failure 'existing output' 'must not already exist' sh "$root/Scripts/package-dmg.sh" "$dummy" "$output" --mode local-preview --architectures arm64
[ "$(cat "$output")" = 'existing image sentinel' ] || { printf '%s\n' 'Existing image was modified.' >&2; exit 1; }
rm "$output"
ln -s "$temporary/missing-target" "$output"
expect_failure 'dangling output symlink' 'must not already exist' sh "$root/Scripts/package-dmg.sh" "$dummy" "$output" --mode local-preview --architectures arm64
rm "$output"
line_break_output=$(printf '%s\n%s' "$temporary/output" 'injected.dmg')
expect_failure 'line-break path' 'must not contain line breaks' sh "$root/Scripts/package-dmg.sh" "$dummy" "$line_break_output" --mode local-preview --architectures arm64
expect_failure 'invalid unsigned app' 'Release audit failed:' sh "$root/Scripts/package-dmg.sh" "$dummy" "$output" --mode local-preview --architectures arm64
[ ! -e "$output" ] && [ ! -L "$output" ]
printf '%s\n' 'PASS DMG guards: required mode/architecture, signed input, output protection, symlinks, install path and paths with spaces'

if [ "$#" -eq 1 ]; then
    source_app=$(CDPATH= cd -- "$1" && pwd -P)
    /usr/bin/ditto "$source_app" "$temporary/input with spaces/Preview.app"
    preview="$temporary/input with spaces/Preview.app"
    architecture_list=$(/usr/bin/lipo -archs "$preview/Contents/MacOS/DockShell")
    case "$architecture_list" in
        arm64|x86_64) architecture=$architecture_list ;;
        'arm64 x86_64'|'x86_64 arm64') architecture=universal ;;
        *) printf '%s\n' 'Unsupported test application architecture.' >&2; exit 1 ;;
    esac
    /usr/bin/shasum -a 256 "$preview/Contents/MacOS/DockShell" "$preview/Contents/Helpers/dockshell-ssh-helper" > "$temporary/source-sha256"
    sh "$root/Scripts/package-dmg.sh" "$preview" "$output" --mode local-preview --architectures "$architecture"
    [ -s "$output" ] && [ ! -L "$output" ]
    /usr/bin/shasum -a 256 -c "$temporary/source-sha256"
    /usr/bin/shasum -a 256 "$output" > "$temporary/dmg-sha256"
    expect_failure 'completed output remains immutable' 'must not already exist' sh "$root/Scripts/package-dmg.sh" "$preview" "$output" --mode local-preview --architectures "$architecture"
    /usr/bin/shasum -a 256 -c "$temporary/dmg-sha256"
    printf '%s\n' 'PASS DMG integration: real image create/verify/normal /Volumes read-only remount/layout and root metadata audit/detach; signed source unchanged; existing image unchanged'
fi

#!/bin/sh
# Offline artifact checks. Gatekeeper/notarization checks run only when explicitly requested.
set -eu
usage() {
    printf '%s\n' 'Usage: sh Scripts/audit-release.sh APP --mode local-preview|developer-id [--architectures arm64|x86_64|universal] [--require-notarized]' >&2
    exit 2
}
fail() { printf 'Release audit failed: %s\n' "$1" >&2; exit 1; }
[ "$#" -ge 3 ] || usage
app=$1; shift
mode=; requested_arch=; notarized=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode) [ "$#" -ge 2 ] || usage; mode=$2; shift 2 ;;
        --architectures) [ "$#" -ge 2 ] || usage; requested_arch=$2; shift 2 ;;
        --require-notarized) notarized=1; shift ;;
        *) usage ;;
    esac
done
case "$mode" in local-preview|developer-id) ;; *) usage ;; esac
case "$requested_arch" in ''|arm64|x86_64|universal) ;; *) usage ;; esac
[ "$notarized" -eq 0 ] || [ "$mode" = developer-id ] || fail 'A local preview cannot be notarized.'
[ -d "$app" ] && [ ! -L "$app" ] || fail 'Expected a real application bundle.'
app=$(CDPATH= cd -- "$app" && pwd)
[ -z "$(/usr/bin/find "$app" -type l -print -quit)" ] || fail 'This application layout requires no symlinks.'
info="$app/Contents/Info.plist"
main="$app/Contents/MacOS/DockShell"
helper="$app/Contents/Helpers/dockshell-ssh-helper"
resources="$app/Contents/Resources"
for file in "$info" "$main" "$helper" "$resources/ThirdPartyNotices.txt" \
    "$resources/DockShell.icns" \
    "$resources/DockShellResources.bundle/Branding/DockShellMark.png" \
    "$resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal" \
    "$resources/DockShellResources.bundle/en.lproj/Localizable.strings" \
    "$resources/DockShellResources.bundle/zh-Hans.lproj/Localizable.strings"; do
    [ -f "$file" ] && [ ! -L "$file" ] || fail 'A required packaged file is absent or is a symlink.'
done
/usr/bin/plutil -lint "$info" >/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" = dev.dockshell.app ] || fail 'Unexpected bundle identifier.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")" = DockShell ] || fail 'Unexpected executable.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info")" = DockShell.icns ] || fail 'Approved application icon is not declared.'
[ -s "$resources/DockShell.icns" ] && [ -s "$resources/DockShellResources.bundle/Branding/DockShellMark.png" ] || fail 'Packaged branding resources are empty.'
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info")" = 14.0 ] || fail 'Minimum system must be macOS 14.0.'
/usr/bin/grep -q 'SwiftTerm' "$resources/ThirdPartyNotices.txt" || fail 'SwiftTerm notice is missing.'
[ -x "$main" ] && [ -x "$helper" ] || fail 'App and SSH helper must be executable.'
temporary=$(mktemp -d "${TMPDIR:-/tmp}/dockshell-release-audit.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
developer_requirement='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
main_arch=$(/usr/bin/lipo -archs "$main")
helper_arch=$(/usr/bin/lipo -archs "$helper")
[ "$main_arch" = "$helper_arch" ] || fail 'App and SSH helper architectures differ.'
case "$requested_arch" in
    arm64|x86_64) [ "$main_arch" = "$requested_arch" ] || fail 'Unexpected architecture.' ;;
    universal)
        [ "$(printf '%s\n' "$main_arch" | tr ' ' '\n' | sort | tr '\n' ' ')" = 'arm64 x86_64 ' ] || fail 'Universal requires arm64 and x86_64 only.' ;;
esac
for binary in "$main" "$helper"; do
    if [ "$binary" = "$main" ]; then expected_identifier=dev.dockshell.app; else expected_identifier=dev.dockshell.ssh-helper; fi
    /usr/bin/codesign --verify --strict --all-architectures "$binary"
    for architecture in $main_arch; do
        /usr/bin/codesign --display --architecture "$architecture" --verbose=4 "$binary" >"$temporary/signature.txt" 2>&1
        /usr/bin/grep -Fqx "Identifier=$expected_identifier" "$temporary/signature.txt" || fail 'Unexpected app/helper signing identifier.'
        /usr/bin/grep -q 'flags=.*runtime' "$temporary/signature.txt" || fail 'Hardened Runtime is missing.'
        # Newer codesign defaults to an abstract display; older tools already return XML.
        if ! /usr/bin/codesign --display --architecture "$architecture" --entitlements - --xml "$binary" >"$temporary/entitlements.plist" 2>/dev/null; then
            /usr/bin/codesign --display --architecture "$architecture" --entitlements - "$binary" >"$temporary/entitlements.plist" 2>/dev/null
        fi
        if [ -s "$temporary/entitlements.plist" ]; then
            /usr/bin/plutil -convert xml1 "$temporary/entitlements.plist"
            if /usr/bin/grep -q '<key>' "$temporary/entitlements.plist"; then
                fail 'This build requires no entitlements; debug/JIT/library-validation/sandbox exceptions are forbidden.'
            fi
        fi
        if [ "$mode" = local-preview ]; then
            /usr/bin/grep -q '^Signature=adhoc$' "$temporary/signature.txt" || fail 'Preview must be explicitly ad-hoc signed.'
        else
            /usr/bin/codesign --verify --strict -R="$developer_requirement" "$binary"
            /usr/bin/grep -q '^Timestamp=' "$temporary/signature.txt" || fail 'A secure signing timestamp is required.'
            team=$(/usr/bin/sed -n 's/^TeamIdentifier=//p' "$temporary/signature.txt")
            [ -n "$team" ] && [ "$team" != not\ set ] || fail 'Developer ID team is missing.'
            if [ -f "$temporary/team.txt" ]; then
                [ "$team" = "$(cat "$temporary/team.txt")" ] || fail 'App and helper signing teams differ.'
            else printf '%s\n' "$team" >"$temporary/team.txt"; fi
        fi
        /usr/bin/vtool -arch "$architecture" -show-build "$binary" >"$temporary/build.txt"
        /usr/bin/awk '$1 == "platform" { if ($2 != "MACOS") exit 1; platform = 1 } $1 == "minos" { if ($2 != "14.0") exit 1; minimum = 1 } END { if (!platform || !minimum) exit 1 }' "$temporary/build.txt" || fail 'Mach-O platform/minimum does not match macOS 14.'
    done
    /usr/bin/otool -L "$binary" >"$temporary/dependencies.txt"
    /usr/bin/awk '/^[[:space:]]/ { path = $1; if (path !~ /^\/usr\/lib\// && path !~ /^\/System\/Library\// && path !~ /^@rpath\/libswift/) exit 1 }' "$temporary/dependencies.txt" || fail 'A non-system dynamic library dependency was found.'
done
/usr/bin/codesign --verify --deep --strict --all-architectures "$app"
if [ "$notarized" -eq 1 ]; then
    xcrun --find stapler >/dev/null
    xcrun stapler validate "$app"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$app"
fi
printf 'PASS release audit: %s; architectures=%s; macOS 14; nested signatures; Hardened Runtime; empty entitlements; bundled resources\n' "$mode" "$main_arch"
if [ "$mode" = local-preview ]; then
    printf '%s\n' 'LOCAL PREVIEW ONLY: not Developer ID signed, not notarized, not approved for public distribution.'
fi

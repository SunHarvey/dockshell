#!/bin/sh
# Uses isolated distribution scratch paths. Existing development/test build paths remain unchanged.
set -eu
DOCKSHELL_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DOCKSHELL_ROOT
usage() {
    printf '%s\n' 'Usage: sh Scripts/release.sh --local-preview|--identity "Developer ID Application: NAME (TEAM)" [--universal]' >&2
    exit 2
}
fail() { printf 'Release preparation failed: %s\n' "$1" >&2; exit 1; }
mode=; identity=; universal=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --local-preview) [ -z "$mode" ] || usage; mode=local-preview; shift ;;
        --identity) [ -z "$mode" ] && [ "$#" -ge 2 ] || usage; mode=developer-id; identity=$2; shift 2 ;;
        --universal) universal=1; shift ;;
        *) usage ;;
    esac
done
[ -n "$mode" ] || usage
host_arch=$(/usr/bin/uname -m)
case "$host_arch" in arm64|x86_64) ;; *) fail 'Unsupported build-host architecture.' ;; esac
architectures=$host_arch
architecture_label=$host_arch
if [ "$universal" -eq 1 ]; then architectures='arm64 x86_64'; architecture_label=universal; fi
if [ "$mode" = developer-id ]; then
    # Select exactly one valid identity by full public name or SHA-1; never read/export a private key.
    selected=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v requested="$identity" '
        { split($0, names, "\"") }
        names[2] ~ /^Developer ID Application: / && (names[2] == requested || toupper($2) == toupper(requested)) { print $2 }')
    [ "$(printf '%s\n' "$selected" | /usr/bin/awk 'NF { count++ } END { print count+0 }')" -eq 1 ] || fail 'Exactly one valid Developer ID Application identity is required. No signing fallback was used.'
    identity=$selected
else identity=-; fi
export CLANG_MODULE_CACHE_PATH="$DOCKSHELL_ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$DOCKSHELL_ROOT/.build/swift-module-cache"
distribution_build() {
    scratch=$1; shift
    if [ "${DOCKSHELL_DISABLE_SPM_SANDBOX:-0}" = 1 ]; then set -- --disable-sandbox "$@"; fi
    xcrun swift build --build-system native --package-path "$DOCKSHELL_ROOT" \
        --scratch-path "$scratch" --cache-path "$DOCKSHELL_ROOT/.build/cache" \
        --config-path "$DOCKSHELL_ROOT/.build/configuration" --security-path "$DOCKSHELL_ROOT/.build/security" \
        --disable-keychain --disable-netrc --force-resolved-versions --skip-update "$@"
}
info="$DOCKSHELL_ROOT/Packaging/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")
case "$version:$build" in *[!0-9.:]*) fail 'Version and build must contain only digits and dots.' ;; esac
[ -n "$version" ] && [ -n "$build" ] || fail 'Version metadata is empty.'
mkdir -p "$DOCKSHELL_ROOT/Build/distribution"
staging=$(mktemp -d "$DOCKSHELL_ROOT/Build/distribution/.release.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
app="$staging/DockShell.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
for architecture in $architectures; do
    scratch="$DOCKSHELL_ROOT/.build/distribution-$architecture"
    triple="$architecture-apple-macosx14.0"
    distribution_build "$scratch" -c release --triple "$triple" --product DockShell
    distribution_build "$scratch" -c release --triple "$triple" --product dockshell-ssh-helper
    bin=$(distribution_build "$scratch" -c release --triple "$triple" --show-bin-path)
    install -m 755 "$bin/DockShell" "$staging/DockShell-$architecture"
    install -m 755 "$bin/dockshell-ssh-helper" "$staging/helper-$architecture"
    bundle="$bin/SwiftTerm_SwiftTerm.bundle"
    [ -f "$bundle/Shaders.metal" ] || fail 'SwiftTerm resources were not built.'
    if [ -d "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle" ]; then
        /usr/bin/diff -qr "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle" "$bundle" >/dev/null || fail 'Architecture resource bundles differ; refusing an arbitrary merge.'
    else /usr/bin/ditto "$bundle" "$app/Contents/Resources/SwiftTerm_SwiftTerm.bundle"; fi
done
if [ "$universal" -eq 1 ]; then
    /usr/bin/lipo -create "$staging/DockShell-arm64" "$staging/DockShell-x86_64" -output "$app/Contents/MacOS/DockShell"
    /usr/bin/lipo -create "$staging/helper-arm64" "$staging/helper-x86_64" -output "$app/Contents/Helpers/dockshell-ssh-helper"
else
    install -m 755 "$staging/DockShell-$host_arch" "$app/Contents/MacOS/DockShell"
    install -m 755 "$staging/helper-$host_arch" "$app/Contents/Helpers/dockshell-ssh-helper"
fi
# The compiler tool runs on the host even when cross-building a second application slice.
tools_scratch="$DOCKSHELL_ROOT/.build/distribution-tools"
distribution_build "$tools_scratch" -c release --product catalog-compiler
tools_bin=$(distribution_build "$tools_scratch" -c release --show-bin-path)
"$tools_bin/catalog-compiler" "$DOCKSHELL_ROOT/Localization/Localizable.xcstrings" "$app/Contents/Resources/DockShellResources.bundle"
sh "$DOCKSHELL_ROOT/Scripts/install-branding.sh" "$app"
cp "$info" "$app/Contents/Info.plist"
cp "$DOCKSHELL_ROOT/Packaging/ThirdPartyNotices.txt" "$app/Contents/Resources/ThirdPartyNotices.txt"
/usr/bin/strip -S -x "$app/Contents/MacOS/DockShell" "$app/Contents/Helpers/dockshell-ssh-helper"
sign_code() {
    identifier=$1; target=$2
    if [ "$mode" = developer-id ]; then timestamp=--timestamp; else timestamp=--timestamp=none; fi
    /usr/bin/codesign --force --sign "$identity" --identifier "$identifier" --options runtime "$timestamp" \
        --entitlements "$DOCKSHELL_ROOT/Packaging/Release.entitlements" "$target"
}
sign_code dev.dockshell.ssh-helper "$app/Contents/Helpers/dockshell-ssh-helper"
sign_code dev.dockshell.app "$app"
sh "$DOCKSHELL_ROOT/Scripts/audit-release.sh" "$app" --mode "$mode" --architectures "$architecture_label"
stem="DockShell-$version-$build-$architecture_label-$mode"
result="$DOCKSHELL_ROOT/Build/distribution/$stem-$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
[ ! -e "$result" ] || fail 'A release with this timestamp already exists.'
mkdir "$result"
/usr/bin/ditto "$app" "$result/DockShell.app"
/usr/bin/ditto -c -k --keepParent "$result/DockShell.app" "$result/$stem.zip"
manifest="$result/ReleaseManifest.plist"
/usr/bin/plutil -create xml1 "$manifest"
/usr/bin/plutil -insert product -string DockShell "$manifest"
/usr/bin/plutil -insert version -string "$version" "$manifest"
/usr/bin/plutil -insert build -string "$build" "$manifest"
/usr/bin/plutil -insert architectures -string "$architecture_label" "$manifest"
/usr/bin/plutil -insert signingMode -string "$mode" "$manifest"
/usr/bin/plutil -insert notarized -bool NO "$manifest"
/usr/bin/plutil -insert publiclyDistributable -bool NO "$manifest"
/usr/bin/plutil -insert minimumSystem -string 14.0 "$manifest"
(cd "$result" && /usr/bin/shasum -a 256 "$stem.zip" > SHA256SUMS)
printf 'Prepared artifact: %s\n' "$result"
if [ "$mode" = local-preview ]; then
    printf '%s\n' 'LOCAL PREVIEW ONLY: no Apple account used; not Developer ID signed or notarized.'
else printf '%s\n' 'Signed artifact prepared. Notarization and final acceptance are still required; nothing was uploaded.'; fi

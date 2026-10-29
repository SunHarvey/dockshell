#!/bin/sh
# Failure guards are exercised without building, signing with a real identity or contacting Apple.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$#" -le 1 ] || { printf '%s\n' 'Usage: sh Scripts/test-release-scripts.sh [LOCAL_PREVIEW_APP]' >&2; exit 2; }
temporary=$(mktemp -d "${TMPDIR:-/tmp}/dockshell-release-guards.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
expect_failure() {
    label=$1; shift
    if "$@" >"$temporary/output" 2>&1; then
        printf 'FAIL release guard: %s\n' "$label" >&2; exit 1
    fi
}
for script in release.sh notarize.sh audit-release.sh; do /bin/sh -n "$root/Scripts/$script"; done
expect_failure 'release mode required' sh "$root/Scripts/release.sh"
expect_failure 'mutually exclusive signing modes' sh "$root/Scripts/release.sh" --local-preview --identity nonexistent
expect_failure 'missing Developer ID identity stops before a build' sh "$root/Scripts/release.sh" --identity nonexistent
expect_failure 'explicit notarization action required' sh "$root/Scripts/notarize.sh"
expect_failure 'raw account credentials are not accepted' sh "$root/Scripts/notarize.sh" --submit nowhere --profile test --password unsupported
expect_failure 'resume requires UUID and app' sh "$root/Scripts/notarize.sh" --resume invalid --app nowhere --profile test
expect_failure 'audit requires an actual app' sh "$root/Scripts/audit-release.sh" "$temporary/missing.app" --mode local-preview
expect_failure 'preview cannot request a notary ticket' sh "$root/Scripts/audit-release.sh" "$temporary/missing.app" --mode local-preview --require-notarized
printf '%s\n' 'PASS release script guards: required modes, identity, no raw credentials, resume UUID, missing artifact and preview limits'
if [ "$#" -eq 1 ]; then
    sh "$root/Scripts/audit-release.sh" "$1" --mode local-preview
    expect_failure 'ad-hoc preview cannot pass Developer ID verification' sh "$root/Scripts/audit-release.sh" "$1" --mode developer-id
    expect_failure 'ad-hoc preview is rejected before notarization submission' sh "$root/Scripts/notarize.sh" --submit "$1" --profile unused-test-profile
    /usr/bin/ditto "$1" "$temporary/Tampered.app"
    printf '\n/* deliberately modified by the artifact verification test */\n' >>"$temporary/Tampered.app/Contents/Resources/DockShellResources.bundle/en.lproj/Localizable.strings"
    expect_failure 'changed localized resources break the sealed artifact' sh "$root/Scripts/audit-release.sh" "$temporary/Tampered.app" --mode local-preview
    /usr/bin/grep -Eq 'resource.*(modified|invalid)|invalid.*resource' "$temporary/output" || { cat "$temporary/output" >&2; exit 1; }
    printf '%s\n' 'PASS artifact guards: preview cannot become a Developer ID/notarized release; resource tampering is detected'
fi

#!/bin/sh
# Explicit opt-in upload. Credentials are read only by notarytool from an existing Keychain profile.
set -eu
DOCKSHELL_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
usage() {
    printf '%s\n' 'Usage: sh Scripts/notarize.sh --submit APP --profile EXISTING_PROFILE' \
        '   or: sh Scripts/notarize.sh --resume REQUEST_UUID --app APP --profile EXISTING_PROFILE' >&2
    exit 2
}
fail() { printf 'Notarization stopped: %s\n' "$1" >&2; exit 1; }
action=; app=; profile=; request=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --submit) [ -z "$action" ] && [ "$#" -ge 2 ] || usage; action=submit; app=$2; shift 2 ;;
        --resume) [ -z "$action" ] && [ "$#" -ge 2 ] || usage; action=resume; request=$2; shift 2 ;;
        --app) [ "$#" -ge 2 ] || usage; app=$2; shift 2 ;;
        --profile) [ "$#" -ge 2 ] || usage; profile=$2; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$action" ] && [ -n "$app" ] && [ -n "$profile" ] || usage
if [ "$action" = resume ]; then
    printf '%s\n' "$request" | /usr/bin/grep -Eq '^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$' || fail 'Invalid submission UUID.'
fi
xcrun --find notarytool >/dev/null 2>&1 || fail 'notarytool is not available in the selected developer tools.'
xcrun --find stapler >/dev/null 2>&1 || fail 'stapler is not available in the selected developer tools.'
sh "$DOCKSHELL_ROOT/Scripts/audit-release.sh" "$app" --mode developer-id
app=$(CDPATH= cd -- "$app" && pwd)
mkdir -p "$DOCKSHELL_ROOT/Build/notarization"
result=$(mktemp -d "$DOCKSHELL_ROOT/Build/notarization/submission.XXXXXX")
# Preserve the original reviewed artifact. A successful ticket is stapled only to this copy.
/usr/bin/ditto "$app" "$result/DockShell.app"
archive="$result/upload.zip"
if [ "$action" = submit ]; then
    /usr/bin/ditto -c -k --keepParent "$result/DockShell.app" "$archive"
    printf '%s\n' 'Uploading this signed application to Apple using the specified existing Keychain profile.'
    if ! xcrun notarytool submit "$archive" --keychain-profile "$profile" --no-wait --output-format json >"$result/submission.json"; then
        printf 'Review directory: %s\n' "$result" >&2
        fail 'Submission failed. No credential was passed through this script.'
    fi
    if ! request=$(/usr/bin/plutil -extract id raw -o - "$result/submission.json" 2>/dev/null); then
        printf 'Review directory: %s\n' "$result" >&2
        fail 'Apple returned no submission UUID. Review the saved JSON before retrying.'
    fi
fi
printf '%s\n' "$request" | /usr/bin/grep -Eq '^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$' || fail 'The submission response contains an invalid UUID.'
printf '%s\n' "$request" >"$result/request-id.txt"
# Record bytes for review. Stapling validates that Apple's ticket actually matches this code.
/usr/bin/shasum -a 256 "$result/DockShell.app/Contents/MacOS/DockShell" \
    "$result/DockShell.app/Contents/Helpers/dockshell-ssh-helper" >"$result/executable-sha256.txt"
wait_failed=0
xcrun notarytool wait "$request" --keychain-profile "$profile" --timeout 10m --output-format json >"$result/status.json" || wait_failed=1
status=$(/usr/bin/plutil -extract status raw -o - "$result/status.json" 2>/dev/null) || status=
if [ "$wait_failed" -eq 1 ] && [ "$status" != Invalid ] && [ "$status" != Rejected ]; then
    printf 'Submission UUID: %s\nReview directory: %s\n' "$request" "$result" >&2
    fail 'Waiting failed or timed out. Resume this UUID; do not create a duplicate submission.'
fi
if [ "$status" != Accepted ]; then
    xcrun notarytool log "$request" --keychain-profile "$profile" "$result/notary-log.json" || true
    printf 'Submission UUID: %s\nReview directory: %s\n' "$request" "$result" >&2
    fail 'Apple did not accept this submission; no release archive was produced.'
fi
xcrun stapler staple "$result/DockShell.app"
sh "$DOCKSHELL_ROOT/Scripts/audit-release.sh" "$result/DockShell.app" --mode developer-id --require-notarized
info="$result/DockShell.app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")
case "$version:$build" in *[!0-9.:]*) fail 'Unsafe version metadata.' ;; esac
[ -n "$version" ] && [ -n "$build" ] || fail 'Empty version metadata.'
name="DockShell-$version-$build-notarized.zip"
# Stapling changes the container. Recreate the deliverable and checksum afterwards.
/usr/bin/ditto -c -k --keepParent "$result/DockShell.app" "$result/$name"
(cd "$result" && /usr/bin/shasum -a 256 "$name" > SHA256SUMS)
manifest="$result/NotarizationManifest.plist"
/usr/bin/plutil -create xml1 "$manifest"
/usr/bin/plutil -insert submissionID -string "$request" "$manifest"
/usr/bin/plutil -insert notarized -bool YES "$manifest"
/usr/bin/plutil -insert gatekeeperAccepted -bool YES "$manifest"
/usr/bin/plutil -insert targetEnvironmentAcceptanceRequired -bool YES "$manifest"
printf 'Notarized review artifact: %s\n' "$result"
printf '%s\n' 'Ticket and Gatekeeper checks passed. Complete target-system acceptance before publishing; this script does not publish.'

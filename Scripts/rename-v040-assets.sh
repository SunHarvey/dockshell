#!/bin/sh
# One narrowly scoped, idempotent maintenance operation for the already published v0.4.0.
# The DMG is renamed through PATCH; it is never rebuilt, deleted or re-uploaded.
set -eu
[ "$#" -eq 1 ] || { printf '%s\n' 'Usage: sh Scripts/rename-v040-assets.sh plan|apply' >&2; exit 2; }
case "$1" in plan|apply) mode=$1 ;; *) exit 2 ;; esac
[ "${GH_REPO:-}" = SunHarvey/dockshell ] || { printf '%s\n' 'Unexpected repository.' >&2; exit 1; }
: "${ASSET_MAINTENANCE_DIR:?A private operation directory is required}"
mkdir -p "$ASSET_MAINTENANCE_DIR"
cd "$ASSET_MAINTENANCE_DIR"
repo=$GH_REPO
tag=v0.4.0
source_commit=aec968f07206b3279ee8c3fa21eaaf82058c092e
tag_object=6da5c98c98f79937246bddf7c732db9a46cddd98
asset_id=696828965
old_name=DockShell-0.4.0-25-arm64-local-preview.dmg
new_name=DockShell-0.4.0-arm64.dmg
expected_digest=f745f92d4b5d5a62e1260b4a7b269d1e4e5222856967b97e437ec9430ed2f6db
manifest_digest=ba8483df58f368f7347acacfc8f55d77e7ede6b52e63990913bb13cc1723cb29
fail() { printf 'Asset maintenance stopped: %s\n' "$1" >&2; exit 1; }
digest() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
    else shasum -a 256 "$1" | cut -d ' ' -f 1; fi
}
download() {
    curl --fail --location --retry 3 --silent --show-error --max-time 60 \
        "https://github.com/$repo/releases/download/$tag/$1" --output "$2"
}

# Refuse a moved tag, a different release, or unexpected binary/manifest content before any write.
gh api "repos/$repo/git/ref/tags/$tag" > tag-ref.json
jq -e --arg sha "$tag_object" '.object.type == "tag" and .object.sha == $sha' tag-ref.json >/dev/null
gh api "repos/$repo/git/tags/$tag_object" > tag.json
jq -e --arg sha "$source_commit" '.object.type == "commit" and .object.sha == $sha and .verification.verified == true' tag.json >/dev/null
gh api "repos/$repo/releases/tags/$tag" > before.json
jq -e --arg tag "$tag" '.id == 430263236 and .name == $tag and .tag_name == $tag and .draft == false and .prerelease == false and .immutable != true' before.json >/dev/null
jq -e --argjson id "$asset_id" --arg old "$old_name" --arg new "$new_name" --arg digest "sha256:$expected_digest" '
    [.assets[] | select(.id == $id and (.name == $old or .name == $new) and .digest == $digest and .state == "uploaded")] | length == 1' before.json >/dev/null
jq -e --arg old "$old_name" --arg new "$new_name" '[.assets[] | select(.name == $old or .name == $new)] | length == 1' before.json >/dev/null
current_name=$(jq -r --argjson id "$asset_id" '.assets[] | select(.id == $id) | .name' before.json)
release_id=$(jq -r '.id' before.json)
mkdir -p before after
download "$current_name" before/installer.dmg
[ "$(digest before/installer.dmg)" = "$expected_digest" ] || fail 'The published DMG differs from the reviewed v0.4.0.'
download ReleaseManifest.plist before/ReleaseManifest.plist
[ "$(digest before/ReleaseManifest.plist)" = "$manifest_digest" ] || fail 'The source/build manifest differs from the reviewed release.'
checksum_count=$(jq '[.assets[] | select(.name == "SHA256SUMS")] | length' before.json)
[ "$checksum_count" -le 1 ] || fail 'Duplicate checksum assets.'
if [ "$checksum_count" -eq 1 ]; then
    download SHA256SUMS before/SHA256SUMS
    record=$(cat before/SHA256SUMS)
    [ "$record" = "$expected_digest  $old_name" ] || [ "$record" = "$expected_digest  $new_name" ] \
        || fail 'Unexpected checksum contents.'
else
    # Recovery after an interrupted checksum replacement; all binary/tag/manifest guards still apply.
    printf '%s  %s\n' "$expected_digest" "$current_name" > before/SHA256SUMS
fi
printf '%s  %s\n' "$expected_digest" "$new_name" > after/SHA256SUMS
jq -rj '.body' before.json > before/ReleaseNotes.md
jq --arg old '从下方 **Assets** 下载 `.dmg`' --arg new '从下方 **Assets** 下载 `DockShell-0.4.0-arm64.dmg`' \
    '{body:(.body | split($old) | join($new))}' before.json > after/notes-request.json
jq -rj '.body' after/notes-request.json > after/ReleaseNotes.md
printf 'Reviewed change: %s -> %s; SHA256=%s\n' "$current_name" "$new_name" "$expected_digest"
[ "$mode" = apply ] || exit 0

changed_name=0; changed_checksum=0; changed_notes=0; complete=0
rollback() {
    status=$?
    if [ "$complete" -eq 0 ]; then
        # Best-effort recovery uses the saved original data; a failure remains visible for retry.
        if [ "$changed_notes" -eq 1 ]; then
            jq '{body:.body}' before.json > before/notes-request.json
            gh api --method PATCH "repos/$repo/releases/$release_id" --input before/notes-request.json >/dev/null \
                || printf '%s\n' 'WARNING: release-note restoration failed; review the backup.' >&2
        fi
        if [ "$changed_checksum" -eq 1 ]; then
            gh release upload "$tag" before/SHA256SUMS --clobber --repo "$repo" \
                || printf '%s\n' 'WARNING: checksum restoration failed; review the backup.' >&2
        fi
        if [ "$changed_name" -eq 1 ]; then
            gh api --method PATCH "repos/$repo/releases/assets/$asset_id" -f "name=$current_name" >/dev/null \
                || printf '%s\n' 'WARNING: filename restoration failed; review the backup.' >&2
        fi
    fi
    exit "$status"
}
trap rollback EXIT
if [ "$current_name" != "$new_name" ]; then
    changed_name=1
    gh api --method PATCH "repos/$repo/releases/assets/$asset_id" -f "name=$new_name" > after/renamed-asset.json
fi
if [ "$checksum_count" -eq 0 ] || ! cmp -s before/SHA256SUMS after/SHA256SUMS; then
    changed_checksum=1
    gh release upload "$tag" after/SHA256SUMS --clobber --repo "$repo"
fi
if ! cmp -s before/ReleaseNotes.md after/ReleaseNotes.md; then
    changed_notes=1
    gh api --method PATCH "repos/$repo/releases/$release_id" --input after/notes-request.json > after/updated-release.json
fi
# Read public URLs, not authenticated downloads, to prove the advertised installer and checksum work.
download "$new_name" after/installer.dmg
download SHA256SUMS after/published-checksums.txt
cmp before/installer.dmg after/installer.dmg
cmp after/SHA256SUMS after/published-checksums.txt
download ReleaseManifest.plist after/ReleaseManifest.plist
cmp before/ReleaseManifest.plist after/ReleaseManifest.plist
gh api "repos/$repo/releases/tags/$tag" > after/release.json
jq -e --argjson id "$asset_id" --arg name "$new_name" --arg digest "sha256:$expected_digest" '
    .name == "v0.4.0" and .draft == false and .prerelease == false and
    ([.assets[] | select(.id == $id and .name == $name and .digest == $digest)] | length == 1)' after/release.json >/dev/null
gh api "repos/$repo/releases/latest" --jq .tag_name | grep -Fxq "$tag"
complete=1
printf '%s\n' 'PASS v0.4.0 asset names: DMG bytes/ID/digest and manifest unchanged; checksum, notes and public download updated; Latest preserved'

#!/bin/sh
# Validates an existing version tag and assembles arm64 preview assets for CI.
# No tag, commit, GitHub release, signing identity or notarization credential is created here.
set -eu
export LC_ALL=C

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
usage() {
    printf '%s\n' 'Usage: sh Scripts/ci-release.sh validate|prepare TAG' >&2
    exit 2
}
fail() { printf 'CI release preparation failed: %s\n' "$1" >&2; exit 1; }
single_line() {
    case "$1" in
        *'
'*|*"$(printf '\r')"*) fail 'A release path or value contains a line break.' ;;
    esac
}
output() {
    single_line "$2"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    fi
}

[ "$#" -eq 2 ] || usage
action=$1; tag=$2
case "$action" in validate|prepare) ;; *) usage ;; esac
single_line "$root"
# An allowlist rejects line breaks and shell metacharacters before the line-based regex.
case "$tag" in ''|*[!A-Za-z0-9.-]*) fail 'The tag must be a safe vMAJOR.MINOR.PATCH version.' ;; esac
printf '%s\n' "$tag" | /usr/bin/grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$' \
    || fail 'The tag must be a safe vMAJOR.MINOR.PATCH version.'

info="$root/Packaging/Info.plist"
[ -f "$info" ] && [ ! -L "$info" ] || fail 'Packaging/Info.plist is missing or is a symlink.'
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info") || fail 'The application version is missing.'
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info") || fail 'The application build number is missing.'
case "$version" in ''|*[!0-9.]*) fail 'The application version must be MAJOR.MINOR.PATCH.' ;; esac
printf '%s\n' "$version" | /usr/bin/grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    || fail 'The application version must be MAJOR.MINOR.PATCH.'
case "$build" in ''|*[!0-9]*) fail 'The application build number must be a positive integer.' ;; esac
printf '%s\n' "$build" | /usr/bin/grep -Eq '^[1-9][0-9]*$' \
    || fail 'The application build number must be a positive integer.'
tag_version=${tag#v}; tag_version=${tag_version%%-*}
[ "$tag_version" = "$version" ] || fail 'The tag version does not match Packaging/Info.plist.'

repository=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || fail 'The project is not a Git repository.'
[ "$repository" = "$root" ] || fail 'The project must be the repository root.'
commit=$(git -C "$root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || fail 'HEAD is not a commit.'
tag_commit=$(git -C "$root" rev-parse --verify "refs/tags/$tag^{commit}" 2>/dev/null) \
    || fail 'The requested tag does not exist or does not refer to a commit.'
[ "$tag_commit" = "$commit" ] || fail 'HEAD does not match the requested tag.'
[ -z "$(git -C "$root" status --porcelain --untracked-files=normal)" ] \
    || fail 'A clean working tree is required so the package matches the tagged commit.'

printf 'Validated tag: %s; version: %s; build: %s; commit: %s\n' "$tag" "$version" "$build" "$commit"
output tag "$tag"
output version "$version"
output build "$build"
output commit "$commit"
[ "$action" = prepare ] || exit 0
[ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || fail 'Preview preparation requires a macOS arm64 build host.'

mkdir -p "$root/Build"
request=$(mktemp -d "$root/Build/.ci-release-request.XXXXXX")
artifact_dir=
complete=0
cleanup() {
    rm -rf "$request"
    if [ "$complete" -eq 0 ] && [ -n "$artifact_dir" ]; then rm -rf "$artifact_dir"; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# The release script writes this file only after its build, signing and audit succeed.
result_file="$request/result-path.txt"
sh "$root/Scripts/release.sh" --local-preview --result-file "$result_file"
[ -f "$result_file" ] && [ ! -L "$result_file" ] || fail 'The build produced no result-file handoff.'
result=$(cat "$result_file")
single_line "$result"
[ -d "$result" ] && [ ! -L "$result" ] || fail 'The build returned an invalid artifact directory.'
result=$(CDPATH= cd -- "$result" && pwd -P)
distribution=$(CDPATH= cd -- "$root/Build/distribution" && pwd -P)
case "$result" in "$distribution"/*) ;; *) fail 'The build returned a directory outside Build/distribution.' ;; esac

zip_name="DockShell-$version-$build-arm64-local-preview.zip"
dmg_name="DockShell-$version-$build-arm64-local-preview.dmg"
archive="$result/$zip_name"
installer="$result/$dmg_name"
manifest="$result/ReleaseManifest.plist"
checksums="$result/SHA256SUMS"
for file in "$archive" "$installer" "$manifest" "$checksums"; do
    [ -f "$file" ] && [ ! -L "$file" ] || fail 'A required release file is missing or is a symlink.'
done
for key_value in "version:$version" "build:$build" 'architectures:arm64' 'signingMode:local-preview' 'notarized:false' 'publiclyDistributable:false'; do
    key=${key_value%%:*}; expected=${key_value#*:}
    actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$manifest") || fail 'The release manifest is incomplete.'
    [ "$actual" = "$expected" ] || fail 'The release manifest does not match the requested arm64 preview.'
done
# The source build keeps its ZIP for existing local verification, while CI ships
# the DMG directly. Accept exactly one checksum for each expected source file.
found_zip=0; found_dmg=0
while IFS= read -r record || [ -n "$record" ]; do
    digest=${record%% *}
    case "$digest" in ''|*[!0-9a-f]*) fail 'The release checksum is not a SHA-256 digest.' ;; esac
    [ "${#digest}" -eq 64 ] || fail 'The release checksum is not a SHA-256 digest.'
    case "$record" in
        "$digest  $zip_name") [ "$found_zip" -eq 0 ] || fail 'The preview ZIP checksum is duplicated.'; found_zip=1 ;;
        "$digest  $dmg_name") [ "$found_dmg" -eq 0 ] || fail 'The preview DMG checksum is duplicated.'; found_dmg=1 ;;
        *) fail 'SHA256SUMS must identify only the expected preview ZIP and DMG.' ;;
    esac
done < "$checksums"
[ "$found_zip:$found_dmg" = 1:1 ] || fail 'SHA256SUMS must identify both the expected preview ZIP and DMG.'
sh "$root/Scripts/audit-release.sh" "$result/DockShell.app" --mode local-preview --architectures arm64
(cd "$result" && /usr/bin/shasum -a 256 -c SHA256SUMS)

artifact_dir=$(mktemp -d "$root/Build/ci-release.XXXXXX")
cp "$installer" "$manifest" "$artifact_dir/"
(cd "$artifact_dir" && /usr/bin/shasum -a 256 "$dmg_name" > SHA256SUMS)
/usr/bin/plutil -insert sourceCommit -string "$commit" "$artifact_dir/ReleaseManifest.plist"
/usr/bin/plutil -insert releaseTag -string "$tag" "$artifact_dir/ReleaseManifest.plist"
if /usr/libexec/PlistBuddy -c 'Print :installerFormat' "$artifact_dir/ReleaseManifest.plist" >/dev/null 2>&1; then
    /usr/bin/plutil -replace installerFormat -string dmg "$artifact_dir/ReleaseManifest.plist"
else
    /usr/bin/plutil -insert installerFormat -string dmg "$artifact_dir/ReleaseManifest.plist"
fi
notes_path="$artifact_dir/ReleaseNotes.md"
cat > "$notes_path" <<EOF
# DockShell $tag — arm64 预览版

这是采用 ad-hoc 签名的开发测试包，尚未获得 Developer ID 签名或 Apple 公证。此版本作为 Pre-release 提供试用，尚未完成正式分发验收。

- 应用版本：$version
- 构建号：$build
- 架构：Apple Silicon / arm64
- 源码提交：$commit
- 部署目标：macOS 14；macOS 14 实机与 Intel 尚未完成验收。

在 GitHub Release 页面的 Assets 中下载以 .dmg 结尾的安装包，无需先解压 ZIP。双击打开后，将 DockShell.app 拖到 Applications（应用程序）快捷方式完成安装。安装只需 DMG，不需要下载 GitHub 自动生成的 Source code 归档。

安装窗口采用紧凑的品牌布局：左侧 DockShell 图标、中间箭头、右侧 Applications，并提供中英文拖动安装提示及适配 Retina 的背景。

单独的校验元数据与日志包用于核对和排查，安装只需下载 DMG 原文件。

macOS 安全检查可能阻止未公证应用运行；此流程不会移除隔离属性或改变系统安全设置。面向普通用户分发前仍需完成正式签名、公证和目标环境验收。

在下载文件所在目录校验 DMG：

    shasum -a 256 -c SHA256SUMS

这是预览版，不会标记为 Latest 正式版本。手动运行发布工作流时仍只创建草稿；推送编号预览标签时创建公开的 Pre-release。
EOF
(cd "$artifact_dir" && /usr/bin/shasum -a 256 -c SHA256SUMS)

dmg_path="$artifact_dir/$dmg_name"
manifest_path="$artifact_dir/ReleaseManifest.plist"
output artifact_dir "$artifact_dir"
output dmg_path "$dmg_path"
output notes_path "$notes_path"
output manifest_path "$manifest_path"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### DockShell 测试包\n\n- 标签：`%s`\n- 构建：`%s`\n- 架构：`arm64`\n- 格式：`DMG`，品牌安装窗口与中英文提示。\n- 提交：`%s`\n- 状态：ad-hoc 签名，未公证的测试预览。\n' \
        "$tag" "$build" "$commit" >> "$GITHUB_STEP_SUMMARY"
fi
complete=1
printf 'Prepared CI artifact directory: %s\n' "$artifact_dir"

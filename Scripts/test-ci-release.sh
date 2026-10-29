#!/bin/sh
# Exercises release identity/version guards in disposable repositories, without network or keys.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/dockshell-ci-release-tests.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
fixture="$temporary/project with spaces"
mkdir -p "$fixture/Scripts" "$fixture/Packaging" "$temporary/bin"
cp "$root/Scripts/ci-release.sh" "$fixture/Scripts/ci-release.sh"
cat > "$fixture/Scripts/release.sh" <<'SH'
#!/bin/sh
printf '%s\n' 'The release build must not run in guard tests.' >&2
exit 97
SH
printf '%s\n' 'Disposable release guard fixture.' > "$fixture/README.fixture"
/usr/bin/plutil -create xml1 "$fixture/Packaging/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 0.1.0 "$fixture/Packaging/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string 16 "$fixture/Packaging/Info.plist"
git -C "$fixture" init -q -b main
git -C "$fixture" config --local user.name 'DockShell CI fixture'
git -C "$fixture" config --local user.email fixture@example.invalid
git -C "$fixture" config --local commit.gpgsign false
git -C "$fixture" config --local tag.gpgsign false
git -C "$fixture" add -- .
git -C "$fixture" commit -q -m fixture
initial=$(git -C "$fixture" rev-parse HEAD)
git -C "$fixture" tag v0.1.0
git -C "$fixture" tag -a v0.1.0-preview.1 -m 'Annotated preview fixture'
git -C "$fixture" tag v0.2.0
git -C "$fixture" branch v0.1.0-branch-only

expect_failure() {
    label=$1; expected=$2; shift 2
    if "$@" > "$temporary/output" 2>&1; then
        printf 'FAIL CI release guard: %s unexpectedly succeeded\n' "$label" >&2
        exit 1
    fi
    if ! /usr/bin/grep -Fq "$expected" "$temporary/output"; then
        printf 'FAIL CI release guard: %s failed for a different reason\n' "$label" >&2
        cat "$temporary/output" >&2
        exit 1
    fi
}
check_valid() {
    tag=$1
    GITHUB_OUTPUT="$temporary/github-output" sh "$fixture/Scripts/ci-release.sh" validate "$tag" > "$temporary/output"
    /usr/bin/grep -Fqx "tag=$tag" "$temporary/github-output"
    /usr/bin/grep -Fqx 'version=0.1.0' "$temporary/github-output"
    /usr/bin/grep -Fqx 'build=16' "$temporary/github-output"
    /usr/bin/grep -Fqx "commit=$initial" "$temporary/github-output"
    rm "$temporary/github-output"
}
check_valid v0.1.0
check_valid v0.1.0-preview.1
expect_failure 'missing command' 'Usage:' sh "$fixture/Scripts/ci-release.sh"
expect_failure 'unknown command' 'Usage:' sh "$fixture/Scripts/ci-release.sh" publish v0.1.0
expect_failure 'version mismatch' 'tag version does not match' sh "$fixture/Scripts/ci-release.sh" validate v0.2.0
expect_failure 'missing tag' 'requested tag does not exist' sh "$fixture/Scripts/ci-release.sh" validate v0.1.0-missing
expect_failure 'branch cannot stand in for tag' 'requested tag does not exist' sh "$fixture/Scripts/ci-release.sh" validate v0.1.0-branch-only
expect_failure 'option-like tag' 'safe vMAJOR.MINOR.PATCH' sh "$fixture/Scripts/ci-release.sh" validate --help
expect_failure 'shell metacharacters' 'safe vMAJOR.MINOR.PATCH' sh "$fixture/Scripts/ci-release.sh" validate 'v0.1.0;touch PWNED'
expect_failure 'non-ASCII tag' 'safe vMAJOR.MINOR.PATCH' sh "$fixture/Scripts/ci-release.sh" validate 'v0.1.0-测试'
line_break_tag=$(printf 'v0.1.0\noutput=injected')
expect_failure 'newline output injection' 'safe vMAJOR.MINOR.PATCH' sh "$fixture/Scripts/ci-release.sh" validate "$line_break_tag"

printf '%s\n' 'dirty tracked content' >> "$fixture/README.fixture"
expect_failure 'dirty tracked source' 'clean working tree is required' sh "$fixture/Scripts/ci-release.sh" validate v0.1.0
git -C "$fixture" restore -- README.fixture
printf '%s\n' untracked > "$fixture/untracked.swift"
expect_failure 'untracked source' 'clean working tree is required' sh "$fixture/Scripts/ci-release.sh" validate v0.1.0
rm "$fixture/untracked.swift"
printf '%s\n' 'new committed content' >> "$fixture/README.fixture"
git -C "$fixture" add -- README.fixture
git -C "$fixture" commit -q -m 'Move HEAD beyond the selected tag'
expect_failure 'HEAD/tag mismatch' 'HEAD does not match' sh "$fixture/Scripts/ci-release.sh" validate v0.1.0
git -C "$fixture" reset -q --hard "$initial"

for invalid_build in 0 -1 16x; do
    /usr/bin/plutil -replace CFBundleVersion -string "$invalid_build" "$fixture/Packaging/Info.plist"
    expect_failure 'invalid build number' 'build number must be a positive integer' sh "$fixture/Scripts/ci-release.sh" validate v0.1.0
done
git -C "$fixture" restore -- Packaging/Info.plist
/usr/bin/plutil -replace CFBundleShortVersionString -string 0.1 "$fixture/Packaging/Info.plist"
expect_failure 'invalid application version' 'application version must be MAJOR.MINOR.PATCH' sh "$fixture/Scripts/ci-release.sh" validate v0.1.0
git -C "$fixture" restore -- Packaging/Info.plist

# Simulate only the host capability check. This never mocks or invokes the build/audit pipeline.
cat > "$temporary/bin/uname" <<'SH'
#!/bin/sh
case "$1" in -s) printf '%s\n' Darwin ;; -m) printf '%s\n' x86_64 ;; *) exit 1 ;; esac
SH
chmod 755 "$temporary/bin/uname"
expect_failure 'non-arm64 host' 'requires a macOS arm64 build host' env PATH="$temporary/bin:$PATH" sh "$fixture/Scripts/ci-release.sh" prepare v0.1.0
check_valid v0.1.0-preview.1
[ ! -e "$fixture/PWNED" ]
[ -z "$(git -C "$fixture" status --porcelain)" ]
printf '%s\n' 'PASS CI release guards: lightweight/annotated tags, safe version identity, output fields, clean source, HEAD matching, host architecture and paths with spaces'

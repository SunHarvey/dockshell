#!/bin/sh
set -eu

if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' 'DockShell requires macOS.' >&2
    exit 1
fi

xcrun --find swift >/dev/null
xcrun --sdk macosx --show-sdk-path >/dev/null
for tool in /usr/bin/codesign /usr/bin/plutil /usr/bin/ssh; do
    if [ ! -x "$tool" ]; then
        printf 'Required system tool missing: %s\n' "$tool" >&2
        exit 1
    fi
done

xcrun swift --version
printf 'macOS SDK: '
xcrun --sdk macosx --show-sdk-version
/usr/bin/ssh -V
printf '%s\n' 'DockShell uses CLT and system frameworks; no Xcode or Apple account login is required.'

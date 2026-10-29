#!/bin/sh
# Builds an untouched official release only inside this probe's directory.
# Supply an existing OpenSSL prefix. This script never installs system software.
set -eu

probe_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
crypto_prefix=${1:?Usage: build-and-run.sh /path/to/existing/openssl-prefix}
crypto_prefix=$(CDPATH='' cd -- "$crypto_prefix" && pwd)
if [ ! -f "$crypto_prefix/include/openssl/opensslv.h" ]; then
    echo '错误：指定目录没有 OpenSSL 头文件。不会自动安装依赖。' >&2
    exit 1
fi

version=1.11.1
archive="$probe_root/.vendor/libssh2-$version.tar.gz"
archive_sha256=d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7
source_root="$probe_root/.vendor/libssh2-$version"
local_prefix="$probe_root/.local"
mkdir -p "$probe_root/.vendor" "$probe_root/.build"
if [ ! -f "$archive" ]; then
    curl --fail --location --proto '=https' --tlsv1.2 \
        "https://libssh2.org/download/libssh2-$version.tar.gz" -o "$archive"
fi
printf '%s  %s\n' "$archive_sha256" "$archive" | shasum -a 256 -c -
if [ ! -d "$source_root" ]; then
    tar -xzf "$archive" -C "$probe_root/.vendor"
fi
if [ ! -f "$local_prefix/lib/libssh2.a" ]; then
    (
        cd "$source_root"
        env MACOSX_DEPLOYMENT_TARGET=14.0 CFLAGS='-O2 -mmacosx-version-min=14.0' \
            LDFLAGS='-mmacosx-version-min=14.0' ./configure \
            --prefix="$local_prefix" --with-crypto=openssl \
            --with-libssl-prefix="$crypto_prefix" --without-libz \
            --disable-shared --enable-static --disable-examples-build \
            --disable-docker-tests --disable-sshd-tests \
            > "$probe_root/.vendor/configure.log" 2>&1
        make -j4 > "$probe_root/.vendor/make.log" 2>&1
        make install > "$probe_root/.vendor/install.log" 2>&1
    )
fi

cd "$probe_root"
env CLANG_MODULE_CACHE_PATH="$probe_root/.build/module-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="$probe_root/.build/module-cache" \
    swift run --disable-sandbox \
        --cache-path .build/cache --config-path .build/config --security-path .build/security \
        -Xcc "-I$local_prefix/include" \
        -Xlinker "-L$local_prefix/lib" -Xlinker "-L$crypto_prefix/lib" libssh2-probe

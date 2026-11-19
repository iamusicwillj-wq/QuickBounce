#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_root="$project_root/.quickbounce-build-cache/lame"
source_archive="$build_root/lame-3.100.tar.gz"
source_root="$build_root/lame-3.100"
output_archive="$project_root/Sources/QuickBounceLAMEShim/lib/libmp3lame.a"
upstream_url="https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz"
expected_sha256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
deployment_target="14.0"

/bin/mkdir -p "$build_root" "${output_archive:h}"

if [[ ! -f "$source_archive" ]]; then
    /usr/bin/curl --fail --location --retry 3 "$upstream_url" --output "$source_archive"
fi

actual_sha256="$(/usr/bin/shasum -a 256 "$source_archive" | /usr/bin/awk '{print $1}')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    print -u2 "LAME source checksum mismatch: $actual_sha256"
    exit 1
fi

if [[ ! -d "$source_root" ]]; then
    /usr/bin/tar -xzf "$source_archive" -C "$build_root"
fi

clang_path="$(/usr/bin/xcrun --find clang)"
sdk_root="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
archives=()
for architecture in arm64 x86_64; do
    architecture_root="$build_root/$architecture"
    install_root="$architecture_root/install"
    /bin/rm -rf "$architecture_root"
    /bin/mkdir -p "$architecture_root" "$install_root"

    host="arm-apple-darwin"
    if [[ "$architecture" == "x86_64" ]]; then
        host="x86_64-apple-darwin"
    fi

    (
        cd "$architecture_root"
        env \
            CC="$clang_path" \
            SDKROOT="$sdk_root" \
            CFLAGS="-arch $architecture -isysroot $sdk_root -mmacosx-version-min=$deployment_target -O3" \
            LDFLAGS="-arch $architecture -isysroot $sdk_root -mmacosx-version-min=$deployment_target" \
            "$source_root/configure" \
                --host="$host" \
                --prefix="$install_root" \
                --disable-shared \
                --enable-static \
                --disable-frontend \
                --disable-decoder \
                --disable-dependency-tracking
        /usr/bin/make -j4
        /usr/bin/make install
    )
    archives+=("$install_root/lib/libmp3lame.a")
done

/usr/bin/lipo -create "${archives[@]}" -output "$output_archive"
/usr/bin/lipo "$output_archive" -verify_arch arm64 x86_64
/usr/bin/lipo -info "$output_archive"

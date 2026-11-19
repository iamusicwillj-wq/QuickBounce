#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_root="${QUICKBOUNCE_BUILD_ROOT:-$project_root/Build}"
info_plist="$project_root/Packaging/Info.plist"
entitlements="$project_root/Packaging/QuickBounce.entitlements"
local_entitlements="$project_root/Packaging/QuickBounce.Local.entitlements"
license="$project_root/LICENSE"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
app_bundle="$build_root/QuickBounce V${version}.app"
contents="$app_bundle/Contents"
macos_directory="$contents/MacOS"
frameworks_directory="$contents/Frameworks"
resources_directory="$contents/Resources"
licenses_directory="$resources_directory/Licenses/LAME"
iconset_directory="$build_root/QuickBounce.iconset"
ptsl_framework="$project_root/Vendor/AvidPTSL/PTSLC_CPP.framework"
ptsl_binary="$ptsl_framework/Versions/A/PTSLC_CPP"
lame_archive="$project_root/Sources/QuickBounceLAMEShim/lib/libmp3lame.a"
icon_source="$project_root/Packaging/QuickBounceIcon.png"
signing_identity="${QUICKBOUNCE_SIGN_IDENTITY:--}"

for required_file in "$info_plist" "$entitlements" "$local_entitlements" "$license" "$icon_source" "$ptsl_binary" "$lame_archive"; do
    if [[ ! -e "$required_file" ]]; then
        print -u2 "Missing release input: $required_file"
        exit 1
    fi
done

/usr/bin/lipo "$ptsl_binary" -verify_arch arm64 x86_64
/usr/bin/lipo "$lame_archive" -verify_arch arm64 x86_64

cd "$project_root"
/usr/bin/swift build \
    -c release \
    -j 4 \
    --product QuickBounce \
    --arch arm64 \
    --arch x86_64
release_bin="$project_root/.build/apple/Products/Release/QuickBounce"
/usr/bin/lipo "$release_bin" -verify_arch arm64 x86_64

/bin/rm -rf "$app_bundle" "$iconset_directory"
/bin/mkdir -p \
    "$macos_directory" \
    "$frameworks_directory" \
    "$licenses_directory" \
    "$iconset_directory"
/usr/bin/ditto "$release_bin" "$macos_directory/QuickBounce"
/usr/bin/ditto "$ptsl_framework" "$frameworks_directory/PTSLC_CPP.framework"
/usr/bin/ditto "$info_plist" "$contents/Info.plist"
/usr/bin/ditto "$project_root/README.md" "$resources_directory/README.md"
/usr/bin/ditto "$project_root/docs" "$resources_directory/docs"
/usr/bin/ditto "$license" "$resources_directory/LICENSE"
/usr/bin/ditto "$project_root/THIRD_PARTY_NOTICES.md" "$resources_directory/THIRD_PARTY_NOTICES.md"
/usr/bin/ditto "$project_root/Vendor/LAME/COPYING" "$licenses_directory/COPYING"
/usr/bin/ditto "$project_root/Vendor/LAME/LICENSE" "$licenses_directory/LICENSE"
/usr/bin/ditto "$project_root/Vendor/LAME/README.upstream" "$licenses_directory/README"

/usr/bin/sips -z 16 16 "$icon_source" --out "$iconset_directory/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "$icon_source" --out "$iconset_directory/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$icon_source" --out "$iconset_directory/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "$icon_source" --out "$iconset_directory/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "$icon_source" --out "$iconset_directory/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "$icon_source" --out "$iconset_directory/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$icon_source" --out "$iconset_directory/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "$icon_source" --out "$iconset_directory/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$icon_source" --out "$iconset_directory/icon_512x512.png" >/dev/null
/usr/bin/sips -z 1024 1024 "$icon_source" --out "$iconset_directory/icon_512x512@2x.png" >/dev/null
/usr/bin/iconutil -c icns "$iconset_directory" -o "$resources_directory/QuickBounce.icns"
/bin/rm -rf "$iconset_directory"

/usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$macos_directory/QuickBounce"

codesign_timestamp=(--timestamp)
app_entitlements="$entitlements"
if [[ "$signing_identity" == "-" ]]; then
    codesign_timestamp=(--timestamp=none)
    app_entitlements="$local_entitlements"
    print "Building a local ad-hoc Release Candidate; Developer ID signing and notarization remain pending."
fi

/usr/bin/codesign \
    --force \
    --sign "$signing_identity" \
    "${codesign_timestamp[@]}" \
    --options runtime \
    "$frameworks_directory/PTSLC_CPP.framework"
/usr/bin/codesign \
    --force \
    --sign "$signing_identity" \
    "${codesign_timestamp[@]}" \
    --options runtime \
    --entitlements "$app_entitlements" \
    "$app_bundle"

"$project_root/Tools/verify_release.sh" "$app_bundle"
print "$app_bundle"

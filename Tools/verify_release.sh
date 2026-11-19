#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
expected_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/Packaging/Info.plist")"
expected_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$project_root/Packaging/Info.plist")"
app_bundle="${1:-$project_root/Build/QuickBounce V${expected_version}.app}"
info_plist="$app_bundle/Contents/Info.plist"
app_binary="$app_bundle/Contents/MacOS/QuickBounce"
ptsl_binary="$app_bundle/Contents/Frameworks/PTSLC_CPP.framework/Versions/A/PTSLC_CPP"

if [[ ! -d "$app_bundle" ]]; then
    print -u2 "App bundle not found: $app_bundle"
    exit 1
fi

/usr/bin/plutil -lint "$info_plist" >/dev/null
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
if [[ "$version" != "$expected_version" || "$build" != "$expected_build" ]]; then
    print -u2 "Unexpected release version: $version ($build)"
    exit 1
fi

minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")"
if [[ "$minimum_macos" != "14.0" ]]; then
    print -u2 "Unexpected minimum macOS version: $minimum_macos"
    exit 1
fi

/usr/bin/lipo "$app_binary" -verify_arch arm64 x86_64
/usr/bin/lipo "$ptsl_binary" -verify_arch arm64 x86_64

for binary in "$app_binary" "$ptsl_binary"; do
    for architecture in arm64 x86_64; do
        binary_macos="$(/usr/bin/vtool -show-build -arch "$architecture" "$binary" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
        if [[ "$binary_macos" != "$minimum_macos" ]]; then
            print -u2 "Unexpected minimum macOS version for $binary ($architecture): $binary_macos"
            exit 1
        fi
    done
done

if /usr/bin/otool -L "$app_binary" | /usr/bin/grep -Eq '/opt/homebrew|/usr/local'; then
    print -u2 "Release binary contains a local package-manager dependency"
    exit 1
fi

test -s "$app_bundle/Contents/Resources/LICENSE"
for license_file in COPYING LICENSE README; do
    test -s "$app_bundle/Contents/Resources/Licenses/LAME/$license_file"
done

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
signature_details="$(/usr/bin/codesign --display --verbose=4 "$app_bundle" 2>&1)"
if [[ "$signature_details" != *"runtime"* ]]; then
    print -u2 "Hardened Runtime flag is missing"
    exit 1
fi
entitlement_details="$(/usr/bin/codesign --display --entitlements :- "$app_bundle" 2>/dev/null)"
if [[ "$entitlement_details" != *"com.apple.security.automation.apple-events"* ]]; then
    print -u2 "Apple Events entitlement is missing"
    exit 1
fi
if [[ "$signature_details" == *"Signature=adhoc"* ]]; then
    if [[ "$entitlement_details" != *"com.apple.security.cs.disable-library-validation"* ]]; then
        print -u2 "Local ad-hoc RC cannot load the embedded framework without its local-only Library Validation entitlement"
        exit 1
    fi
elif [[ "$entitlement_details" == *"com.apple.security.cs.disable-library-validation"* ]]; then
    print -u2 "Developer ID releases must keep Library Validation enabled"
    exit 1
fi

print "Verified QuickBounce V${version} (${build}): macOS ${minimum_macos}+, Universal 2, Hardened Runtime, embedded license notices, and valid code signature."

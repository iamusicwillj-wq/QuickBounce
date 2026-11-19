#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/Packaging/Info.plist")"
app_bundle="${1:-$project_root/Build/QuickBounce V${version}.app}"
notary_profile="${QUICKBOUNCE_NOTARY_PROFILE:-}"
archive="$project_root/Build/QuickBounce V${version}.zip"

if [[ -z "$notary_profile" ]]; then
    print -u2 "Set QUICKBOUNCE_NOTARY_PROFILE to a notarytool Keychain profile."
    exit 1
fi
if [[ ! -d "$app_bundle" ]]; then
    print -u2 "App bundle not found: $app_bundle"
    exit 1
fi

signature_details="$(/usr/bin/codesign --display --verbose=4 "$app_bundle" 2>&1)"
if [[ "$signature_details" == *"Signature=adhoc"* || "$signature_details" == *"TeamIdentifier=not set"* ]]; then
    print -u2 "Notarization requires a Developer ID Application signature."
    exit 1
fi

"$project_root/Tools/verify_release.sh" "$app_bundle"
archive_directory="${archive:h}"
/bin/mkdir -p "$archive_directory"
scratch_dir="$(/usr/bin/mktemp -d "$archive_directory/.notarize.XXXXXX")"
trap '/bin/rm -rf "$scratch_dir"' EXIT
submission_archive="$scratch_dir/submission.zip"
/usr/bin/ditto -c -k --keepParent "$app_bundle" "$submission_archive"
/usr/bin/xcrun notarytool submit \
    "$submission_archive" \
    --keychain-profile "$notary_profile" \
    --wait
/usr/bin/xcrun stapler staple "$app_bundle"
/usr/bin/xcrun stapler validate "$app_bundle"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app_bundle"
/usr/bin/ditto -c -k --keepParent "$app_bundle" "$scratch_dir/release.zip"
/bin/mv -f "$scratch_dir/release.zip" "$archive"
print "Notarized distribution: $archive"

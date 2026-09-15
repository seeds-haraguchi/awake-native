#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
output_dir="$repo_dir/build/distribution"
archive_path="$output_dir/Awake.xcarchive"
app_path="$archive_path/Products/Applications/Awake.app"
zip_path="$output_dir/Awake.zip"
dmg_path="$output_dir/Awake.dmg"
staging_dir="$output_dir/dmg-root"
identity="${SIGNING_IDENTITY:-Developer ID Application}"

if [[ -z "${DEVELOPMENT_TEAM:-}" || -z "${NOTARY_PROFILE:-}" ]]; then
  print -u2 "Set DEVELOPMENT_TEAM and NOTARY_PROFILE before running this script."
  exit 1
fi

if /usr/bin/grep -Rqs 'com.example.Awake' \
  "$repo_dir/macOS" "$repo_dir/Awake.xcodeproj/project.pbxproj"; then
  print -u2 "Replace the com.example.Awake placeholder identifiers before distribution."
  exit 1
fi

/bin/mkdir -p "$output_dir"

/usr/bin/xcodebuild archive \
  -project "$repo_dir/Awake.xcodeproj" \
  -scheme Awake \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$identity" \
  OTHER_CODE_SIGN_FLAGS='--timestamp' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

for executable in "$app_path/Contents/MacOS/Awake" "$app_path/Contents/MacOS/AwakeHelper"; do
  archs="$(/usr/bin/lipo -archs "$executable")"
  if [[ "$archs" != *arm64* || "$archs" != *x86_64* ]]; then
    print -u2 "Not Universal 2: $executable ($archs)"
    exit 1
  fi
done

/usr/bin/ditto -c -k --keepParent "$app_path" "$zip_path"
/usr/bin/xcrun notarytool submit "$zip_path" --keychain-profile "$NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$app_path"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"

/bin/rm -rf "$staging_dir"
/bin/mkdir -p "$staging_dir"
/usr/bin/ditto "$app_path" "$staging_dir/Awake.app"
/bin/ln -s /Applications "$staging_dir/Applications"
/usr/bin/hdiutil create \
  -volname Awake \
  -srcfolder "$staging_dir" \
  -ov \
  -format UDZO \
  "$dmg_path"

/usr/bin/codesign --force --timestamp --sign "$identity" "$dmg_path"
/usr/bin/xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$dmg_path"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

print "Created notarized and stapled DMG: $dmg_path"

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

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-VKKULG2DQ5}"

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  print -u2 "Set NOTARY_PROFILE before running this script."
  exit 1
fi

if [[ -n "$(/usr/bin/git -C "$repo_dir" status --porcelain)" ]]; then
  print -u2 "Commit or stash local changes first; the build number identifies the released commit."
  exit 1
fi

# The app replaces an installed helper whose build differs, so every release needs a new build number.
# The commit count only grows on main, so it is unique per released commit.
build_number="$(/usr/bin/git -C "$repo_dir" rev-list --count HEAD)"

/bin/mkdir -p "$output_dir"

/usr/bin/xcodebuild archive \
  -project "$repo_dir/Awake.xcodeproj" \
  -scheme Awake \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CURRENT_PROJECT_VERSION="$build_number" \
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

print "Created notarized and stapled DMG (build $build_number): $dmg_path"

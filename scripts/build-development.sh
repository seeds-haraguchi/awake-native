#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/build"
derived_data="$build_dir/DevelopmentDerivedData"
product="$derived_data/Build/Products/Debug/Awake.app"
output="$build_dir/Awake.app"

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  print -u2 "Set DEVELOPMENT_TEAM to your Apple Developer Team ID."
  print -u2 "Example: DEVELOPMENT_TEAM=ABCDE12345 ./scripts/build-development.sh"
  exit 1
fi

/usr/bin/xcodebuild \
  -project "$repo_dir/Awake.xcodeproj" \
  -scheme Awake \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  build

/bin/rm -rf "$output"
/usr/bin/ditto "$product" "$output"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$output"

app_archs="$(/usr/bin/lipo -archs "$output/Contents/MacOS/Awake")"
helper_archs="$(/usr/bin/lipo -archs "$output/Contents/MacOS/AwakeHelper")"
app_team="$(/usr/bin/codesign -dv --verbose=4 "$output" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
helper_team="$(/usr/bin/codesign -dv --verbose=4 "$output/Contents/MacOS/AwakeHelper" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"

if [[ "$app_archs" != *arm64* || "$app_archs" != *x86_64* ]]; then
  print -u2 "Awake executable is not Universal 2: $app_archs"
  exit 1
fi
if [[ "$helper_archs" != *arm64* || "$helper_archs" != *x86_64* ]]; then
  print -u2 "AwakeHelper executable is not Universal 2: $helper_archs"
  exit 1
fi
if [[ -z "$app_team" || "$app_team" != "$DEVELOPMENT_TEAM" ]]; then
  print -u2 "Awake is not signed by the requested team: ${app_team:-none}"
  exit 1
fi
if [[ "$helper_team" != "$app_team" ]]; then
  print -u2 "Awake and AwakeHelper have different signing teams."
  exit 1
fi

print "Built signed Universal 2 development app: $output"
print "Signing Team ID: $app_team"
print "Awake architectures: $app_archs"
print "Helper architectures: $helper_archs"
print "Copy Awake.app to /Applications before testing the privileged helper."

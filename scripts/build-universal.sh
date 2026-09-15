#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
build_dir="$repo_dir/build"
derived_data="$build_dir/DerivedData"
product="$derived_data/Build/Products/Release/Awake.app"
output="$build_dir/Awake.app"

/usr/bin/xcodebuild \
  -project "$repo_dir/Awake.xcodeproj" \
  -scheme Awake \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  build

/usr/bin/ditto "$product" "$output"

app_archs="$(/usr/bin/lipo -archs "$output/Contents/MacOS/Awake")"
helper_archs="$(/usr/bin/lipo -archs "$output/Contents/MacOS/AwakeHelper")"

if [[ "$app_archs" != *arm64* || "$app_archs" != *x86_64* ]]; then
  print -u2 "Awake executable is not Universal 2: $app_archs"
  exit 1
fi
if [[ "$helper_archs" != *arm64* || "$helper_archs" != *x86_64* ]]; then
  print -u2 "AwakeHelper executable is not Universal 2: $helper_archs"
  exit 1
fi

print "Built unsigned Universal 2 app: $output"
print "Awake architectures: $app_archs"
print "Helper architectures: $helper_archs"

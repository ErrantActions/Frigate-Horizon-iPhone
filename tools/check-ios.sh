#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: Full iOS compilation requires macOS and Xcode; Windows syntax checks are not equivalent." >&2
  exit 1
fi

for tool in xcodebuild xcrun swift xcodegen node plutil git; do
  if ! command -v "$tool" > /dev/null; then
    echo "ERROR: Missing $tool. Install full Xcode, Node.js, and the dependencies in Brewfile before running." >&2
    exit 1
  fi
done

export REQUIRE_DUO="${REQUIRE_DUO:-true}"
export APPLE_TEAM_ID=""
export BUILD_NUMBER="${BUILD_NUMBER:-1}"

# Source the shared setup so its SDK selection and compilation flags survive locally.
source .github/scripts/prepare-ios.sh
plutil -lint App/Info.plist App/PrivacyInfo.xcprivacy

mkdir -p build
results="$(mktemp -d "$root/build/local-check.XXXXXX")"
export IOS_RESULT_BUNDLE_PATH="$results/Tests.xcresult"
archive="$results/FrigateHorizon.xcarchive"

echo "Local validation results: $results"
echo "1/3: Core tests"
swift test
echo "2/3: Native simulator build and tests"
bash .github/scripts/test-ios.sh
echo "3/3: Unsigned Release archive for a physical iOS device"
xcodebuild \
  -project FrigateHorizon.xcodeproj \
  -scheme FrigateHorizon \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  -archivePath "$archive" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM= \
  archive

info="$archive/Products/Applications/FrigateHorizon.app/Info.plist"
plutil -lint "$info"
for key in NSCameraUsageDescription NSMicrophoneUsageDescription NSLocalNetworkUsageDescription; do
  value="$(plutil -extract "$key" raw -o - "$info")"
  if [[ -z "$value" ]]; then
    echo "ERROR: The archived app is missing a nonempty $key." >&2
    exit 1
  fi
done

{
  echo "LOCAL IOS VALIDATION PASSED"
  echo "Commit: $(git rev-parse HEAD)"
  echo "Working-tree changes at validation time:"
  git status --short
  xcodebuild -version
  echo "iOS SDK: $(xcrun --sdk iphoneos --show-sdk-version)"
  echo "Duo required: $REQUIRE_DUO; Duo compilation: ${DUO_SDK:-disabled}"
  echo "Simulator results: $IOS_RESULT_BUNDLE_PATH"
  echo "Unsigned Release archive: $archive"
  echo "Signing, Apple processing, networking, and physical-device behavior are not verified by this check."
} | tee "$results/validation.txt"

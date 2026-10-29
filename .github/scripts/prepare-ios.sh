#!/bin/bash
set -euo pipefail

export APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.errantactions.frigatehorizon}"
export APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
export BUILD_NUMBER="${BUILD_NUMBER:-1}"
export DUO_SDK=""
export ENABLE_NATIVE_PUSH="${ENABLE_NATIVE_PUSH:-false}"
export NATIVE_PUSH_ENABLED="NO"
export APP_ENTITLEMENTS_FILE="App/Horizon.entitlements"
if [[ "$ENABLE_NATIVE_PUSH" == "true" ]]; then
  export NATIVE_PUSH_ENABLED="YES"
  export APP_ENTITLEMENTS_FILE="App/HorizonPush.entitlements"
elif [[ "$ENABLE_NATIVE_PUSH" != "false" ]]; then
  echo "::error::ENABLE_NATIVE_PUSH must be true or false."
  exit 1
fi

if [[ -n "${XCODE_PATH:-}" ]]; then
  export DEVELOPER_DIR="$XCODE_PATH/Contents/Developer"
fi

xcodebuild -version
sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
sdk_major="${sdk%%.*}"
sdk_minor="${sdk#*.}"
sdk_minor="${sdk_minor%%.*}"
if (( sdk_major > 27 || (sdk_major == 27 && sdk_minor >= 1) )); then
  export DUO_SDK="DUO_SDK"
fi
if [[ "${REQUIRE_DUO:-false}" == "true" && "$DUO_SDK" != "DUO_SDK" ]]; then
  echo "::error::This build requires the iOS 27.1+ SDK for real fold-region detection. Selected SDK: $sdk. Select Xcode 27.1+ using XCODE_PATH or update the runner image."
  exit 1
fi
echo "iOS SDK: $sdk; fold-region integration: ${DUO_SDK:-disabled for compatibility}"
xcodegen generate

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "DUO_SDK=$DUO_SDK"
    echo "APP_BUNDLE_ID=$APP_BUNDLE_ID"
    echo "APPLE_TEAM_ID=$APPLE_TEAM_ID"
    echo "BUILD_NUMBER=$BUILD_NUMBER"
    echo "NATIVE_PUSH_ENABLED=$NATIVE_PUSH_ENABLED"
    echo "APP_ENTITLEMENTS_FILE=$APP_ENTITLEMENTS_FILE"
    if [[ -n "${DEVELOPER_DIR:-}" ]]; then echo "DEVELOPER_DIR=$DEVELOPER_DIR"; fi
  } >> "$GITHUB_ENV"
fi

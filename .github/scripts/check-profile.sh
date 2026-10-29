#!/bin/bash
set -euo pipefail
umask 077

if [[ "${ENABLE_NATIVE_PUSH:-false}" != "true" ]]; then
  echo "::error::This release requires separately approved ENABLE_NATIVE_PUSH=true with image notifications."
  exit 1
fi
if [[ "${APNS_IMAGES_BACKEND_READY:-false}" != "true" ]]; then
  echo "::error::Backend image-payload support must be verified and separately approved before this build."
  exit 1
fi

for name in APP_BUNDLE_ID APPLE_TEAM_ID PROVISIONING_PROFILE_BASE64 NOTIFICATION_SERVICE_PROFILE_BASE64; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Missing required signing configuration: $name"
    exit 1
  fi
done

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/horizon-profile.XXXXXX")"
cleanup() {
  rm -f "$work/profile.mobileprovision" "$work/profile.plist" \
    "$work/extension.mobileprovision" "$work/extension.plist"
  rmdir "$work"
}
trap cleanup EXIT

printf '%s' "$PROVISIONING_PROFILE_BASE64" | base64 --decode > "$work/profile.mobileprovision"
security cms -D -i "$work/profile.mobileprovision" > "$work/profile.plist"
printf '%s' "$NOTIFICATION_SERVICE_PROFILE_BASE64" | base64 --decode > "$work/extension.mobileprovision"
security cms -D -i "$work/extension.mobileprovision" > "$work/extension.plist"
python3 .github/scripts/validate-profile.py \
  --profile "$work/profile.plist" \
  --extension-profile "$work/extension.plist" \
  --team-id "$APPLE_TEAM_ID" \
  --bundle-id "$APP_BUNDLE_ID" \
  --native-push "${ENABLE_NATIVE_PUSH:-false}"

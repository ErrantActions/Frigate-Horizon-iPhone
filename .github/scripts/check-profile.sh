#!/bin/bash
set -euo pipefail
umask 077

for name in APP_BUNDLE_ID APPLE_TEAM_ID PROVISIONING_PROFILE_BASE64; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Missing required signing configuration: $name"
    exit 1
  fi
done

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/horizon-profile.XXXXXX")"
cleanup() {
  rm -f "$work/profile.mobileprovision" "$work/profile.plist"
  rmdir "$work"
}
trap cleanup EXIT

printf '%s' "$PROVISIONING_PROFILE_BASE64" | base64 --decode > "$work/profile.mobileprovision"
security cms -D -i "$work/profile.mobileprovision" > "$work/profile.plist"
python3 .github/scripts/validate-profile.py \
  --profile "$work/profile.plist" \
  --team-id "$APPLE_TEAM_ID" \
  --bundle-id "$APP_BUNDLE_ID" \
  --native-push "${ENABLE_NATIVE_PUSH:-false}"

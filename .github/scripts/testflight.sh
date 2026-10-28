#!/bin/bash
set -euo pipefail
umask 077

mask_value() {
  local value="$1"
  value="${value//%/%25}"
  value="${value//$'\r'/%0D}"
  value="${value//$'\n'/%0A}"
  printf '::add-mask::%s\n' "$value"
}

for name in APP_BUNDLE_ID APPLE_TEAM_ID DISTRIBUTION_CERTIFICATE_BASE64 \
  DISTRIBUTION_CERTIFICATE_PASSWORD PROVISIONING_PROFILE_BASE64 \
  APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_PRIVATE_KEY; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Missing required signing configuration: $name"
    exit 1
  fi
done

xcrun --find altool > /dev/null

work="$(mktemp -d "$RUNNER_TEMP/horizon-signing.XXXXXX")"
keychain="$work/signing.keychain-db"
keychain_password="$(openssl rand -hex 32)"
mask_value "$keychain_password"
profile_path=""
key_path=""
original_keychains="$(security list-keychains -d user | tr -d '"')"

cleanup() {
  if [[ -n "$profile_path" ]]; then rm -f "$profile_path"; fi
  if [[ -n "$key_path" ]]; then rm -f "$key_path"; fi
  security delete-keychain "$keychain" || true
  # Restore only this job's original keychain search list.
  local restored=()
  while IFS= read -r line; do
    line="$(echo "$line" | xargs)"
    if [[ -n "$line" ]]; then restored+=("$line"); fi
  done <<< "$original_keychains"
  if [[ ${#restored[@]} -gt 0 ]]; then security list-keychains -d user -s "${restored[@]}"; fi
  rm -f "$work/certificate.p12" "$work/profile.mobileprovision" "$work/profile.plist" \
    "$work/ExportOptions.plist"
  rmdir "$work" 2>/dev/null || true
}
trap cleanup EXIT

printf '%s' "$DISTRIBUTION_CERTIFICATE_BASE64" | base64 --decode > "$work/certificate.p12"
printf '%s' "$PROVISIONING_PROFILE_BASE64" | base64 --decode > "$work/profile.mobileprovision"
security cms -D -i "$work/profile.mobileprovision" > "$work/profile.plist"
profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print UUID' "$work/profile.plist")"
profile_name="$(/usr/libexec/PlistBuddy -c 'Print Name' "$work/profile.plist")"
export EXPORT_OPTIONS="$work/ExportOptions.plist"
python3 .github/scripts/validate-profile.py \
  --profile "$work/profile.plist" \
  --team-id "$APPLE_TEAM_ID" \
  --bundle-id "$APP_BUNDLE_ID" \
  --native-push "${ENABLE_NATIVE_PUSH:-false}" \
  --export-options "$EXPORT_OPTIONS"

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/certificate.p12" -P "$DISTRIBUTION_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security -t cert -f pkcs12 -k "$keychain"
identity="$(security find-identity -v -p codesigning "$keychain" | sed -n 's/.*"\(Apple Distribution:.*\)".*/\1/p')"
if [[ -z "$identity" || "$identity" == *$'\n'* ]]; then
  echo "::error::Expected one valid Apple Distribution signing identity."
  exit 1
fi
mask_value "$identity"
identity_name="${identity#Apple Distribution: }"
identity_name="${identity_name% ($APPLE_TEAM_ID)}"
mask_value "$identity_name"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain"
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
profile_path="$HOME/Library/MobileDevice/Provisioning Profiles/$profile_uuid.mobileprovision"
cp "$work/profile.mobileprovision" "$profile_path"

xcodebuild \
  -project FrigateHorizon.xcodeproj -scheme FrigateHorizon \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/FrigateHorizon.xcarchive \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Distribution" \
  PROVISIONING_PROFILE_SPECIFIER="$profile_name" \
  archive

xcodebuild -exportArchive -archivePath build/FrigateHorizon.xcarchive \
  -exportPath build/export -exportOptionsPlist "$EXPORT_OPTIONS"

mkdir -p "$HOME/.appstoreconnect/private_keys"
key_path="$HOME/.appstoreconnect/private_keys/AuthKey_$APP_STORE_CONNECT_KEY_ID.p8"
printf '%s' "$APP_STORE_CONNECT_PRIVATE_KEY" > "$key_path"
chmod 600 "$key_path"
ipa="$(find build/export -maxdepth 1 -name '*.ipa' -print -quit)"
if [[ -z "$ipa" ]]; then echo "::error::Archive export produced no IPA."; exit 1; fi
xcrun altool --upload-app -f "$ipa" -t ios \
  --apiKey "$APP_STORE_CONNECT_KEY_ID" --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"

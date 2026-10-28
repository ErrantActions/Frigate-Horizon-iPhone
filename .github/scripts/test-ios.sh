#!/bin/bash
set -euo pipefail

mkdir -p build
result_bundle="${IOS_RESULT_BUNDLE_PATH:-build/Tests.xcresult}"
mkdir -p "$(dirname "$result_bundle")"
devices="$(xcrun simctl list devices available --json)"
device_id="$(DEVICE_LIST="$devices" node --input-type=module -e '
const devices = JSON.parse(process.env.DEVICE_LIST).devices;
const iphones = Object.entries(devices)
  .filter(([runtime]) => runtime.includes("iOS"))
  .sort(([a], [b]) => b.localeCompare(a, undefined, { numeric: true }))
  .flatMap(([, items]) => items)
  .filter(device => device.isAvailable && device.name.startsWith("iPhone"));
const selected = process.env.REQUIRE_DUO === "true"
  ? iphones.find(device => device.name.includes("Duo"))
  : iphones[0];
if (!selected) {
  console.error("No suitable iPhone simulator is installed. Duo builds require an iPhone Duo simulator.");
  process.exit(1);
}
console.error(`Testing on ${selected.name}`);
console.log(selected.udid);
')"
xcodebuild \
  -project FrigateHorizon.xcodeproj \
  -scheme FrigateHorizon \
  -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath build/DerivedData \
  -resultBundlePath "$result_bundle" \
  CODE_SIGNING_ALLOWED=NO \
  test

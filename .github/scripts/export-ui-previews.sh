#!/bin/bash
set -euo pipefail

if [[ ! -f build/Tests.xcresult/Info.plist ]]; then
  echo "::notice::No completed native test result bundle is available to export."
  exit 0
fi

xcrun xcresulttool export attachments --path build/Tests.xcresult --output-path build/UISnapshots

#!/bin/bash
set -euo pipefail

if [[ ! -d build/Tests.xcresult ]]; then
  echo "::notice::No native test result bundle is available to export."
  exit 0
fi

xcrun xcresulttool export attachments --path build/Tests.xcresult --output-path build/UISnapshots

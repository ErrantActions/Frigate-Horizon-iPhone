#!/bin/bash
set -euo pipefail

offset="${BUILD_NUMBER_OFFSET:-1000}"
if [[ ! "$offset" =~ ^[0-9]{1,4}$ || ! "${GITHUB_RUN_NUMBER:-}" =~ ^[1-9][0-9]{0,3}$ ]]; then
  echo "::error::Build offset and workflow run number must be bounded nonnegative integers."
  exit 1
fi

number=$(( 10#$offset + 10#$GITHUB_RUN_NUMBER ))
if (( number > 9999 )); then
  echo "::error::Build number exceeds 9999. Review the marketing version and numbering policy before uploading."
  exit 1
fi
printf 'BUILD_NUMBER=%s\n' "$number" >> "${GITHUB_ENV:?Missing GitHub environment file}"
echo "Selected TestFlight build number: $number"

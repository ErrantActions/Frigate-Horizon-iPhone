#!/bin/bash
set -euo pipefail

if [[ ! "${USAGE_STARTED_AT:-}" =~ ^[0-9]+$ || ! "${USAGE_TIMEOUT_MINUTES:-}" =~ ^[0-9]+$ ]]; then
  echo "::error::Run usage requires numeric start time and timeout."
  exit 1
fi

elapsed=$(( $(date +%s) - USAGE_STARTED_AT ))
if (( elapsed < 0 )); then
  echo "::error::Run usage start time is in the future."
  exit 1
fi
rounded_minutes=$(( (elapsed + 59) / 60 ))

{
  echo "## macOS run usage"
  echo
  echo "| Item | Value |"
  echo "| --- | --- |"
  echo "| Runner label | ${USAGE_RUNNER:?Missing runner label} |"
  echo "| Result before reporting | ${USAGE_RESULT:?Missing job result} |"
  echo "| Elapsed since first step | ${elapsed} seconds |"
  echo "| Rounded-up elapsed | ${rounded_minutes} minutes |"
  echo "| Job timeout | ${USAGE_TIMEOUT_MINUTES} minutes |"
  echo
  echo "Runtime is an estimate, not billed minutes or a dollar charge. Setup/teardown,"
  echo "runner pricing, included usage, rounding, and storage can change the invoice."
  echo "Check GitHub Billing for actual spend. Timeout/cancellation can prevent this"
  echo "summary from running; GitHub's job duration remains available."
} | tee -a "${GITHUB_STEP_SUMMARY:?Missing GitHub step summary path}"

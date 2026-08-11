#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tiro-acceptance.log"

if "$ROOT/scripts/test_all.sh" 2>&1 | tee "$LOG"; then
    exit 0
fi

failures="$(
    grep -E '✘|recorded an issue|Expectation failed|Caught error|error:' "$LOG" \
        | tail -80 || true
)"
failure_summary="${failures:-$(tail -40 "$LOG")}"
{
    echo "### Acceptance failure"
    echo '```text'
    printf '%s\n' "$failure_summary"
    echo '```'
    echo "### End of log"
    echo '```text'
    tail -80 "$LOG"
    echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

message="$failure_summary"
message="${message//'%'/'%25'}"
message="${message//$'\r'/'%0D'}"
message="${message//$'\n'/'%0A'}"
printf '::error title=Acceptance suite failed::%s\n' "$message"
exit 1

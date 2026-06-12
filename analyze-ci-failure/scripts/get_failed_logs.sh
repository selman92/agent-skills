#!/usr/bin/env bash
# Extract trimmed logs for failed jobs of a GitHub Actions run.
# Usage: get_failed_logs.sh OWNER/REPO RUN_ID [OUTPUT_DIR]
#
# Writes one trimmed log file per failed job to OUTPUT_DIR and prints a summary.
# Trimming strategy: keep lines around error markers plus the tail of each failed
# step, so the agent reads kilobytes instead of megabytes.
#
# Rollup/aggregator jobs (whose log is only "::error::<job>: failure" lines) are
# flagged in the summary so the agent knows to look upstream instead.

set -euo pipefail

REPO="${1:?Usage: get_failed_logs.sh OWNER/REPO RUN_ID [OUTPUT_DIR]}"
RUN_ID="${2:?Usage: get_failed_logs.sh OWNER/REPO RUN_ID [OUTPUT_DIR]}"
OUT="${3:-/tmp/ci-diagnosis-$RUN_ID}"
mkdir -p "$OUT"

# Error markers worth keeping context around (case-insensitive where sensible).
# Covers generic CI markers (##[error]), JS/Python/Go/Swift frameworks, and .NET
# test output (vstest "Error Message:", TRX timeout aborts, NUnit/Reqnroll/MSTest).
MARKERS='(^|[^a-zA-Z])(error|FAIL(ED|URE)?|✕|✗|⛔|AssertionError|Expected|Exception|Traceback|panic:|fatal:|XCTAssert|Test Case .* failed|##\[error\]|Error Message:|Stack Trace:|Aborting test run|Test Run Failed|timed? ?out)'

echo "Failed jobs for run $RUN_ID in $REPO:" >&2

gh run view "$RUN_ID" -R "$REPO" --json jobs \
  -q '.jobs[] | select(.conclusion=="failure") | "\(.databaseId)\t\(.name)"' |
while IFS=$'\t' read -r JOB_ID JOB_NAME; do
  SAFE_NAME=$(echo "$JOB_NAME" | tr -cs '[:alnum:]._-' '_' | cut -c1-80)
  RAW="$OUT/raw-$JOB_ID.log"
  TRIMMED="$OUT/job-$SAFE_NAME-$JOB_ID.log"

  # Per-job logs; fall back gracefully if logs expired.
  if ! gh api "repos/$REPO/actions/jobs/$JOB_ID/logs" > "$RAW" 2>/dev/null; then
    echo "  - $JOB_NAME (job $JOB_ID): LOGS UNAVAILABLE (expired?)" >&2
    echo "LOGS UNAVAILABLE for job $JOB_NAME ($JOB_ID) — use check-run annotations instead." > "$TRIMMED"
    continue
  fi

  TOTAL=$(wc -l < "$RAW")

  # Detect rollup/aggregator jobs: every ::error:: line is "<job-name>: <result>".
  ERR_LINES=$(grep -c '##\[error\]' "$RAW" || true)
  ROLLUP_LINES=$(grep -cE '##\[error\][a-zA-Z0-9_-]+: (failure|cancelled|skipped)\s*$' "$RAW" || true)
  ROLLUP_NOTE=""
  if [ "$ERR_LINES" -gt 0 ] && [ "$ERR_LINES" -eq "$ROLLUP_LINES" ]; then
    ROLLUP_NOTE=" [ROLLUP JOB — only aggregates upstream results; real failure is in the jobs named in its ::error:: lines]"
  fi

  {
    echo "===== Job: $JOB_NAME (id $JOB_ID, $TOTAL log lines total; trimmed)$ROLLUP_NOTE ====="
    # 1) Lines matching error markers, with context, capped.
    grep -i -E -B2 -A8 "$MARKERS" "$RAW" | head -n 500 || true
    echo
    echo "===== Tail of job log (last 120 lines) ====="
    tail -n 120 "$RAW"
  } > "$TRIMMED"
  rm -f "$RAW"

  echo "  - $JOB_NAME (job $JOB_ID)$ROLLUP_NOTE -> $TRIMMED" >&2
done

echo >&2
echo "Trimmed logs written to: $OUT" >&2
echo "Tip: test-result artifacts (TRX/JUnit XML) are more precise than logs:" >&2
echo "  gh api repos/$REPO/actions/runs/$RUN_ID/artifacts -q '.artifacts[].name'" >&2

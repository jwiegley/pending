#!/usr/bin/env bash
# Run ERT under undercover.el and emit coverage.lcov.
# Fails if coverage drops below the recorded baseline in
# .coverage-baseline.
set -euo pipefail
cd "$(dirname "$0")/.."

# Baseline file (line coverage percentage as a single integer 0-100).
BASELINE_FILE=.coverage-baseline
BASELINE=${BASELINE:-$(cat "$BASELINE_FILE" 2>/dev/null || echo 0)}

# Tell undercover not to wait for an external service to acknowledge.
export UNDERCOVER_FORCE=true

# undercover.el can't instrument byte-compiled .elc files; drop them
# so the load picks up the .el sources. Also drop any prior report so
# undercover doesn't try (and fail) to merge.
rm -f pending.elc pending-test.elc coverage.lcov

emacs --batch -L . \
  --eval "(require 'package)" \
  --eval "(package-initialize)" \
  --eval "(require 'undercover)" \
  --eval "(undercover \"pending.el\" (:report-file \"./coverage.lcov\") (:report-format 'lcov) (:send-report nil))" \
  -l pending-test.el \
  -f ert-run-tests-batch-and-exit

# Extract line coverage from lcov.
if [ -f coverage.lcov ]; then
  COVERED=$(grep -c '^DA:[0-9]*,[1-9]' coverage.lcov || true)
  TOTAL=$(grep -c '^DA:' coverage.lcov || true)
  COVERED=${COVERED:-0}
  TOTAL=${TOTAL:-0}
  if [ "$TOTAL" -le 0 ]; then
    echo "coverage: no DA records in coverage.lcov" >&2
    exit 1
  fi
  PCT=$((COVERED * 100 / TOTAL))
  echo "coverage: $PCT% ($COVERED/$TOTAL lines)"
  if [ "$PCT" -lt "$BASELINE" ]; then
    echo "coverage: REGRESSION ($PCT% < baseline $BASELINE%)" >&2
    exit 1
  fi
  # Update baseline if improved.
  if [ "$PCT" -gt "$BASELINE" ]; then
    echo "$PCT" >"$BASELINE_FILE"
    echo "coverage: baseline raised to $PCT%"
  fi
else
  echo "coverage: no coverage.lcov produced" >&2
  exit 1
fi

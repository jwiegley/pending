#!/usr/bin/env bash
# Microbenchmark suite. Runs each benchmark NRUNS times and compares
# the minimum (least-noisy estimate) against the recorded baseline.
# Fails if any min ratio (new/baseline) exceeds PERF_THRESHOLD
# (default 1.20). Microbenchmarks on a multitasking host are noisy;
# `min` plus a generous threshold suppresses sporadic OS-load
# transients without hiding actual regressions.
set -euo pipefail
cd "$(dirname "$0")/.."

BASELINE_FILE=.perf-baseline
NRUNS=${NRUNS:-3}
THRESHOLD=${PERF_THRESHOLD:-1.20}

# Empty the per-run report; each pass appends to it.
: >./profile-report-runs.txt

run_once() {
  emacs --batch -L . -l pending.el --eval "
(let* ((iters 1000)
       (suite
        (list
         (cons 'make-and-resolve
               (lambda ()
                 (with-temp-buffer
                   (let ((p (pending-make (current-buffer) :label \"x\")))
                     (pending-resolve p \"y\")))))
         (cons 'gen-id
               (lambda () (pending--gen-id)))
         (cons 'render-bar-eighths
               (lambda () (pending--render-bar 0.5 16)))
         (cons 'eta-fraction
               (lambda () (pending--eta-fraction 0.0 8.0 5.0)))))
       (results
        (mapcar (lambda (entry)
                  (let* ((name (car entry))
                         (fn (cdr entry))
                         (run (benchmark-run iters (funcall fn))))
                    (cons name (car run))))
                suite)))
  (dolist (r results)
    (princ (format \"%-24s %.6f\n\" (car r) (cdr r)))))
"
}

for _ in $(seq 1 "$NRUNS"); do
  run_once >>./profile-report-runs.txt
done

# Reduce to per-name minimum across runs and write the aggregated report.
python3 - <<EOF >./profile-report.txt
mins = {}
with open("./profile-report-runs.txt") as f:
    for line in f:
        parts = line.split()
        if len(parts) >= 2:
            name, t = parts[0], float(parts[1])
            if name not in mins or t < mins[name]:
                mins[name] = t
for name, t in mins.items():
    print(f"{name:<24} {t:.6f}")
EOF
cat ./profile-report.txt

# Compare against baseline if present.
if [ -f "$BASELINE_FILE" ]; then
  python3 - "$THRESHOLD" <<'EOF'
import sys
threshold = float(sys.argv[1])
def parse(path):
    out = {}
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                out[parts[0]] = float(parts[1])
    return out
base = parse(".perf-baseline")
curr = parse("./profile-report.txt")
worst = 1.0
for k, v in curr.items():
    if k in base and base[k] > 0:
        ratio = v / base[k]
        marker = "*" if ratio > threshold else " "
        print(f" {marker} {k:24s} {base[k]:.6f} -> {v:.6f} (x{ratio:.2f})")
        if ratio > worst:
            worst = ratio
if worst > threshold:
    print(f"profile: REGRESSION (worst x{worst:.2f} > {threshold})", file=sys.stderr)
    sys.exit(1)
print(f"profile: OK (worst x{worst:.2f}, threshold {threshold})")
EOF
else
  cp profile-report.txt "$BASELINE_FILE"
  echo "profile: baseline initialized"
fi

#!/usr/bin/env bash
# Microbenchmark suite. Fails if the median ratio (new/baseline) > 1.05.
set -euo pipefail
cd "$(dirname "$0")/.."

BASELINE_FILE=.perf-baseline

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
  (with-temp-file \"./profile-report.txt\"
    (dolist (r results)
      (insert (format \"%-24s %.6f\\n\" (car r) (cdr r)))))
  (princ (with-temp-buffer (insert-file-contents \"./profile-report.txt\") (buffer-string))))
"

# Compare against baseline if present.
if [ -f "$BASELINE_FILE" ]; then
  python3 - <<EOF
import sys
def parse(path):
    out = {}
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                out[parts[0]] = float(parts[1])
    return out
base = parse("$BASELINE_FILE")
curr = parse("./profile-report.txt")
worst = 1.0
for k, v in curr.items():
    if k in base and base[k] > 0:
        ratio = v / base[k]
        marker = "*" if ratio > 1.05 else " "
        print(f" {marker} {k:24s} {base[k]:.6f} -> {v:.6f} (x{ratio:.2f})")
        if ratio > worst:
            worst = ratio
if worst > 1.05:
    print(f"profile: REGRESSION (worst x{worst:.2f} > 1.05)", file=sys.stderr)
    sys.exit(1)
print(f"profile: OK (worst x{worst:.2f})")
EOF
else
  cp profile-report.txt "$BASELINE_FILE"
  echo "profile: baseline initialized"
fi

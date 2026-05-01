#!/usr/bin/env bash
# Fail if `make format` would change any tracked .el file.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! git diff --quiet HEAD -- '*.el'; then
  echo "format-check: working tree has uncommitted .el changes; commit/stash first" >&2
  exit 2
fi
make format >/dev/null
if ! git diff --quiet HEAD -- '*.el'; then
  echo "format-check: indent-region produced changes --- run 'make format' and commit" >&2
  git diff --stat -- '*.el' >&2
  git checkout -- '*.el'
  exit 1
fi
echo "format-check: OK"

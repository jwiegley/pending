#!/usr/bin/env bash
# Fail if `make format` would change any tracked .el file.
#
# We snapshot the .el files first, run `make format` (which rewrites
# in place), diff against the snapshot, then restore the snapshot
# unconditionally.  This works whether the working tree is clean,
# has staged changes (pre-commit hook), or has unstaged changes.
set -euo pipefail
cd "$(dirname "$0")/.."

snap="$(mktemp -d)"
trap 'rm -rf "$snap"' EXIT

# Snapshot every tracked .el file at its current on-disk content.
mapfile -t files < <(git ls-files '*.el')
for f in "${files[@]}"; do
  mkdir -p "$snap/$(dirname "$f")"
  cp "$f" "$snap/$f"
done

make format >/dev/null

rc=0
for f in "${files[@]}"; do
  if ! diff -q "$snap/$f" "$f" >/dev/null; then
    echo "format-check: $f differs after 'make format'" >&2
    diff -u "$snap/$f" "$f" >&2 || true
    rc=1
  fi
done

# Restore the snapshot unconditionally so we never leave the tree
# changed under the user.
for f in "${files[@]}"; do
  cp "$snap/$f" "$f"
done

if [ "$rc" -ne 0 ]; then
  echo "format-check: run 'make format' and commit the result" >&2
  exit 1
fi

echo "format-check: OK"

#!/usr/bin/env bash
# Run every test suite: all Dart packages + the Rust decode crate.
# Usage: test.sh [package-name ...]   e.g. `test.sh aval_format aval_decode`
set -euo pipefail

FLUTTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
only=("$@")
failed=()

want() {
  [ ${#only[@]} -eq 0 ] && return 0
  for o in "${only[@]}"; do [ "$o" = "$1" ] && return 0; done
  return 1
}

for pkg in "$FLUTTER_DIR"/packages/*/; do
  [ -f "$pkg/pubspec.yaml" ] || continue
  [ -d "$pkg/test" ] || continue
  name="$(basename "$pkg")"
  want "$name" || continue
  echo "==> dart test: $name"
  (cd "$pkg" && dart test) || failed+=("$name")
done

for crate in "$FLUTTER_DIR"/rust/*/; do
  [ -f "$crate/Cargo.toml" ] || continue
  name="$(basename "$crate")"
  want "$name" || continue
  echo "==> cargo test: $name"
  (cd "$crate" && cargo test) || failed+=("$name")
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "TESTS FAILED: ${failed[*]}" >&2
  exit 1
fi
echo "all test suites green"

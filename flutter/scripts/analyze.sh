#!/usr/bin/env bash
# Static analysis across all Dart packages and the Rust crate (clippy).
set -euo pipefail

FLUTTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=()

for pkg in "$FLUTTER_DIR"/packages/*/; do
  [ -f "$pkg/pubspec.yaml" ] || continue
  name="$(basename "$pkg")"
  echo "==> dart analyze: $name"
  (cd "$pkg" && dart analyze) || failed+=("$name")
done

for crate in "$FLUTTER_DIR"/rust/*/; do
  [ -f "$crate/Cargo.toml" ] || continue
  name="$(basename "$crate")"
  echo "==> cargo clippy: $name"
  (cd "$crate" && cargo clippy --all-targets -- -D warnings) || failed+=("$name")
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "ANALYSIS FAILED: ${failed[*]}" >&2
  exit 1
fi
echo "all packages analyze clean"

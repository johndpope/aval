#!/usr/bin/env bash
# Fetch dependencies for every Dart package and the Rust crate.
set -euo pipefail

FLUTTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for pkg in "$FLUTTER_DIR"/packages/*/; do
  [ -f "$pkg/pubspec.yaml" ] || continue
  echo "==> dart pub get: $(basename "$pkg")"
  (cd "$pkg" && dart pub get)
done

for crate in "$FLUTTER_DIR"/rust/*/; do
  [ -f "$crate/Cargo.toml" ] || continue
  echo "==> cargo fetch: $(basename "$crate")"
  (cd "$crate" && cargo fetch)
done

echo "setup complete"

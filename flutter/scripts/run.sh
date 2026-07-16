#!/usr/bin/env bash
# Build the Rust decode core, then run a Flutter example app.
# Usage: run.sh [example] [flutter-run-args...]
#   run.sh                          # default example (grass_rabbit) on macOS
#   run.sh grass_rabbit -d macos    # explicit device
set -euo pipefail

FLUTTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="${1:-grass_rabbit}"
shift || true

EXAMPLE_DIR="$FLUTTER_DIR/examples/$EXAMPLE"
if [ ! -d "$EXAMPLE_DIR" ]; then
  echo "unknown example '$EXAMPLE' — available:" >&2
  ls "$FLUTTER_DIR/examples" 2>/dev/null >&2 || echo "  (none yet)" >&2
  exit 1
fi

echo "==> cargo build --release: aval_decode"
(cd "$FLUTTER_DIR/rust/aval_decode" && cargo build --release)

case "$(uname -s)" in
  Darwin) LIB_NAME="libaval_decode.dylib" ;;
  Linux)  LIB_NAME="libaval_decode.so" ;;
  *)      LIB_NAME="aval_decode.dll" ;;
esac
export AVAL_DECODE_LIB="$FLUTTER_DIR/rust/aval_decode/target/release/$LIB_NAME"
[ -f "$AVAL_DECODE_LIB" ] || { echo "missing $AVAL_DECODE_LIB" >&2; exit 1; }

DEVICE_ARGS=()
case "$*" in *"-d "*) ;; *) [ "$(uname -s)" = Darwin ] && DEVICE_ARGS=(-d macos) ;; esac

echo "==> flutter run: $EXAMPLE (AVAL_DECODE_LIB=$AVAL_DECODE_LIB)"
cd "$EXAMPLE_DIR"
flutter pub get
exec flutter run "${DEVICE_ARGS[@]}" --dart-define=AVAL_DECODE_LIB="$AVAL_DECODE_LIB" "$@"

#!/usr/bin/env bash
# Build the Rust decode core, then run a Flutter example app.
# Usage: run.sh [example] [flutter-run-args...]
#   run.sh                                    # grass_rabbit on macOS
#   run.sh grass_rabbit -d macos              # explicit macOS
#   run.sh grass_rabbit -d ios                # first available iOS simulator
#   run.sh grass_rabbit -d "iPhone 17 Pro"    # named simulator
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

# Detect target device from remaining args (before we may inject -d).
DEVICE_HINT=""
ARGS=("$@")
for ((i = 0; i < ${#ARGS[@]}; i++)); do
  if [ "${ARGS[$i]}" = "-d" ] || [ "${ARGS[$i]}" = "--device-id" ]; then
    DEVICE_HINT="${ARGS[$((i + 1))]:-}"
    break
  fi
done

# Default to macOS on Darwin when no -d is given.
if [ -z "$DEVICE_HINT" ] && [ "$(uname -s)" = Darwin ]; then
  ARGS=(-d macos "${ARGS[@]}")
  DEVICE_HINT="macos"
fi

# Choose Rust triple + library name for the host or iOS simulator.
RUST_TARGET=""
LIB_NAME=""
case "$DEVICE_HINT" in
  macos|"")
    case "$(uname -s)" in
      Darwin) LIB_NAME="libaval_decode.dylib" ;;
      Linux)  LIB_NAME="libaval_decode.so" ;;
      *)      LIB_NAME="aval_decode.dll" ;;
    esac
    ;;
  ios|iPhone*|iPad*|simulator|iphone*|ipad*)
    # Apple Silicon Macs → arm64 sim; Intel → x86_64 sim.
    if [ "$(uname -m)" = arm64 ]; then
      RUST_TARGET="aarch64-apple-ios-sim"
    else
      RUST_TARGET="x86_64-apple-ios"
    fi
    LIB_NAME="libaval_decode.dylib"
    ;;
  *)
    # Unknown device id: try to resolve via flutter devices later; default host lib.
    case "$(uname -s)" in
      Darwin) LIB_NAME="libaval_decode.dylib" ;;
      Linux)  LIB_NAME="libaval_decode.so" ;;
      *)      LIB_NAME="aval_decode.dll" ;;
    esac
    # If it looks like an iOS sim UDID / name, prefer ios-sim triple.
    if [[ "$DEVICE_HINT" == *iPhone* || "$DEVICE_HINT" == *iPad* || "$DEVICE_HINT" == *Simulator* ]]; then
      if [ "$(uname -m)" = arm64 ]; then
        RUST_TARGET="aarch64-apple-ios-sim"
      else
        RUST_TARGET="x86_64-apple-ios"
      fi
    fi
    ;;
esac

if [ -n "$RUST_TARGET" ]; then
  echo "==> cargo build --release --target $RUST_TARGET: aval_decode"
  (cd "$FLUTTER_DIR/rust/aval_decode" && cargo build --release --target "$RUST_TARGET")
  export AVAL_DECODE_LIB="$FLUTTER_DIR/rust/aval_decode/target/$RUST_TARGET/release/$LIB_NAME"
else
  echo "==> cargo build --release: aval_decode"
  (cd "$FLUTTER_DIR/rust/aval_decode" && cargo build --release)
  export AVAL_DECODE_LIB="$FLUTTER_DIR/rust/aval_decode/target/release/$LIB_NAME"
fi

[ -f "$AVAL_DECODE_LIB" ] || { echo "missing $AVAL_DECODE_LIB" >&2; exit 1; }

# Ad-hoc sign so the simulator / macOS can dlopen the cargo artifact.
if [ "$(uname -s)" = Darwin ] && [[ "$AVAL_DECODE_LIB" == *.dylib ]]; then
  codesign -s - --force "$AVAL_DECODE_LIB" >/dev/null 2>&1 || true
fi

# Boot an iOS simulator when targeting ios / a named phone / iPad, and rewrite
# -d ios to a concrete UDID (flutter does not accept the bare "ios" id).
case "$DEVICE_HINT" in
  ios|iPhone*|iPad*|iphone*|ipad*|simulator)
    pick_sim_udid() {
      # Prefer already-booted iPhone.
      local udid
      udid="$(xcrun simctl list devices booted 2>/dev/null | \
        awk -F '[()]' '/iPhone / {print $2; exit}')"
      if [ -n "$udid" ]; then
        echo "$udid"
        return
      fi
      for pattern in 'iPhone 17 Pro (' 'iPhone 16 Pro (' 'iPhone 17 (' 'iPhone 16 (' 'iPhone '; do
        udid="$(xcrun simctl list devices available 2>/dev/null | \
          awk -F '[()]' -v p="$pattern" 'index($0, p) {print $2; exit}')"
        if [ -n "$udid" ]; then
          echo "$udid"
          return
        fi
      done
    }

    SIM_UDID="$(pick_sim_udid)"
    if [ -z "$SIM_UDID" ]; then
      echo "no iOS simulator found" >&2
      exit 1
    fi

    if ! xcrun simctl list devices booted 2>/dev/null | grep -q "$SIM_UDID"; then
      echo "==> booting simulator $SIM_UDID"
      xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
    fi
    open -a Simulator 2>/dev/null || true

    # If the user passed -d ios (or a loose name), pin to the concrete UDID.
    if [ "$DEVICE_HINT" = "ios" ] || [ "$DEVICE_HINT" = "simulator" ]; then
      NEW_ARGS=()
      for ((i = 0; i < ${#ARGS[@]}; i++)); do
        if [ "${ARGS[$i]}" = "-d" ] || [ "${ARGS[$i]}" = "--device-id" ]; then
          NEW_ARGS+=("${ARGS[$i]}" "$SIM_UDID")
          i=$((i + 1))
          continue
        fi
        NEW_ARGS+=("${ARGS[$i]}")
      done
      ARGS=("${NEW_ARGS[@]}")
      DEVICE_HINT="$SIM_UDID"
    fi
    ;;
esac

echo "==> flutter run: $EXAMPLE (AVAL_DECODE_LIB=$AVAL_DECODE_LIB)"
cd "$EXAMPLE_DIR"
flutter pub get
exec flutter run "${ARGS[@]}" --dart-define=AVAL_DECODE_LIB="$AVAL_DECODE_LIB"

# grass_rabbit (Flutter, macOS)

The first **runnable** Flutter example of the AVAL port. It proves the
Phase 3 exit criterion — a live Dart↔Rust FFI decode round-trip — and shows
real decoded frames looping while the pure-Dart state graph reacts to hover.

What it does, end to end:

1. **Loads** `assets/grass-rabbit.avl` as a bundled Flutter asset.
   > This file is a **copy** of the web example's asset,
   > `examples/grass-rabbit/public/grass-rabbit.avl` (1.13 MB). Keep them in sync
   > if the source asset is regenerated.
2. **Parses** it with `package:aval_format` (`parseFrontIndex`): header,
   JSON manifest, and the fixed-record access-unit index.
3. **Installs** the parsed graph into `aval_graph`'s `MotionGraphEngine`
   (`install` → `beginAnimated`) and surfaces the state names + current state.
4. **Decodes** all five units (`intro`, `idle-loop`, `hover-in`, `hover-loop`,
   `hover-out` — 311 access units total) through the Rust `aval_decode` core via
   **hand-written `dart:ffi`** bindings (`lib/src/aval_ffi.dart`, a 1:1 mirror of
   `rust/aval_decode/src/ffi.rs`): per unit, `configure` → `activate_generation`
   → per-AU `submit_access_unit` / `take_frame` / `release_frame`. Each RGBA
   buffer becomes a `ui.Image`, bucketed by unit id.
5. **Displays** the frames graph-driven, painted by a Ticker-driven
   `CustomPainter` gated to the manifest frame rate (24 fps), `BoxFit.contain`.
   The displayed unit follows the graph state: `intro` on start, then
   `idle → idle-loop` (loop), `entering → hover-in` (finite, holds last frame),
   `hover → hover-loop` (loop), `exiting → hover-out` (finite). Hovering makes the
   rabbit actually hop in — the rabbit is authored into the hover units, not idle.
6. **Reacts to hover**: a `MouseRegion` over the video sends
   `hover.enter` / `hover.leave` to the graph; the label shows the committed
   `visualState` and, while a transition is pending, the `requestedState`
   (`idle → entering → hover → exiting`).

## Run

From `flutter/`:

```sh
./scripts/run.sh                 # builds aval_decode, then flutter run -d macos
# or explicitly:
./scripts/run.sh grass_rabbit -d macos
```

The runner builds the Rust dylib (`cargo build --release`) and passes its
absolute path via `--dart-define=AVAL_DECODE_LIB=<abs path>`. The Dart side reads
it with `String.fromEnvironment('AVAL_DECODE_LIB')` and falls back to
`../../rust/aval_decode/target/release/libaval_decode.dylib` (relative to this
example dir) when the define is absent.

## Verifying without a display

```sh
# Full FFI decode round-trip (Phase 3 proof), headless:
AVAL_DECODE_LIB=<abs path> dart run tool/decode_check.dart
# Manifest / access-unit inspection:
dart run tool/inspect.dart
# Parse + graph-reaction + widget smoke tests:
flutter test
# The macOS build (exit criterion):
flutter build macos --debug --dart-define=AVAL_DECODE_LIB=<abs path>
```

## macOS sandbox

`com.apple.security.app-sandbox` is set to **`false`** in both
`macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`.
A sandboxed macOS app may only `dlopen()` libraries from inside its own
`.app` bundle. This milestone loads the freshly-built cargo artifact from an
**arbitrary absolute path** in the repo tree (the one passed via
`--dart-define`), which the sandbox would block. A production build would bundle
the dylib inside the app and re-enable the sandbox; that packaging (cargokit /
flutter_rust_bridge) is a later phase.

## Known simplifications (this milestone)

- **Opaque asset, no packed-alpha unpack.** `grass-rabbit.avl`'s rendition is
  `avc-annexb-opaque-v1` (`AvcOpaqueRenditionV01`, coded 1280×720) — a plain
  opaque video with **no** alpha pane. The packed-alpha vertical-stacking
  layout (color / 8 px gutter / alpha) described in ARCHITECTURE.md §3.1 does
  **not** apply to this asset, so no CPU unpack or premultiply is performed; the
  decoded RGBA (alpha = 255 from the Rust core) is displayed directly. The full
  packed-alpha `FragmentProgram` shader is a later phase.
- **Graph-driven unit playback is an approximation, not frame-accurate.** The
  displayed unit follows `visualState` (see step 5), and the unit-local frame
  counter is reset whenever the unit changes. This is *not* the true Phase 7–8
  portal-frame-accurate scheduling (that arrives with `aval_player`): the switch
  happens when the graph commits the state, not at an exact authored portal
  frame, and the video's frame counter is independent of the graph's
  `presentation.frameIndex`. Good enough to see the rabbit hop in/out on hover;
  not certified frame parity.
- **Decode-ahead / frame-credit streaming not used.** All 311 frames (across all
  five units) are decoded up front into `ui.Image`s, one decoder session per unit
  (each native frame released synchronously right after the copy). The Rust
  `FrameCreditLedger` is exercised but never stressed. Phase 5 wires streaming
  decode-ahead.
- **`NativeFinalizer` is on the session, not per frame.** `aval_decode_release_frame`
  takes two arguments (handle + frame_id) and so cannot serve as a single-token
  `NativeFinalizerFunction` callback; frames are released manually after copy.
  The `NativeFinalizer` is instead wired to `aval_decode_session_destroy`
  (single-pointer signature — exact ABI match) as a GC-safe backstop for the
  session handle. See `lib/src/aval_ffi.dart`.
- **macOS only.** Other platforms are out of scope for this milestone.
- **No `aval_player` dependency.** That package is under active development by
  another worker and is deliberately not depended on yet.

## Layout

```
lib/
  main.dart                  UI: Ticker, CustomPainter video, MouseRegion, state badge
  src/aval_ffi.dart          hand-written dart:ffi bindings for aval_decode's C ABI
  src/rabbit_controller.dart parse + FFI decode + graph orchestration
tool/
  inspect.dart               prints manifest / access-unit facts
  decode_check.dart          headless FFI decode round-trip proof
assets/grass-rabbit.avl      copy of the web example's asset
```

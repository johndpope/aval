/// Platform seam types referenced by the pure runtime contracts.
///
/// These stand in for browser/native objects that the TypeScript sources use
/// directly but that have no pure-Dart equivalent. They are declared here as
/// opaque interfaces so the pure `aval_player` package stays free of `dart:ui`
/// / `dart:html` / FFI dependencies; the concrete implementations live in the
/// platform-bound layer (`aval_flutter` / the decode adapter), per §6 of
/// `flutter/ARCHITECTURE.md`.
library;

/// Opaque handle to a decoded picture.
///
/// Mirrors the TypeScript `VideoFrame` DOM type used by
/// `decoder-worker/client-support.ts` and `protocol.ts`. In the port, the
/// decoded-frame buffer is owned by the platform decode backend (browser
/// `VideoFrame`, or native external typed data behind a `NativeFinalizer`), so
/// this package only ever holds it as an opaque reference.
abstract interface class VideoFrame {}

/// Cancellation seam mirroring the browser `AbortSignal`.
///
/// The path-scheduler family threads this through worker/decode calls to cancel
/// a superseded generation (§4 of `flutter/ARCHITECTURE.md` — the
/// cancellation token stays in Dart). Only the surface referenced by the
/// scheduler contracts is declared here.
abstract interface class AbortSignal {
  /// Whether the associated operation has already been aborted.
  bool get aborted;
}

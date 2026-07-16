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
/// cancellation token stays in Dart).
///
/// Extended (vs. the original Phase-2 frozen surface) with `reason` and the
/// `addEventListener`/`removeEventListener` seam that
/// `abortablePathSchedulerActivation` (path-scheduler-generation.ts:145-171)
/// requires. A pure-Dart [AbortController]/[DOMException] implementation is
/// provided below so the headless `aval_player` scheduler — and its tests — can
/// run without a browser or FFI backend.
abstract interface class AbortSignal {
  /// Whether the associated operation has already been aborted.
  bool get aborted;

  /// The reason the operation was aborted (a [DOMException] by default).
  Object? get reason;

  /// Registers [listener] for `type` (only `"abort"` is dispatched). When
  /// [once] is true the listener is removed after it first fires.
  void addEventListener(String type, void Function() listener, {bool once});

  /// Removes a previously-registered [listener] for `type`.
  void removeEventListener(String type, void Function() listener);
}

/// A cancellable operation token whose [signal] mirrors the browser
/// `AbortController`. Pure Dart — no platform dependency.
class AbortController {
  final _AbortSignal _signal = _AbortSignal();

  AbortSignal get signal => _signal;

  /// Aborts the associated [signal], defaulting to an `AbortError`
  /// [DOMException] when no explicit [reason] is supplied (browser parity).
  void abort([Object? reason]) {
    _signal._abort(
      reason ?? DOMException('signal aborted without an explicit reason',
          'AbortError'),
    );
  }
}

class _AbortSignal implements AbortSignal {
  bool _aborted = false;
  Object? _reason;
  final List<_AbortListener> _listeners = <_AbortListener>[];

  @override
  bool get aborted => _aborted;

  @override
  Object? get reason => _reason;

  @override
  void addEventListener(String type, void Function() listener,
      {bool once = false}) {
    if (type != 'abort') return;
    _listeners.add(_AbortListener(listener, once));
  }

  @override
  void removeEventListener(String type, void Function() listener) {
    if (type != 'abort') return;
    _listeners.removeWhere((entry) => identical(entry.listener, listener));
  }

  void _abort(Object reason) {
    if (_aborted) return;
    _aborted = true;
    _reason = reason;
    for (final entry in List<_AbortListener>.of(_listeners)) {
      if (entry.once) {
        _listeners.removeWhere((candidate) => identical(candidate, entry));
      }
      entry.listener();
    }
  }
}

class _AbortListener {
  _AbortListener(this.listener, this.once);

  final void Function() listener;
  final bool once;
}

/// Cancellation-error seam mirroring the browser `DOMException`.
///
/// The scheduler raises `DOMException("...", "AbortError")` when a generation
/// activation is superseded (path-scheduler.ts:767). Only the `name`/`message`
/// surface the runtime and tests observe is modelled.
class DOMException implements Exception {
  DOMException(this.message, this.name);

  final String message;
  final String name;

  @override
  String toString() => '$name: $message';
}

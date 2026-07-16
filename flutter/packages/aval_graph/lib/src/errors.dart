/// Machine-readable failure classification for [MotionGraphError].
///
/// Mirrors the TypeScript `MotionGraphErrorCode` string union. Each value
/// exposes [wireValue], the exact SCREAMING_SNAKE_CASE string used by the
/// original TypeScript package, for hosts that log or match on the code.
enum MotionGraphErrorCode {
  graphValidation('GRAPH_VALIDATION'),
  notReady('NOT_READY'),
  routeNotFound('ROUTE_NOT_FOUND'),
  inputOverflow('INPUT_OVERFLOW'),
  nonConsecutiveTick('NON_CONSECUTIVE_TICK'),
  playbackFallback('PLAYBACK_FALLBACK'),
  disposed('DISPOSED');

  const MotionGraphErrorCode(this.wireValue);

  /// The original TypeScript literal string for this code.
  final String wireValue;
}

/// Base error type thrown by the graph engine and its validator.
///
/// Mirrors the TypeScript `MotionGraphError` class. Dart exceptions are not
/// caught by default the way JavaScript errors can propagate uncaught, so
/// this implements [Exception] (rather than extending [Error]) to signal
/// that callers are expected to catch and handle it.
class MotionGraphError implements Exception {
  const MotionGraphError(this.code, this.message, {this.cause});

  final MotionGraphErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'MotionGraphError(${code.wireValue}): $message';
}

/// Thrown when an untrusted graph definition fails structural validation.
///
/// Mirrors the TypeScript `MotionGraphValidationError` class, which always
/// carries the `GRAPH_VALIDATION` code.
class MotionGraphValidationError extends MotionGraphError {
  const MotionGraphValidationError(String message, {Object? cause})
      : super(MotionGraphErrorCode.graphValidation, message, cause: cause);

  @override
  String toString() => 'MotionGraphValidationError: $message';
}

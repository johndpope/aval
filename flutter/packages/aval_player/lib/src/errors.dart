/// Bounded, sanitized runtime failure taxonomy.
///
/// Direct port of `packages/player-web/src/runtime/errors.ts`. The TypeScript
/// string-literal union `RuntimeFailureCode` becomes an enum whose [wireValue]
/// carries the exact literal; the frozen `RuntimeFailureContext` object becomes
/// an immutable value class. `Object.freeze`/`Object.defineProperties` on the
/// thrown error have no Dart analog and are dropped — [RuntimePlaybackError] is
/// simply an immutable [Exception]. The JS `Reflect`/hostile-accessor defenses
/// in `messageFrom` collapse to a plain type check, because Dart cannot invoke
/// a getter it did not declare.
library;

/// Maximum UTF-16 code units retained from a runtime failure message.
const int maxRuntimeFailureMessageLength = 512;

/// Maximum UTF-16 code units retained from one structured diagnostic string.
const int maxRuntimeDiagnosticTextLength = 128;

/// The closed set of runtime failure codes (`RUNTIME_FAILURE_CODES`).
enum RuntimeFailureCode {
  invalidAsset('invalid-asset'),
  loadFailure('load-failure'),
  rangeResponseInvalid('range-response-invalid'),
  entityChanged('entity-changed'),
  integrityMismatch('integrity-mismatch'),
  unsupportedProfile('unsupported-profile'),
  resourceRejection('resource-rejection'),
  readinessFailure('readiness-failure'),
  workerDecodeFailure('worker-decode-failure'),
  rendererFailure('renderer-failure'),
  contextLoss('context-loss'),
  watchdogTimeout('watchdog-timeout'),
  underflow('underflow'),
  abort('abort'),
  disposed('disposed');

  const RuntimeFailureCode(this.wireValue);

  final String wireValue;
}

const Map<RuntimeFailureCode, String> _defaultFailureMessages = {
  RuntimeFailureCode.invalidAsset: 'installed animation asset is invalid',
  RuntimeFailureCode.loadFailure: 'animation asset loading failed',
  RuntimeFailureCode.rangeResponseInvalid: 'animation range response is invalid',
  RuntimeFailureCode.entityChanged:
      'animation asset entity changed during loading',
  RuntimeFailureCode.integrityMismatch:
      'animation asset integrity did not match',
  RuntimeFailureCode.unsupportedProfile: 'AVC animation profile is unsupported',
  RuntimeFailureCode.resourceRejection: 'animation resource budget was rejected',
  RuntimeFailureCode.readinessFailure: 'animation readiness failed',
  RuntimeFailureCode.workerDecodeFailure: 'animation decoder worker failed',
  RuntimeFailureCode.rendererFailure: 'animation renderer failed',
  RuntimeFailureCode.contextLoss: 'animation rendering context was lost',
  RuntimeFailureCode.watchdogTimeout: 'animation watchdog expired',
  RuntimeFailureCode.underflow: 'animation presentation underflowed',
  RuntimeFailureCode.abort: 'animation operation was aborted',
  RuntimeFailureCode.disposed: 'animation player is disposed',
};

/// IDs and counters stay structured so diagnostics never interpolate untrusted
/// asset data into a message.
class RuntimeFailureContext {
  const RuntimeFailureContext({
    this.rendition,
    this.profile,
    this.codec,
    this.unit,
    this.state,
    this.edge,
    this.path,
    this.operation,
    this.sourceCode,
    this.sourcePath,
    this.alphaStatistic,
    this.policyPhase,
    this.lifecyclePhase,
    this.offset,
    this.width,
    this.height,
    this.generation,
    this.ordinal,
    this.localFrame,
    this.rank,
    this.requestOrdinal,
    this.httpStatus,
    this.expectedBytes,
    this.observedBytes,
    this.declaredTotalBytes,
    this.playerBytes,
    this.pageBytes,
  });

  final String? rendition;
  final String? profile;
  final String? codec;
  final String? unit;
  final String? state;
  final String? edge;
  final String? path;
  final String? operation;
  final String? sourceCode;
  final String? sourcePath;
  final String? alphaStatistic;
  final String? policyPhase;
  final String? lifecyclePhase;
  final int? offset;
  final int? width;
  final int? height;
  final int? generation;
  final int? ordinal;
  final int? localFrame;
  final int? rank;
  final int? requestOrdinal;
  final int? httpStatus;
  final int? expectedBytes;
  final int? observedBytes;
  final int? declaredTotalBytes;
  final int? playerBytes;
  final int? pageBytes;

  bool get isEmpty =>
      rendition == null &&
      profile == null &&
      codec == null &&
      unit == null &&
      state == null &&
      edge == null &&
      path == null &&
      operation == null &&
      sourceCode == null &&
      sourcePath == null &&
      alphaStatistic == null &&
      policyPhase == null &&
      lifecyclePhase == null &&
      offset == null &&
      width == null &&
      height == null &&
      generation == null &&
      ordinal == null &&
      localFrame == null &&
      rank == null &&
      requestOrdinal == null &&
      httpStatus == null &&
      expectedBytes == null &&
      observedBytes == null &&
      declaredTotalBytes == null &&
      playerBytes == null &&
      pageBytes == null;
}

/// A normalized, bounded runtime failure value.
class RuntimeFailure {
  const RuntimeFailure({
    required this.code,
    required this.message,
    required this.context,
  });

  final RuntimeFailureCode code;
  final String message;
  final RuntimeFailureContext context;
}

/// A stable thrown form of a normalized runtime failure.
class RuntimePlaybackError implements Exception {
  RuntimePlaybackError(this.failure);

  final RuntimeFailure failure;

  RuntimeFailureCode get code => failure.code;

  String get name => 'RuntimePlaybackError';

  @override
  String toString() => 'RuntimePlaybackError: ${failure.message}';
}

bool isRuntimePlaybackError(Object? error) => error is RuntimePlaybackError;

/// Convert an unknown boundary failure into a bounded immutable value.
RuntimeFailure normalizeRuntimeFailure(
  RuntimeFailureCode code, [
  Object? cause,
  RuntimeFailureContext context = const RuntimeFailureContext(),
]) {
  if (cause is RuntimePlaybackError && cause.code == code && context.isEmpty) {
    return cause.failure;
  }

  final message = _boundedMessage(
    _messageFrom(cause),
    _defaultFailureMessages[code]!,
  );
  return RuntimeFailure(
    code: code,
    message: message,
    context: _normalizeContext(context),
  );
}

String? _messageFrom(Object? cause) {
  if (cause is String) return cause;
  if (cause is RuntimePlaybackError) return cause.failure.message;
  if (cause is Error || cause is Exception) {
    // Dart cannot read a hostile accessor-backed `message`; the only structured
    // message an unknown thrown value exposes safely is its toString().
    final text = cause.toString();
    return text.isEmpty ? null : text;
  }
  return null;
}

String _boundedMessage(String? candidate, String fallback) {
  final source =
      candidate != null && candidate.isNotEmpty ? candidate : fallback;
  return _truncateUtf16(source, maxRuntimeFailureMessageLength);
}

RuntimeFailureContext _normalizeContext(RuntimeFailureContext context) {
  String? text(String? value) {
    if (value != null && value.isNotEmpty) {
      return _truncateUtf16(value, maxRuntimeDiagnosticTextLength);
    }
    return null;
  }

  int? integer(int? value) {
    if (value != null && value >= 0) return value;
    return null;
  }

  return RuntimeFailureContext(
    rendition: text(context.rendition),
    profile: text(context.profile),
    codec: text(context.codec),
    unit: text(context.unit),
    state: text(context.state),
    edge: text(context.edge),
    path: text(context.path),
    operation: text(context.operation),
    sourceCode: text(context.sourceCode),
    sourcePath: text(context.sourcePath),
    alphaStatistic: text(context.alphaStatistic),
    policyPhase: text(context.policyPhase),
    lifecyclePhase: text(context.lifecyclePhase),
    offset: integer(context.offset),
    width: integer(context.width),
    height: integer(context.height),
    generation: integer(context.generation),
    ordinal: integer(context.ordinal),
    localFrame: integer(context.localFrame),
    rank: integer(context.rank),
    requestOrdinal: integer(context.requestOrdinal),
    httpStatus: integer(context.httpStatus),
    expectedBytes: integer(context.expectedBytes),
    observedBytes: integer(context.observedBytes),
    declaredTotalBytes: integer(context.declaredTotalBytes),
    playerBytes: integer(context.playerBytes),
    pageBytes: integer(context.pageBytes),
  );
}

String _truncateUtf16(String value, int maximum) {
  if (value.length <= maximum) return value;
  var result = value.substring(0, maximum);
  final last = result.codeUnitAt(result.length - 1);
  if (last >= 0xd800 && last <= 0xdbff) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

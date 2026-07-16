/// Exact rational frame-rate clock shared by presentation and decode time.
///
/// Direct port of `packages/player-web/src/runtime/rational-time.ts`. The TS
/// `number | bigint` virtual-frame parameter becomes a plain Dart `int`:
/// Dart's `int` is 64-bit on the VM, comfortably beyond JavaScript's
/// `Number.MAX_SAFE_INTEGER`, so no separate bigint-accepting overload is
/// needed the way TypeScript required one. `BigInt` is used internally only
/// where the TS source itself used `bigint`, to keep the microsecond dividend
/// calculation exact (frame counts near the safe-integer ceiling would
/// otherwise overflow even a 64-bit product). `Number.MAX_SAFE_INTEGER` is
/// kept as the exact JavaScript literal for parity, per the convention
/// established by `aval_graph`'s `request_ledger.dart`.
library;

final BigInt _microsecondsPerSecond = BigInt.from(1000000);
final BigInt _maxFrameRate = BigInt.from(60);

/// The largest integer JavaScript can represent exactly
/// (`Number.MAX_SAFE_INTEGER`). Kept as the literal TypeScript bound for
/// parity, even though Dart's native `int` safely exceeds it.
const int maxSafeInteger = 9007199254740991;
final BigInt _maxSafeIntegerBig = BigInt.from(maxSafeInteger);

/// A rational frame rate expressed as an authored numerator/denominator pair.
///
/// Rates are deliberately not reduced: preserving the authored numerator and
/// denominator keeps the manifest clock explicit.
class RationalFrameRate {
  const RationalFrameRate({required this.numerator, required this.denominator});

  final int numerator;
  final int denominator;

  @override
  bool operator ==(Object other) =>
      other is RationalFrameRate &&
      other.numerator == numerator &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  @override
  String toString() =>
      'RationalFrameRate(numerator: $numerator, denominator: $denominator)';
}

/// A virtual frame's position within one reusable encoded loop occurrence.
class VirtualFramePosition {
  const VirtualFramePosition({
    required this.iteration,
    required this.contentFrame,
  });

  final BigInt iteration;
  final int contentFrame;

  @override
  bool operator ==(Object other) =>
      other is VirtualFramePosition &&
      other.iteration == iteration &&
      other.contentFrame == contentFrame;

  @override
  int get hashCode => Object.hash(iteration, contentFrame);

  @override
  String toString() =>
      'VirtualFramePosition(iteration: $iteration, contentFrame: $contentFrame)';
}

/// Validates the exact rational clock shared by presentation and decode time.
///
/// Integer comparison avoids rounding a rate near the 60 fps ceiling through
/// floating-point arithmetic.
void validateFrameRate(RationalFrameRate rate) {
  _validatePositiveSafeInteger(rate.numerator, 'frame-rate numerator');
  _validatePositiveSafeInteger(rate.denominator, 'frame-rate denominator');

  if (BigInt.from(rate.numerator) >
      _maxFrameRate * BigInt.from(rate.denominator)) {
    throw RangeError('frame rate must not exceed 60 fps');
  }
}

/// Maps a non-negative frame ordinal to an integer-microsecond timestamp
/// using exact round-half-up arithmetic.
int timestampForFrame(int virtualFrame, RationalFrameRate rate) {
  validateFrameRate(rate);

  final frame = _normalizeVirtualFrame(virtualFrame);
  final dividend =
      frame * _microsecondsPerSecond * BigInt.from(rate.denominator);
  final timestamp = _divideRoundHalfUp(dividend, BigInt.from(rate.numerator));

  if (timestamp > _maxSafeIntegerBig) {
    throw RangeError("frame timestamp exceeds JavaScript's safe-integer range");
  }

  return timestamp.toInt();
}

/// Uses adjacent exact timestamps rather than accumulating a rounded duration.
int durationForFrame(int virtualFrame, RationalFrameRate rate) {
  final frame = _normalizeVirtualFrame(virtualFrame).toInt();
  final timestamp = timestampForFrame(frame, rate);
  final nextTimestamp = timestampForFrame(frame + 1, rate);

  return nextTimestamp - timestamp;
}

/// Maps the global clock back to one frame of a reusable encoded loop.
VirtualFramePosition splitVirtualFrame(int virtualFrame, int unitFrameCount) {
  final frame = _normalizeVirtualFrame(virtualFrame);
  _validatePositiveSafeInteger(unitFrameCount, 'unit frame count');

  final count = BigInt.from(unitFrameCount);

  return VirtualFramePosition(
    iteration: frame ~/ count,
    contentFrame: (frame.remainder(count)).toInt(),
  );
}

BigInt _normalizeVirtualFrame(int virtualFrame) {
  if (virtualFrame < 0) {
    throw RangeError(
      'virtual frame must be a non-negative safe integer or bigint',
    );
  }
  return BigInt.from(virtualFrame);
}

void _validatePositiveSafeInteger(int value, String label) {
  if (value <= 0) {
    throw RangeError('$label must be a positive safe integer');
  }
}

BigInt _divideRoundHalfUp(BigInt dividend, BigInt divisor) {
  final quotient = dividend ~/ divisor;
  final remainder = dividend.remainder(divisor);

  return quotient +
      (remainder * BigInt.two >= divisor ? BigInt.one : BigInt.zero);
}

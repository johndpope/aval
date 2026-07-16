/// Constrained Baseline AVC level table and codec-string identification.
///
/// Dart port of `packages/format/src/avc/codec.ts`.
library;

import '../errors.dart';

/// Supported ITU-T H.264 `level_idc` values (Constrained Baseline only).
const List<int> avcLevelIdcValues = [
  10, 11, 12, 13,
  20, 21, 22,
  30, 31, 32,
  40, 41, 42,
  50, 51, 52,
  60, 61, 62,
];

/// Codec identifier string, e.g. `"avc1.42E00A"`.
typedef AvcCodecV01 = String;

/// One `level_idc`, matching the closed set in [avcLevelIdcValues].
typedef AvcLevelIdc = int;

class AvcLevelLimits {
  const AvcLevelLimits({
    required this.levelIdc,
    required this.codec,
    required this.maximumMacroblocksPerSecond,
    required this.maximumMacroblocksPerFrame,
    required this.maximumMacroblockDimension,
    required this.maximumDpbMacroblocks,
    required this.maximumBitrate,
  });

  final AvcLevelIdc levelIdc;
  final AvcCodecV01 codec;
  final int maximumMacroblocksPerSecond;
  final int maximumMacroblocksPerFrame;
  final int maximumMacroblockDimension;
  final int maximumDpbMacroblocks;
  final int maximumBitrate;
}

const List<List<Object>> _levelRows = [
  [10, 'avc1.42E00A', 1485, 99, 396, 64000, 175000],
  [11, 'avc1.42E00B', 3000, 396, 900, 192000, 500000],
  [12, 'avc1.42E00C', 6000, 396, 2376, 384000, 1000000],
  [13, 'avc1.42E00D', 11880, 396, 2376, 768000, 2000000],
  [20, 'avc1.42E014', 11880, 396, 2376, 2000000, 2000000],
  [21, 'avc1.42E015', 19800, 792, 4752, 4000000, 4000000],
  [22, 'avc1.42E016', 20250, 1620, 8100, 4000000, 4000000],
  [30, 'avc1.42E01E', 40500, 1620, 8100, 10000000, 10000000],
  [31, 'avc1.42E01F', 108000, 3600, 18000, 14000000, 14000000],
  [32, 'avc1.42E020', 216000, 5120, 20480, 20000000, 20000000],
  [40, 'avc1.42E028', 245760, 8192, 32768, 20000000, 25000000],
  [41, 'avc1.42E029', 245760, 8192, 32768, 50000000, 62500000],
  [42, 'avc1.42E02A', 522240, 8704, 34816, 50000000, 62500000],
  [50, 'avc1.42E032', 589824, 22080, 110400, 135000000, 135000000],
  [51, 'avc1.42E033', 983040, 36864, 184320, 240000000, 240000000],
  [52, 'avc1.42E034', 2073600, 36864, 184320, 240000000, 240000000],
  [60, 'avc1.42E03C', 4177920, 139264, 696320, 240000000, 240000000],
  [61, 'avc1.42E03D', 8355840, 139264, 696320, 480000000, 480000000],
  [62, 'avc1.42E03E', 16711680, 139264, 696320, 800000000, 800000000],
];

int _maximumMacroblockDimension(int macroblocksPerFrame) =>
    (_sqrt(macroblocksPerFrame * 8)).floor();

double _sqrt(int value) => value <= 0 ? 0 : _newtonSqrt(value.toDouble());

double _newtonSqrt(double value) {
  var guess = value;
  for (var i = 0; i < 64; i += 1) {
    if (guess == 0) break;
    final next = 0.5 * (guess + value / guess);
    if ((next - guess).abs() < 1e-9) return next;
    guess = next;
  }
  return guess;
}

final Map<int, AvcLevelLimits> _levels = {
  for (final row in _levelRows)
    (row[0] as int): AvcLevelLimits(
      levelIdc: row[0] as int,
      codec: row[1] as String,
      maximumMacroblocksPerSecond: row[2] as int,
      maximumMacroblocksPerFrame: row[3] as int,
      maximumMacroblockDimension: _maximumMacroblockDimension(row[3] as int),
      maximumDpbMacroblocks: row[4] as int,
      maximumBitrate: row[5] as int,
    ),
};

final Map<String, AvcLevelLimits> _codecs = {
  for (final limits in _levels.values) limits.codec: limits,
};

bool isAvcLevelIdc(int value) => _levels.containsKey(value);

AvcLevelLimits avcLevelLimits(int levelIdc) {
  final limits = _levels[levelIdc];
  if (limits == null) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'AVC level_idc is unsupported',
    );
  }
  return limits;
}

AvcCodecV01 avcCodecForLevel(int levelIdc) => avcLevelLimits(levelIdc).codec;

AvcLevelLimits parseAvcCodec(Object? codec) {
  final limits = codec is String ? _codecs[codec] : null;
  if (limits == null) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'AVC codec must identify a supported Constrained Baseline level',
    );
  }
  return limits;
}

bool isAvcCodec(Object? codec) => codec is String && _codecs.containsKey(codec);

/// High-profile H264 level table and codec-string identification.
///
/// Dart port of `packages/format/src/h264/codec.ts`.
library;

import 'dart:math' as math;

import '../errors.dart';

/// One `level_idc`, matching the closed set carried by [_levelRows].
///
/// TS `H264LevelIdc` is a string-literal union of numeric `level_idc` values;
/// used only for equality, so it is a Dart `int` typedef per the port
/// conventions.
typedef H264LevelIdc = int;

/// Codec identifier string, e.g. `"avc1.640020"` (High profile).
///
/// TS `H264Codec` is a string-literal union used only for equality/membership.
typedef H264Codec = String;

class H264LevelLimits {
  const H264LevelLimits({
    required this.levelIdc,
    required this.codec,
    required this.maximumMacroblocksPerSecond,
    required this.maximumMacroblocksPerFrame,
    required this.maximumMacroblockDimension,
    required this.maximumDpbMacroblocks,
    required this.maximumBitrate,
    required this.maximumCpbBits,
  });

  final H264LevelIdc levelIdc;
  final H264Codec codec;
  final int maximumMacroblocksPerSecond;
  final int maximumMacroblocksPerFrame;
  final int maximumMacroblockDimension;
  final int maximumDpbMacroblocks;
  final int maximumBitrate;
  final int maximumCpbBits;
}

// Columns: level_idc, codec, maxMb/s, maxMb/frame, maxDpbMb, maxBitrate,
// maxCpbBits. Mirrors `codec.ts` `LEVEL_ROWS`.
const List<List<Object>> _levelRows = [
  [10, 'avc1.64000A', 1485, 99, 396, 64000, 175000],
  [11, 'avc1.64000B', 3000, 396, 900, 192000, 500000],
  [12, 'avc1.64000C', 6000, 396, 2376, 384000, 1000000],
  [13, 'avc1.64000D', 11880, 396, 2376, 768000, 2000000],
  [20, 'avc1.640014', 11880, 396, 2376, 2000000, 2000000],
  [21, 'avc1.640015', 19800, 792, 4752, 4000000, 4000000],
  [22, 'avc1.640016', 20250, 1620, 8100, 4000000, 4000000],
  [30, 'avc1.64001E', 40500, 1620, 8100, 10000000, 10000000],
  [31, 'avc1.64001F', 108000, 3600, 18000, 14000000, 14000000],
  [32, 'avc1.640020', 216000, 5120, 20480, 20000000, 20000000],
  [40, 'avc1.640028', 245760, 8192, 32768, 20000000, 25000000],
  [41, 'avc1.640029', 245760, 8192, 32768, 50000000, 62500000],
  [42, 'avc1.64002A', 522240, 8704, 34816, 50000000, 62500000],
  [50, 'avc1.640032', 589824, 22080, 110400, 135000000, 135000000],
  [51, 'avc1.640033', 983040, 36864, 184320, 240000000, 240000000],
  [52, 'avc1.640034', 2073600, 36864, 184320, 240000000, 240000000],
  [60, 'avc1.64003C', 4177920, 139264, 696320, 240000000, 240000000],
  [61, 'avc1.64003D', 8355840, 139264, 696320, 480000000, 480000000],
  [62, 'avc1.64003E', 16711680, 139264, 696320, 800000000, 800000000],
];

// `Math.floor(Math.sqrt(row[3] * 8))` from `codec.ts:59`.
int _maximumMacroblockDimension(int macroblocksPerFrame) =>
    math.sqrt(macroblocksPerFrame * 8).floor();

final Map<int, H264LevelLimits> _levels = {
  for (final row in _levelRows)
    (row[0] as int): H264LevelLimits(
      levelIdc: row[0] as int,
      codec: row[1] as String,
      maximumMacroblocksPerSecond: row[2] as int,
      maximumMacroblocksPerFrame: row[3] as int,
      maximumMacroblockDimension: _maximumMacroblockDimension(row[3] as int),
      maximumDpbMacroblocks: row[4] as int,
      maximumBitrate: row[5] as int,
      maximumCpbBits: row[6] as int,
    ),
};

final Map<String, H264LevelLimits> _codecs = {
  for (final limits in _levels.values) limits.codec: limits,
};

bool isH264LevelIdc(int value) => _levels.containsKey(value);

H264LevelLimits h264LevelLimits(int levelIdc) {
  final limits = _levels[levelIdc];
  if (limits == null) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'H264 level_idc is unsupported',
    );
  }
  return limits;
}

H264Codec h264CodecForLevel(int levelIdc) => h264LevelLimits(levelIdc).codec;

H264LevelLimits parseH264Codec(Object? codec) {
  final limits = codec is String ? _codecs[codec] : null;
  if (limits == null) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'H264 codec must identify a supported High-profile level',
    );
  }
  return limits;
}

bool isH264Codec(Object? codec) =>
    codec is String && _codecs.containsKey(codec);

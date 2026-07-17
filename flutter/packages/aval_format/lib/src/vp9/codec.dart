/// VP9 profile-0 level table and codec-string identification.
///
/// Dart port of `packages/format/src/vp9/codec.ts`.
library;

import '../errors.dart';

/// One of the supported VP9 level identifiers (`"10"` … `"62"`).
///
/// The TypeScript source models this as a string-literal union; equality is
/// on the string value, so a [String] typedef preserves behavior.
typedef Vp9Level = String;

/// Fully-qualified VP9 codec string, e.g. `"vp09.00.10.08.01.01.01.01.00"`.
typedef Vp9Codec = String;

class _Vp9LevelLimit {
  const _Vp9LevelLimit({
    required this.level,
    required this.maximumLumaSampleRate,
    required this.maximumLumaPictureSize,
    required this.maximumBitrate,
    required this.maximumDimension,
  });

  final String level;
  final int maximumLumaSampleRate;
  final int maximumLumaPictureSize;
  final int maximumBitrate;
  final int maximumDimension;
}

const List<_Vp9LevelLimit> _levels = [
  _Vp9LevelLimit(level: '10', maximumLumaSampleRate: 829440, maximumLumaPictureSize: 36864, maximumBitrate: 200000, maximumDimension: 512),
  _Vp9LevelLimit(level: '11', maximumLumaSampleRate: 2764800, maximumLumaPictureSize: 73728, maximumBitrate: 800000, maximumDimension: 768),
  _Vp9LevelLimit(level: '20', maximumLumaSampleRate: 4608000, maximumLumaPictureSize: 122880, maximumBitrate: 1800000, maximumDimension: 960),
  _Vp9LevelLimit(level: '21', maximumLumaSampleRate: 9216000, maximumLumaPictureSize: 245760, maximumBitrate: 3600000, maximumDimension: 1344),
  _Vp9LevelLimit(level: '30', maximumLumaSampleRate: 20736000, maximumLumaPictureSize: 552960, maximumBitrate: 7200000, maximumDimension: 2048),
  _Vp9LevelLimit(level: '31', maximumLumaSampleRate: 36864000, maximumLumaPictureSize: 983040, maximumBitrate: 12000000, maximumDimension: 2752),
  _Vp9LevelLimit(level: '40', maximumLumaSampleRate: 83558400, maximumLumaPictureSize: 2228224, maximumBitrate: 18000000, maximumDimension: 4160),
  _Vp9LevelLimit(level: '41', maximumLumaSampleRate: 160432128, maximumLumaPictureSize: 2228224, maximumBitrate: 30000000, maximumDimension: 4160),
  _Vp9LevelLimit(level: '50', maximumLumaSampleRate: 311951360, maximumLumaPictureSize: 8912896, maximumBitrate: 60000000, maximumDimension: 8384),
  _Vp9LevelLimit(level: '51', maximumLumaSampleRate: 588251136, maximumLumaPictureSize: 8912896, maximumBitrate: 120000000, maximumDimension: 8384),
  _Vp9LevelLimit(level: '52', maximumLumaSampleRate: 1176502272, maximumLumaPictureSize: 8912896, maximumBitrate: 180000000, maximumDimension: 8384),
  _Vp9LevelLimit(level: '60', maximumLumaSampleRate: 1176502272, maximumLumaPictureSize: 35651584, maximumBitrate: 180000000, maximumDimension: 16832),
  _Vp9LevelLimit(level: '61', maximumLumaSampleRate: 2353004544, maximumLumaPictureSize: 35651584, maximumBitrate: 240000000, maximumDimension: 16832),
  _Vp9LevelLimit(level: '62', maximumLumaSampleRate: 4706009088, maximumLumaPictureSize: 35651584, maximumBitrate: 480000000, maximumDimension: 16832),
];

class DeriveVp9CodecInput {
  const DeriveVp9CodecInput({
    required this.width,
    required this.height,
    required this.codedFramesPerSecond,
    required this.averageBitrate,
  });

  final num width;
  final num height;
  final num codedFramesPerSecond;
  final num averageBitrate;
}

Vp9Codec deriveVp9Codec(DeriveVp9CodecInput input) {
  for (final value in [
    input.width,
    input.height,
    input.codedFramesPerSecond,
    input.averageBitrate,
  ]) {
    if (!value.isFinite || value <= 0) {
      throw FormatError(
        FormatErrorCode.profileInvalid,
        'VP9 level inputs must be positive',
      );
    }
  }
  final pictureSize = input.width * input.height;
  final sampleRate = pictureSize * input.codedFramesPerSecond;
  _Vp9LevelLimit? level;
  for (final candidate in _levels) {
    if (pictureSize <= candidate.maximumLumaPictureSize &&
        sampleRate <= candidate.maximumLumaSampleRate &&
        input.averageBitrate <= candidate.maximumBitrate &&
        input.width <= candidate.maximumDimension &&
        input.height <= candidate.maximumDimension) {
      level = candidate;
      break;
    }
  }
  if (level == null) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'VP9 stream exceeds level 6.2',
    );
  }
  return 'vp09.00.${level.level}.08.01.01.01.01.00';
}

final RegExp _vp9CodecPattern = RegExp(
  r'^vp09\.00\.(?:10|11|20|21|30|31|40|41|50|51|52|60|61|62)\.08\.01\.01\.01\.01\.00$',
);

bool isVp9Codec(Object? value) =>
    value is String && _vp9CodecPattern.hasMatch(value);

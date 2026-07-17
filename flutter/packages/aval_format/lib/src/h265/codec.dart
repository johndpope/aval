/// HEVC codec-string parsing/derivation and WebCodecs decoder config.
///
/// Dart port of `packages/format/src/h265/codec.ts`.
library;

import 'failure.dart';
import 'parameter_sets.dart' show H265ProfileTierLevel, ParsedH265Sps;
import 'types.dart' show H265DecoderColorSpace, H265VideoDecoderConfig;

const List<String> _profileSpacePrefix = ['', 'A', 'B', 'C'];
final RegExp _h265MainCodec = RegExp(
  r'^hvc1\.1\.(0|[1-9A-F][0-9A-F]*)\.[LH](0|[1-9][0-9]*)\.((?:[0-9A-F]{2}\.){0,5}(?!00)[0-9A-F]{2})$',
  unicode: true,
);

/// Port of `ParsedH265Codec` (`src/h265/codec.ts:9`).
class ParsedH265Codec {
  const ParsedH265Codec({required this.codec});

  final String codec;

  /// Always `8`.
  final int bitDepth = 8;
}

/// Parse the canonical Main/8-bit HEVC profile accepted by AVAL inspection.
///
/// Port of `parseH265Codec` (`src/h265/codec.ts:15`). Not part of the module's
/// public barrel; retained for file-level parity with the TS source.
ParsedH265Codec? parseH265Codec(Object? value) {
  if (value is! String) return null;
  final match = _h265MainCodec.firstMatch(value);
  if (match == null) return null;
  final compatibilityFlags = int.parse(match.group(1)!, radix: 16);
  final levelIdc = int.parse(match.group(2)!);
  final firstConstraintByte =
      int.parse(match.group(3)!.substring(0, 2), radix: 16);
  if (compatibilityFlags > 0xffffffff ||
      (compatibilityFlags & 0x02) == 0 ||
      levelIdc < 1 ||
      levelIdc > 255 ||
      (firstConstraintByte & 0x80) == 0 ||
      (firstConstraintByte & 0x40) != 0 ||
      (firstConstraintByte & 0x10) == 0) {
    return null;
  }
  return ParsedH265Codec(codec: value);
}

/// Derives the RFC 6381/ISO BMFF HEVC identifier used by WebCodecs.
///
/// Port of `h265CodecString` (`src/h265/codec.ts:39`).
String h265CodecString(H265ProfileTierLevel profileTierLevel) {
  final prefix = (profileTierLevel.profileSpace >= 0 &&
          profileTierLevel.profileSpace < _profileSpacePrefix.length)
      ? _profileSpacePrefix[profileTierLevel.profileSpace]
      : null;
  requireH265(prefix != null, 'profileTierLevel', 'invalid profile space');
  final compatibility = profileTierLevel.profileCompatibilityFlags
      .toRadixString(16)
      .toUpperCase();
  final constraints = List<int>.from(profileTierLevel.constraintIndicatorFlags);
  while (constraints.isNotEmpty && constraints.last == 0) {
    constraints.removeLast();
  }
  final suffix = constraints
      .map((byte) => byte.toRadixString(16).toUpperCase().padLeft(2, '0'))
      .join('.');
  return 'hvc1.$prefix${profileTierLevel.profileIdc}.$compatibility.'
      '${profileTierLevel.tierFlag ? 'H' : 'L'}${profileTierLevel.levelIdc}'
      '${suffix.isEmpty ? '' : '.$suffix'}';
}

/// Port of `createH265VideoDecoderConfig` (`src/h265/codec.ts:55`).
H265VideoDecoderConfig createH265VideoDecoderConfig(ParsedH265Sps sps) {
  requireH265(
    sps.color.fullRange == false &&
        sps.color.colourPrimaries == 1 &&
        sps.color.transferCharacteristics == 1 &&
        sps.color.matrixCoefficients == 1,
    'sps.vui',
    'HEVC decoder configuration requires BT.709 limited-range signalling',
  );
  return H265VideoDecoderConfig(
    codec: h265CodecString(sps.profileTierLevel),
    codedWidth: sps.codedWidth,
    codedHeight: sps.codedHeight,
    displayAspectWidth: sps.crop.visibleWidth,
    displayAspectHeight: sps.crop.visibleHeight,
    colorSpace: const H265DecoderColorSpace(),
  );
}

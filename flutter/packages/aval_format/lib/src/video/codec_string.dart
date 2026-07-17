/// Canonical WebCodecs codec-string parsing shared across codecs.
///
/// Dart port of `packages/format/src/video/codec-string.ts`.
library;

import '../av1/codec.dart' show isAv1Codec;
import '../h264/codec.dart' show isH264Codec;
import '../h265/codec.dart' show parseH265Codec;
import '../model.dart' show VideoBitDepth, VideoBitstream, VideoCodec;
import '../vp9/codec.dart' show isVp9Codec;

const List<VideoCodec> videoCodecs = ['h264', 'h265', 'vp9', 'av1'];

const Map<VideoCodec, VideoBitstream> videoBitstreamByCodec = {
  'h264': 'annex-b',
  'h265': 'annex-b',
  'vp9': 'frame',
  'av1': 'low-overhead',
};

/// `{ family, bitDepth }` — the parsed family and declared bit depth of a
/// supported WebCodecs codec string.
class ParsedVideoCodecString {
  const ParsedVideoCodecString({required this.family, required this.bitDepth});

  /// `"h264" | "h265" | "vp9" | "av1"`.
  final VideoCodec family;
  final VideoBitDepth bitDepth;
}

final RegExp _vp9Short =
    RegExp(r'^vp09\.00\.(?:10|11|20|21|30|31|40|41|50|51|52|60|61|62)\.08$', unicode: true);
final RegExp _av1Short =
    RegExp(r'^av01\.0\.(?:0[0-9]|[12][0-9]|3[01])[MH]\.(08|10)$', unicode: true);

/// Parse one canonical WebCodecs codec string supported by the AVAL format.
ParsedVideoCodecString? parseVideoCodecString(String value) {
  if (isH264Codec(value)) {
    return const ParsedVideoCodecString(family: 'h264', bitDepth: 8);
  }

  final h265 = parseH265Codec(value);
  if (h265 != null) {
    return ParsedVideoCodecString(family: 'h265', bitDepth: h265.bitDepth);
  }

  if (isVp9Codec(value) || _vp9Short.hasMatch(value)) {
    return const ParsedVideoCodecString(family: 'vp9', bitDepth: 8);
  }

  final av1Short = _av1Short.firstMatch(value);
  if (isAv1Codec(value) || av1Short != null) {
    final parts = value.split('.');
    final bitDepthTerm =
        av1Short?.group(1) ?? (parts.length > 3 ? parts[3] : null);
    return ParsedVideoCodecString(
      family: 'av1',
      bitDepth: bitDepthTerm == '10' ? 10 : 8,
    );
  }

  return null;
}

bool isVideoCodecString(Object? value, VideoCodec family, VideoBitDepth bitDepth) {
  if (value is! String) return false;
  final parsed = parseVideoCodecString(value);
  return parsed?.family == family && parsed?.bitDepth == bitDepth;
}

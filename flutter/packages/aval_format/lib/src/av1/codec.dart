/// AV1 codec-string derivation and identification.
///
/// Dart port of `packages/format/src/av1/codec.ts`.
library;

import '../errors.dart';
import 'sequence_header.dart';

/// Fully-qualified AV1 codec string,
/// e.g. `"av01.0.00M.08.0.110.01.01.01.0"`.
typedef Av1Codec = String;

Av1Codec av1CodecFromSequence(Av1SequenceHeader sequence) {
  if (sequence.level < 0 || sequence.level > 31) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'AV1 level is invalid',
    );
  }
  final level = sequence.level.toString().padLeft(2, '0');
  final bitDepth = sequence.bitDepth.toString().padLeft(2, '0');
  return 'av01.0.$level${sequence.tier}.$bitDepth.0.11${sequence.chromaSamplePosition}.01.01.01.0';
}

final RegExp _av1CodecPattern = RegExp(
  r'^av01\.0\.(?:0[0-9]|[12][0-9]|3[01])[MH]\.(?:08|10)\.0\.11[0-3]\.01\.01\.01\.0$',
);

bool isAv1Codec(Object? value) =>
    value is String && _av1CodecPattern.hasMatch(value);

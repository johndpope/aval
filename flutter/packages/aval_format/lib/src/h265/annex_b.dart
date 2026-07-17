/// HEVC Annex-B NAL-unit tokenizer and EBSP-to-RBSP conversion.
///
/// Dart port of `packages/format/src/h265/annex-b.ts`.
library;

// ignore_for_file: constant_identifier_names

import 'dart:typed_data';

import '../checked_integer.dart' show maxSafeInteger;
import 'failure.dart';

const int H265_NAL_TRAIL_N = 0;
const int H265_NAL_TRAIL_R = 1;
const int H265_NAL_BLA_W_LP = 16;
const int H265_NAL_BLA_W_RADL = 17;
const int H265_NAL_BLA_N_LP = 18;
const int H265_NAL_IDR_W_RADL = 19;
const int H265_NAL_IDR_N_LP = 20;
const int H265_NAL_CRA_NUT = 21;
const int H265_NAL_VPS = 32;
const int H265_NAL_SPS = 33;
const int H265_NAL_PPS = 34;
const int H265_NAL_AUD = 35;
const int H265_NAL_EOS = 36;
const int H265_NAL_EOB = 37;
const int H265_NAL_FILLER = 38;
const int H265_NAL_PREFIX_SEI = 39;
const int H265_NAL_SUFFIX_SEI = 40;

const int H265_MAX_ACCESS_UNIT_BYTES = 64 * 1024 * 1024;
const int H265_MAX_NAL_UNITS = 4096;
const int _maxParameterSetBytes = 1024 * 1024;

/// Options controlling [splitH265AnnexBAccessUnit].
///
/// Port of `H265AnnexBOptions` (`src/h265/annex-b.ts:25`).
class H265AnnexBOptions {
  const H265AnnexBOptions({
    this.maximumBytes,
    this.maximumNalUnits,
    this.allowEncoderMetadata,
  });

  final int? maximumBytes;
  final int? maximumNalUnits;
  final bool? allowEncoderMetadata;
}

/// A single parsed HEVC Annex-B NAL unit.
///
/// Port of `H265AnnexBNalUnit` (`src/h265/annex-b.ts:31`).
class H265AnnexBNalUnit {
  const H265AnnexBNalUnit({
    required this.type,
    required this.layerId,
    required this.temporalId,
    required this.offset,
    required this.prefixLength,
    required this.payload,
    required this.rbsp,
  });

  final int type;

  /// Always `0` (multilayer HEVC is unsupported).
  final int layerId;
  final int temporalId;
  final int offset;

  /// Always `3` or `4`.
  final int prefixLength;
  final Uint8List payload;
  final Uint8List rbsp;
}

class _StartCode {
  const _StartCode({required this.offset, required this.length});

  final int offset;

  /// Always `3` or `4`.
  final int length;
}

/// Splits one canonical Annex-B access unit without retaining hidden copies.
///
/// Port of `splitH265AnnexBAccessUnit` (`src/h265/annex-b.ts:47`).
List<H265AnnexBNalUnit> splitH265AnnexBAccessUnit(
  Uint8List bytes, [
  String path = 'accessUnit',
  H265AnnexBOptions options = const H265AnnexBOptions(),
]) {
  final maximumBytes = options.maximumBytes ?? H265_MAX_ACCESS_UNIT_BYTES;
  final maximumNalUnits = options.maximumNalUnits ?? H265_MAX_NAL_UNITS;
  requireH265(
    maximumBytes <= maxSafeInteger && maximumBytes > 0,
    path,
    'access-unit byte budget is invalid',
  );
  requireH265(
    maximumNalUnits <= maxSafeInteger && maximumNalUnits > 0,
    path,
    'NAL-unit count budget is invalid',
  );
  requireH265(bytes.length >= 6, path, 'Annex-B access unit is too short');
  requireH265(
    bytes.length <= maximumBytes,
    path,
    'Annex-B access unit exceeds the byte budget',
  );

  final starts = _findStartCodes(bytes, path, maximumNalUnits);
  requireH265(starts.isNotEmpty, path, 'Annex-B start code is missing', 0);
  requireH265(
    starts[0].offset == 0,
    path,
    'bytes precede the first start code',
    0,
  );

  final units = <H265AnnexBNalUnit>[];
  for (var index = 0; index < starts.length; index += 1) {
    final start = starts[index];
    final payloadOffset = start.offset + start.length;
    final payloadEnd =
        index + 1 < starts.length ? starts[index + 1].offset : bytes.length;
    requireH265(
      payloadEnd >= payloadOffset + 3,
      path,
      'empty or truncated HEVC NAL unit',
      start.offset,
    );
    final payload = Uint8List.sublistView(bytes, payloadOffset, payloadEnd);
    // TS reads payload[0]/[1]; the length >= 3 guarantee above keeps them
    // in range, matching the `first !== undefined && second !== undefined`
    // check (`src/h265/annex-b.ts:88`).
    final first = payload[0];
    final second = payload[1];
    requireH265(
      payload[payload.length - 1] != 0,
      path,
      'NAL units may not contain trailing_zero_8bits',
      payloadEnd - 1,
    );
    requireH265(
      (first & 0x80) == 0,
      path,
      'forbidden_zero_bit must be zero',
      payloadOffset,
    );
    final type = (first >> 1) & 0x3f;
    final layerId = ((first & 1) << 5) | (second >> 3);
    final temporalIdPlusOne = second & 0x07;
    requireH265(
      layerId == 0,
      path,
      'multilayer HEVC is unsupported',
      payloadOffset,
    );
    requireH265(
      temporalIdPlusOne != 0,
      path,
      'nuh_temporal_id_plus1 must not be zero',
      payloadOffset + 1,
    );
    requireH265(
      _isPermittedH265NalType(type, options.allowEncoderMetadata == true),
      path,
      'NAL unit type $type is outside the production HEVC profile',
      payloadOffset,
    );
    if (type >= H265_NAL_VPS) {
      requireH265(
        temporalIdPlusOne == 1,
        path,
        'non-VCL NAL units must use temporal_id zero',
        payloadOffset + 1,
      );
    }
    if (type == H265_NAL_VPS || type == H265_NAL_SPS || type == H265_NAL_PPS) {
      requireH265(
        payload.length <= _maxParameterSetBytes,
        path,
        'HEVC parameter set exceeds the syntax budget',
        payloadOffset,
      );
    }
    units.add(
      H265AnnexBNalUnit(
        type: type,
        layerId: 0,
        temporalId: temporalIdPlusOne - 1,
        offset: payloadOffset,
        prefixLength: start.length,
        payload: payload,
        rbsp: removeH265EmulationPrevention(
          Uint8List.sublistView(payload, 2),
          path,
          payloadOffset + 2,
        ),
      ),
    );
  }
  return List.unmodifiable(units);
}

/// Port of `isH265VclNalType` (`src/h265/annex-b.ts:155`).
bool isH265VclNalType(int type) {
  return (type >= 0 && type <= 9) || (type >= 16 && type <= 21);
}

/// Port of `isH265RandomAccessNalType` (`src/h265/annex-b.ts:159`).
bool isH265RandomAccessNalType(int type) {
  return type >= H265_NAL_BLA_W_LP && type <= H265_NAL_CRA_NUT;
}

/// Port of `isH265IdrNalType` (`src/h265/annex-b.ts:163`).
bool isH265IdrNalType(int type) {
  return type == H265_NAL_IDR_W_RADL || type == H265_NAL_IDR_N_LP;
}

bool _isPermittedH265NalType(int type, bool allowMetadata) {
  if (isH265VclNalType(type)) return true;
  if (type == H265_NAL_VPS ||
      type == H265_NAL_SPS ||
      type == H265_NAL_PPS ||
      type == H265_NAL_AUD) {
    return true;
  }
  return allowMetadata &&
      (type == H265_NAL_EOS ||
          type == H265_NAL_EOB ||
          type == H265_NAL_FILLER ||
          type == H265_NAL_PREFIX_SEI ||
          type == H265_NAL_SUFFIX_SEI);
}

List<_StartCode> _findStartCodes(
  Uint8List bytes,
  String path,
  int maximumNalUnits,
) {
  final starts = <_StartCode>[];
  var cursor = 0;
  while (cursor < bytes.length) {
    if (bytes[cursor] != 0) {
      cursor += 1;
      continue;
    }
    final runStart = cursor;
    while (cursor < bytes.length && bytes[cursor] == 0) {
      cursor += 1;
    }
    if (cursor >= bytes.length || bytes[cursor] != 1 || cursor - runStart < 2) {
      continue;
    }
    final zeroCount = cursor - runStart;
    requireH265(
      zeroCount == 2 || zeroCount == 3,
      path,
      'start codes may contain only two or three zero bytes',
      runStart,
    );
    starts.add(_StartCode(offset: runStart, length: zeroCount + 1));
    requireH265(
      starts.length <= maximumNalUnits,
      path,
      'NAL-unit count exceeds the inspection budget',
      runStart,
    );
    cursor += 1;
  }
  return List.unmodifiable(starts);
}

/// Removes emulation-prevention bytes and rejects non-canonical EBSP.
///
/// Port of `removeH265EmulationPrevention` (`src/h265/annex-b.ts:224`).
Uint8List removeH265EmulationPrevention(
  Uint8List ebsp,
  String path,
  int absoluteOffset,
) {
  requireH265(ebsp.isNotEmpty, path, 'NAL RBSP is empty', absoluteOffset);
  final rbsp = Uint8List(ebsp.length);
  var outputLength = 0;
  var zeroCount = 0;
  for (var index = 0; index < ebsp.length; index += 1) {
    final byte = ebsp[index];
    if (zeroCount == 2) {
      if (byte == 0x03) {
        final escapedIndex = index + 1;
        final escaped = escapedIndex < ebsp.length ? ebsp[escapedIndex] : null;
        requireH265(
          escaped != null && escaped <= 0x03,
          path,
          'emulation_prevention_three_byte is not followed by 0x00..0x03',
          absoluteOffset + index,
        );
        zeroCount = 0;
        continue;
      }
      requireH265(
        byte > 0x02,
        path,
        'unescaped start-code emulation sequence in EBSP',
        absoluteOffset + index,
      );
    }
    rbsp[outputLength] = byte;
    outputLength += 1;
    zeroCount = byte == 0 ? zeroCount + 1 : 0;
  }
  // TS `rbsp.slice(0, outputLength)` returns a fresh copy.
  return Uint8List.fromList(Uint8List.sublistView(rbsp, 0, outputLength));
}

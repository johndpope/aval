/// Annex B NAL-unit tokenizer and EBSP-to-RBSP conversion.
///
/// Dart port of `packages/format/src/h264/annex-b.ts`.
library;

// ignore_for_file: constant_identifier_names

import 'dart:typed_data';

import '../checked_integer.dart' show maxSafeInteger;
import 'failure.dart';

const int H264_NAL_TYPE_NON_IDR = 1;
const int H264_NAL_TYPE_IDR = 5;
const int H264_NAL_TYPE_SEI = 6;
const int H264_NAL_TYPE_SPS = 7;
const int H264_NAL_TYPE_PPS = 8;
const int H264_NAL_TYPE_AUD = 9;

const Set<int> _allowedNalTypes = {
  H264_NAL_TYPE_NON_IDR,
  H264_NAL_TYPE_IDR,
  H264_NAL_TYPE_SPS,
  H264_NAL_TYPE_PPS,
  H264_NAL_TYPE_AUD,
};
const int _defaultMaxNalUnits = 5124;

class AnnexBNalUnit {
  const AnnexBNalUnit({
    required this.type,
    required this.referenceIdc,
    required this.offset,
    required this.prefixLength,
    required this.payload,
    required this.rbsp,
  });

  final int type;
  final int referenceIdc;
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

List<AnnexBNalUnit> splitAnnexBAccessUnit(
  Uint8List bytes,
  String path, [
  int maximumNalUnits = _defaultMaxNalUnits,
  bool allowEncoderSei = false,
]) {
  // TS `annex-b.ts:39` also asserts `bytes instanceof Uint8Array`; Dart's
  // static typing guarantees a `Uint8List`, so the guard is structurally met.
  requireH264(bytes.length >= 5, path, 'Annex B access unit is too short');
  requireH264(
    maximumNalUnits > 0 && maximumNalUnits <= maxSafeInteger,
    path,
    'NAL-unit budget is invalid',
  );

  final starts = _findStartCodes(bytes, path, maximumNalUnits);
  requireH264(starts.isNotEmpty, path, 'Annex B start code is missing', 0);
  requireH264(
    starts[0].offset == 0,
    path,
    'bytes precede the first start code',
    0,
  );

  final units = <AnnexBNalUnit>[];
  for (var index = 0; index < starts.length; index += 1) {
    final start = starts[index];
    final payloadOffset = start.offset + start.length;
    final payloadEnd =
        index + 1 < starts.length ? starts[index + 1].offset : bytes.length;
    requireH264(
      payloadEnd > payloadOffset,
      path,
      'empty NAL unit is forbidden',
      start.offset,
    );
    final payload = Uint8List.sublistView(bytes, payloadOffset, payloadEnd);
    requireH264(payload.isNotEmpty, path, 'NAL header is missing', payloadOffset);
    final header = payload[0];
    requireH264(
      payload[payload.length - 1] != 0,
      path,
      'NAL units may not contain trailing_zero_8bits',
      payloadEnd - 1,
    );
    requireH264(
      (header & 0x80) == 0,
      path,
      'forbidden_zero_bit must be zero',
      payloadOffset,
    );
    final type = header & 0x1f;
    requireH264(
      _allowedNalTypes.contains(type) ||
          (allowEncoderSei && type == H264_NAL_TYPE_SEI),
      path,
      'NAL unit type $type is not permitted by the production H264 profile',
      payloadOffset,
    );
    final referenceIdc = (header >> 5) & 0x03;
    if (type == H264_NAL_TYPE_AUD || type == H264_NAL_TYPE_SEI) {
      requireH264(
        referenceIdc == 0,
        path,
        'AUD and SEI nal_ref_idc must be zero',
        payloadOffset,
      );
    } else if (type == H264_NAL_TYPE_SPS ||
        type == H264_NAL_TYPE_PPS ||
        type == H264_NAL_TYPE_IDR) {
      requireH264(
        referenceIdc != 0,
        path,
        'parameter sets and IDR pictures must be reference NAL units',
        payloadOffset,
      );
    }
    units.add(
      AnnexBNalUnit(
        type: type,
        referenceIdc: referenceIdc,
        offset: payloadOffset,
        prefixLength: start.length,
        payload: payload,
        rbsp: removeEmulationPrevention(
          Uint8List.sublistView(payload, 1),
          path,
          payloadOffset + 1,
        ),
      ),
    );
  }

  return List.unmodifiable(units);
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
    if (zeroCount > 3) {
      h264Invalid(
        path,
        'start codes may contain only two or three zero bytes',
        runStart,
      );
    }
    starts.add(_StartCode(offset: runStart, length: zeroCount + 1));
    requireH264(
      starts.length <= maximumNalUnits,
      path,
      'NAL-unit count exceeds the inspection budget',
      runStart,
    );
    cursor += 1;
  }
  return List.unmodifiable(starts);
}

/// Converts EBSP to RBSP while rejecting non-canonical escape sequences.
Uint8List removeEmulationPrevention(
  Uint8List ebsp,
  String path,
  int absoluteOffset,
) {
  requireH264(ebsp.isNotEmpty, path, 'NAL RBSP is empty', absoluteOffset);
  final rbsp = Uint8List(ebsp.length);
  var outputLength = 0;
  var zeroCount = 0;

  for (var index = 0; index < ebsp.length; index += 1) {
    final byte = ebsp[index];

    if (zeroCount == 2) {
      if (byte == 0x03) {
        final escapedIndex = index + 1;
        final escaped = escapedIndex < ebsp.length ? ebsp[escapedIndex] : null;
        requireH264(
          escaped != null && escaped <= 0x03,
          path,
          'emulation_prevention_three_byte is not followed by 0x00..0x03',
          absoluteOffset + index,
        );
        zeroCount = 0;
        continue;
      }
      requireH264(
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

  return Uint8List.sublistView(rbsp, 0, outputLength);
}

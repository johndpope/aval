/// Canonicalizes HEVC Annex-B access units to four-byte start codes and
/// derives access-unit inputs from an AUD-delimited encoder stream.
///
/// Dart port of `packages/format/src/h265/canonicalize.ts`.
library;

import 'dart:typed_data';

import '../checked_integer.dart' show maxSafeInteger;
import '../errors.dart';
import 'annex_b.dart'
    show
        H265_MAX_ACCESS_UNIT_BYTES,
        H265_NAL_AUD,
        H265_NAL_EOB,
        H265_NAL_EOS,
        H265_NAL_FILLER,
        H265_NAL_PREFIX_SEI,
        H265_NAL_SUFFIX_SEI,
        H265AnnexBNalUnit,
        H265AnnexBOptions,
        isH265RandomAccessNalType,
        isH265VclNalType,
        splitH265AnnexBAccessUnit;
import 'failure.dart';
import 'types.dart' show H265AccessUnitInput;

const List<int> _fourByteStartCode = [0, 0, 0, 1];

/// Removes encoder metadata and normalizes every retained NAL to a four-byte
/// Annex-B start code. No caller-owned byte view is retained.
///
/// Port of `canonicalizeH265AccessUnit` (`src/h265/canonicalize.ts:24`).
Uint8List canonicalizeH265AccessUnit(
  Uint8List bytes, [
  String path = 'accessUnit',
]) {
  final nals = splitH265AnnexBAccessUnit(
    bytes,
    path,
    const H265AnnexBOptions(allowEncoderMetadata: true),
  );
  return _canonicalizeNals(nals, path);
}

/// Splits an AUD-delimited raw libx265 stream into canonical access units.
///
/// Port of `canonicalizeH265EncoderUnitStream`
/// (`src/h265/canonicalize.ts:35`).
List<H265AccessUnitInput> canonicalizeH265EncoderUnitStream(
  Uint8List bytes,
  int expectedAccessUnitCount, [
  String path = 'encoderUnit',
]) {
  requireH265(
    expectedAccessUnitCount <= maxSafeInteger && expectedAccessUnitCount > 0,
    path,
    'expected access-unit count must be a positive safe integer',
  );
  final maximumNalUnits = expectedAccessUnitCount * 8 + 8;
  requireH265(
    maximumNalUnits <= maxSafeInteger,
    path,
    'derived NAL-unit budget is not representable',
  );
  final nals = splitH265AnnexBAccessUnit(
    bytes,
    path,
    H265AnnexBOptions(
      maximumBytes: H265_MAX_ACCESS_UNIT_BYTES,
      maximumNalUnits: maximumNalUnits,
      allowEncoderMetadata: true,
    ),
  );
  requireH265(
    nals.isNotEmpty && nals[0].type == H265_NAL_AUD,
    path,
    'raw HEVC encoder stream must begin with AUD',
  );
  final groups = <List<H265AnnexBNalUnit>>[];
  List<H265AnnexBNalUnit>? current;
  for (final nal in nals) {
    if (nal.type == H265_NAL_AUD) {
      if (current != null) groups.add(current);
      current = [nal];
    } else {
      requireH265(
        current != null,
        path,
        'NAL unit appears before the first AUD',
      );
      current!.add(nal);
    }
  }
  if (current != null) groups.add(current);
  requireH265(
    groups.length == expectedAccessUnitCount,
    path,
    'expected $expectedAccessUnitCount access units but found ${groups.length}',
  );
  final result = <H265AccessUnitInput>[];
  for (var index = 0; index < groups.length; index += 1) {
    final group = groups[index];
    final accessUnitPath = '$path.accessUnits[$index]';
    final accessUnitBytes = _canonicalizeNals(group, accessUnitPath);
    final vcl = group.where((nal) => isH265VclNalType(nal.type)).toList();
    requireH265(
      vcl.isNotEmpty,
      accessUnitPath,
      'access unit contains no coded picture',
    );
    result.add(
      H265AccessUnitInput(
        bytes: accessUnitBytes,
        key: vcl.any((nal) => isH265RandomAccessNalType(nal.type)),
      ),
    );
  }
  return List.unmodifiable(result);
}

Uint8List _canonicalizeNals(
  List<H265AnnexBNalUnit> nals,
  String path,
) {
  final retained = nals.where((nal) => !_isMetadataNal(nal.type)).toList();
  requireH265(retained.isNotEmpty, path, 'canonical access unit is empty');
  requireH265(
    retained[0].type == H265_NAL_AUD,
    path,
    'canonical access unit must begin with AUD',
  );
  requireH265(
    retained.any((nal) => isH265VclNalType(nal.type)),
    path,
    'canonical access unit contains no coded picture',
  );
  var length = 0;
  for (final nal in retained) {
    length += _fourByteStartCode.length + nal.payload.length;
    requireH265(
      length <= maxSafeInteger && length <= H265_MAX_ACCESS_UNIT_BYTES,
      path,
      'canonical HEVC access unit exceeds the byte budget',
    );
  }
  Uint8List output;
  try {
    output = Uint8List(length);
  } catch (_) {
    throw FormatError(
      FormatErrorCode.profileInvalid,
      'HEVC canonicalization allocation of $length bytes failed',
      FormatErrorDetails(path: path),
    );
  }
  var offset = 0;
  for (final nal in retained) {
    output.setAll(offset, _fourByteStartCode);
    offset += _fourByteStartCode.length;
    output.setAll(offset, nal.payload);
    offset += nal.payload.length;
  }
  return output;
}

bool _isMetadataNal(int type) {
  return type == H265_NAL_PREFIX_SEI ||
      type == H265_NAL_SUFFIX_SEI ||
      type == H265_NAL_FILLER ||
      type == H265_NAL_EOS ||
      type == H265_NAL_EOB;
}

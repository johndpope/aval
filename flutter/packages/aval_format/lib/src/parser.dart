/// Parses and completely validates version-0.1 aval assets.
///
/// Dart port of `packages/format/src/parser.ts`.
library;

import 'dart:typed_data';

import 'access_unit_index.dart' show parseAccessUnitIndex;
import 'canonical_json.dart' show parseCanonicalJson, serializeCanonicalJson;
import 'checked_integer.dart' show checkedAdd, requireByteRange;
import 'graph_adapter.dart' show adaptManifestToMotionGraph;
import 'header.dart' show parseHeader;
import 'layout.dart' show deriveCanonicalAssetLayout, validateZeroPadding;
import 'manifest_json.dart' show compiledManifestToJson;
import 'manifest_schema.dart' show validateCompiledManifestV01;
import 'reference_frame.dart' show ReferenceFrameValidationInput, validateReferenceFrame;
import 'errors.dart';
import 'model.dart';

const List<String> _headerFields = [
  'major',
  'minor',
  'headerLength',
  'requiredFeatureFlags',
  'declaredFileLength',
  'manifestOffset',
  'manifestLength',
  'indexOffset',
  'indexLength',
];

Never _rethrowAtFileOffset(Object error, int baseOffset) {
  if (error is FormatError) {
    throw FormatError(
      error.code,
      error.message,
      FormatErrorDetails(
        path: error.path,
        offset: error.offset == null ? null : baseOffset + error.offset!,
      ),
    );
  }
  throw error;
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Map<String, Object?> _headerFieldMap(FormatHeader header) => {
      'major': header.major,
      'minor': header.minor,
      'headerLength': header.headerLength,
      'requiredFeatureFlags': header.requiredFeatureFlags,
      'declaredFileLength': header.declaredFileLength,
      'manifestOffset': header.manifestOffset,
      'manifestLength': header.manifestLength,
      'indexOffset': header.indexOffset,
      'indexLength': header.indexLength,
    };

void _assertMatchingFrontIndex(
  ParsedFrontIndex supplied,
  ParsedFrontIndex reparsed, [
  FormatOptions? options,
]) {
  final suppliedFields = _headerFieldMap(supplied.header);
  final reparsedFields = _headerFieldMap(reparsed.header);
  for (final field in _headerFields) {
    if (suppliedFields[field] != reparsedFields[field]) {
      throw FormatError(
        FormatErrorCode.layoutInvalid,
        'supplied front index header field $field does not match the asset',
      );
    }
  }

  Uint8List suppliedManifestBytes;
  Uint8List reparsedManifestBytes;
  try {
    final suppliedManifest =
        validateCompiledManifestV01(compiledManifestToJson(supplied.manifest), options);
    suppliedManifestBytes = serializeCanonicalJson(compiledManifestToJson(suppliedManifest), options);
    reparsedManifestBytes = serializeCanonicalJson(compiledManifestToJson(reparsed.manifest), options);
  } on FormatError {
    throw FormatError(
      FormatErrorCode.layoutInvalid,
      'supplied front index manifest is not the asset manifest',
    );
  }
  if (!_bytesEqual(suppliedManifestBytes, reparsedManifestBytes)) {
    throw FormatError(
      FormatErrorCode.layoutInvalid,
      'supplied front index manifest does not match the asset',
    );
  }

  if (supplied.records.length != reparsed.records.length) {
    throw FormatError(
      FormatErrorCode.layoutInvalid,
      'supplied front index record count does not match the asset',
    );
  }
  for (var index = 0; index < reparsed.records.length; index += 1) {
    final suppliedRecord = supplied.records[index];
    final reparsedRecord = reparsed.records[index];
    if (suppliedRecord.payloadOffset != reparsedRecord.payloadOffset ||
        suppliedRecord.payloadLength != reparsedRecord.payloadLength ||
        suppliedRecord.unitIndex != reparsedRecord.unitIndex ||
        suppliedRecord.renditionIndex != reparsedRecord.renditionIndex ||
        suppliedRecord.key != reparsedRecord.key ||
        suppliedRecord.frameIndex != reparsedRecord.frameIndex) {
      throw FormatError(
        FormatErrorCode.layoutInvalid,
        'supplied front index record $index field does not match the asset',
      );
    }
  }
}

CompiledManifestV01 _parseManifest(Uint8List bytes, FormatHeader header, [FormatOptions? options]) {
  final end = requireByteRange(
    bytes,
    header.manifestOffset,
    header.manifestLength,
    FormatErrorCode.jsonInvalid,
    'manifest',
  );
  Object? parsed;
  try {
    parsed = parseCanonicalJson(bytes.sublist(header.manifestOffset, end), options);
  } catch (error) {
    _rethrowAtFileOffset(error, header.manifestOffset);
  }
  return validateCompiledManifestV01(parsed, options);
}

/// Parses exactly the bounded metadata prefix needed to route and
/// range-load an asset. Payload bytes, when present in the input view, are
/// ignored.
ParsedFrontIndex parseFrontIndex(Uint8List bytesFromFileStart, [FormatOptions? options]) {
  try {
    final header = parseHeader(bytesFromFileStart, options);
    final frontIndexEnd = checkedAdd(
      header.indexOffset,
      header.indexLength,
      header.declaredFileLength,
      'front index end',
    );
    if (bytesFromFileStart.length < frontIndexEnd) {
      throw FormatError(
        FormatErrorCode.indexInvalid,
        'front index is truncated',
        FormatErrorDetails(offset: bytesFromFileStart.length),
      );
    }

    final manifest = _parseManifest(bytesFromFileStart, header, options);
    final manifestEnd = checkedAdd(
      header.manifestOffset,
      header.manifestLength,
      header.indexOffset,
      'manifest end',
    );
    validateZeroPadding(bytesFromFileStart, [
      ByteRange(offset: manifestEnd, length: header.indexOffset - manifestEnd),
    ]);

    List<AccessUnitRecord> records;
    try {
      records = parseAccessUnitIndex(
        Uint8List.sublistView(bytesFromFileStart, header.indexOffset, frontIndexEnd),
        manifest,
        options,
      );
    } catch (error) {
      _rethrowAtFileOffset(error, header.indexOffset);
    }

    final graph = adaptManifestToMotionGraph(manifest);
    final layout = deriveCanonicalAssetLayout(header, manifest, records, options);
    return ParsedFrontIndex(
      header: header,
      manifest: manifest,
      graph: graph,
      records: records,
      frontIndexRange: layout.frontIndexRange,
      unitBlobs: layout.unitBlobs,
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.inputInvalid, 'front index could not be parsed');
  }
}

void _validatePayloadProfiles(Uint8List bytes, ParsedFrontIndex frontIndex, [FormatOptions? options]) {
  for (final record in frontIndex.records) {
    final rendition = record.renditionIndex < frontIndex.manifest.renditions.length
        ? frontIndex.manifest.renditions[record.renditionIndex]
        : null;
    if (rendition is! ReferenceRgbaRenditionV01) continue;
    final sampleEnd =
        checkedAdd(record.payloadOffset, record.payloadLength, bytes.length, 'reference sample end');
    try {
      validateReferenceFrame(ReferenceFrameValidationInput(
        sample: Uint8List.sublistView(bytes, record.payloadOffset, sampleEnd),
        expectedWidth: rendition.codedWidth,
        expectedHeight: rendition.codedHeight,
        expectedFrameIndex: record.frameIndex,
        options: options,
      ));
    } catch (error) {
      _rethrowAtFileOffset(error, record.payloadOffset);
    }
  }
}

/// Reparses and completely validates one exact, caller-owned asset byte
/// array.
ValidatedAssetLayout validateCompleteAsset({
  required Uint8List bytes,
  ParsedFrontIndex? frontIndex,
  FormatOptions? options,
}) {
  try {
    final reparsed = parseFrontIndex(bytes, options);
    if (bytes.length != reparsed.header.declaredFileLength) {
      throw FormatError(
        FormatErrorCode.layoutInvalid,
        bytes.length < reparsed.header.declaredFileLength
            ? 'asset bytes are truncated'
            : 'asset contains bytes beyond the declared file length',
        FormatErrorDetails(
          offset: bytes.length < reparsed.header.declaredFileLength
              ? bytes.length
              : reparsed.header.declaredFileLength,
        ),
      );
    }
    if (frontIndex != null) {
      _assertMatchingFrontIndex(frontIndex, reparsed, options);
    }

    final layout = deriveCanonicalAssetLayout(reparsed.header, reparsed.manifest, reparsed.records, options);
    validateZeroPadding(bytes, layout.paddingRanges);
    _validatePayloadProfiles(bytes, reparsed, options);

    return ValidatedAssetLayout(frontIndex: reparsed, fileRange: layout.fileRange);
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.inputInvalid, 'complete asset could not be validated');
  }
}

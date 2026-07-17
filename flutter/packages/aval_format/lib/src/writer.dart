/// Writes one byte-canonical version-1.0 aval asset.
///
/// Dart port of `packages/format/src/writer.ts`.
library;

import 'dart:typed_data';

import 'access_unit_index.dart' show encodeEncodedChunkIndex;
import 'canonical_json.dart' show serializeCanonicalJson;
import 'constants.dart' show formatHeaderLength;
import 'errors.dart';
import 'header.dart' show encodeHeader;
import 'layout.dart' show ChunkPayloadShape, planCanonicalAssetLayout;
import 'manifest_json.dart' show compiledManifestToJson;
import 'model.dart';
import 'parser.dart' show validateCompleteAsset;
import 'writer_normalize.dart' show NormalizedWriterInput, normalizeWriterInput;

class _WriterLayout {
  const _WriterLayout({
    required this.indexOffset,
    required this.indexLength,
    required this.records,
    required this.fileLength,
  });

  final int indexOffset;
  final int indexLength;
  final List<EncodedChunkRecord> records;
  final int fileLength;
}

/// Writes one byte-canonical version-1.0 aval asset.
Uint8List writeCanonicalAsset(CanonicalAssetInput input, [FormatOptions? options]) {
  try {
    final normalized = normalizeWriterInput(input, options);
    final manifest = normalized.manifest;
    final manifestBytes = serializeCanonicalJson(compiledManifestToJson(manifest), options);
    final finalLayout = _deriveLayout(normalized, manifest, manifestBytes, options);

    final header = FormatHeader(
      declaredFileLength: finalLayout.fileLength,
      manifestLength: manifestBytes.length,
      indexOffset: finalLayout.indexOffset,
      indexLength: finalLayout.indexLength,
    );
    final headerBytes = encodeHeader(header, options);
    final indexBytes = encodeEncodedChunkIndex(finalLayout.records, manifest, options);
    if (indexBytes.length != finalLayout.indexLength) {
      throw FormatError(FormatErrorCode.writerInvalid, 'encoded index length changed');
    }

    Uint8List bytes;
    try {
      bytes = Uint8List(finalLayout.fileLength);
    } catch (_) {
      throw FormatError(
        FormatErrorCode.writerInvalid,
        'final file allocation of ${finalLayout.fileLength} bytes failed',
      );
    }
    bytes.setRange(0, headerBytes.length, headerBytes);
    bytes.setRange(formatHeaderLength, formatHeaderLength + manifestBytes.length, manifestBytes);
    bytes.setRange(finalLayout.indexOffset, finalLayout.indexOffset + indexBytes.length, indexBytes);

    for (var index = 0; index < normalized.chunks.length; index += 1) {
      final payload = normalized.chunks[index];
      final record = index < finalLayout.records.length ? finalLayout.records[index] : null;
      if (record == null) {
        throw FormatError(FormatErrorCode.writerInvalid, 'encoded-chunk layout is sparse');
      }
      bytes.setRange(record.byteOffset, record.byteOffset + payload.bytes.length, payload.bytes);
    }
    validateCompleteAsset(bytes: bytes, options: options);
    return bytes;
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.writerInvalid, 'canonical asset could not be written');
  }
}

_WriterLayout _deriveLayout(
  NormalizedWriterInput normalized,
  CompiledManifest manifest,
  Uint8List manifestBytes, [
  FormatOptions? options,
]) {
  final plan = planCanonicalAssetLayout(
    manifestBytes.length,
    manifest,
    normalized.chunks
        .map((chunk) => ChunkPayloadShape(
              byteLength: chunk.bytes.length,
              presentationTimestamp: chunk.presentationTimestamp,
              duration: chunk.duration,
              randomAccess: chunk.randomAccess,
              displayedFrameCount: chunk.displayedFrameCount,
            ))
        .toList(),
    options,
  );
  return _WriterLayout(
    indexOffset: plan.indexOffset,
    indexLength: plan.indexLength,
    records: plan.records,
    fileLength: plan.fileRange.length,
  );
}

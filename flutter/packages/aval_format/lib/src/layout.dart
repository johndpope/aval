/// Canonical version-1.0 asset byte-layout derivation.
///
/// Dart port of `packages/format/src/layout.ts`.
library;

import 'dart:typed_data';

import 'checked_integer.dart';
import 'chunk_plan.dart';
import 'constants.dart';
import 'errors.dart';
import 'model.dart';

class CanonicalAssetLayout {
  const CanonicalAssetLayout({
    required this.frontIndexRange,
    required this.unitBlobs,
    required this.paddingRanges,
    required this.fileRange,
  });

  final ByteRange frontIndexRange;
  final List<UnitBlobRange> unitBlobs;
  final List<ByteRange> paddingRanges;
  final ByteRange fileRange;
}

/// Structural counterpart of the TS `ChunkPayloadShape` interface: the exact
/// per-chunk fields the layout planner needs. `EncodedChunkRecord` satisfies
/// this shape; the writer builds one per encoded payload.
class ChunkPayloadShape {
  const ChunkPayloadShape({
    required this.byteLength,
    required this.presentationTimestamp,
    required this.duration,
    required this.randomAccess,
    required this.displayedFrameCount,
  });

  final int byteLength;
  final int presentationTimestamp;
  final int duration;
  final bool randomAccess;
  final int displayedFrameCount;
}

class CanonicalAssetPlan extends CanonicalAssetLayout {
  const CanonicalAssetPlan({
    required this.indexOffset,
    required this.indexLength,
    required this.records,
    required super.frontIndexRange,
    required super.unitBlobs,
    required super.paddingRanges,
    required super.fileRange,
  });

  final int indexOffset;
  final int indexLength;
  final List<EncodedChunkRecord> records;
}

Never _fail(String message, [FormatErrorDetails? details]) {
  throw FormatError(FormatErrorCode.layoutInvalid, message, details);
}

ByteRange _freezeRange(int offset, int length) =>
    ByteRange(offset: offset, length: length);

void _addPaddingRange(List<ByteRange> ranges, int offset, int end) {
  if (end > offset) ranges.add(_freezeRange(offset, end - offset));
}

/// Build the sole legal 1.0 file layout from bounded chunk descriptors.
CanonicalAssetPlan planCanonicalAssetLayout(
  int manifestLength,
  CompiledManifest manifest,
  List<ChunkPayloadShape> chunks, [
  FormatOptions? options,
]) {
  try {
    final budgets = resolveFormatBudgets(options);
    final chunkPlan = createCanonicalChunkPlan(
      manifest.renditions,
      manifest.units,
      budgets.maxChunkRecords,
      budgets.maxTotalUnitFrames,
    );
    validateCanonicalChunkSpans(chunkPlan, manifest.units);
    if (chunks.length != chunkPlan.recordCount) {
      _fail(
          'encoded-chunk payload count must be ${chunkPlan.recordCount}, received ${chunks.length}');
    }
    if (chunkPlan.spans.length > budgets.maxBlobRanges) {
      throw FormatError(FormatErrorCode.budgetExceeded,
          'canonical blob range count exceeds the active budget');
    }
    if (manifestLength > budgets.maxManifestBytes) {
      throw FormatError(
        FormatErrorCode.budgetExceeded,
        'manifest length exceeds the active limit of ${budgets.maxManifestBytes}',
      );
    }
    final manifestEnd =
        checkedAdd(formatHeaderLength, manifestLength, budgets.maxFileBytes, 'manifest end');
    final indexOffset =
        align8(manifestEnd, budgets.maxFileBytes, 'encoded-chunk index offset');
    final indexLength = checkedAdd(
      chunkIndexHeaderLength,
      checkedMultiply(
        chunkPlan.recordCount,
        chunkIndexRecordLength,
        budgets.maxIndexBytes,
        'encoded-chunk records length',
      ),
      budgets.maxIndexBytes,
      'encoded-chunk index length',
    );
    final frontIndexEnd =
        checkedAdd(indexOffset, indexLength, budgets.maxFileBytes, 'front index end');

    final paddingRanges = <ByteRange>[];
    _addPaddingRange(paddingRanges, manifestEnd, indexOffset);
    final records = <EncodedChunkRecord>[];
    final unitBlobs = <UnitBlobRange>[];
    var cursor = frontIndexEnd;
    for (final span in chunkPlan.spans) {
      final aligned = align8(cursor, budgets.maxFileBytes, 'unit blob offset');
      _addPaddingRange(paddingRanges, cursor, aligned);
      cursor = aligned;
      final blobOffset = cursor;
      final unit =
          span.unitIndex < manifest.units.length ? manifest.units[span.unitIndex] : null;
      final descriptor =
          unit != null && span.renditionIndex < unit.chunks.length
              ? unit.chunks[span.renditionIndex]
              : null;
      if (unit == null || descriptor == null) {
        _fail('canonical unit chunk descriptor is missing');
      }
      final spanEnd = checkedAdd(
        span.chunkStart,
        span.chunkCount,
        chunkPlan.recordCount,
        'chunk span end',
      );
      var displayedFrames = 0;
      for (var ordinal = span.chunkStart; ordinal < spanEnd; ordinal += 1) {
        final slot = chunkPlan.recordAt(ordinal);
        final chunk = ordinal < chunks.length ? chunks[ordinal] : null;
        if (chunk == null) _fail('canonical encoded-chunk payload is missing');
        if (chunk.byteLength < 1 || chunk.byteLength > maxSafeInteger) {
          _fail('encoded-chunk byte length must be a positive safe integer');
        }
        if (chunk.byteLength > budgets.maxChunkBytes) {
          throw FormatError(
            FormatErrorCode.budgetExceeded,
            'encoded-chunk byte length exceeds the active limit of ${budgets.maxChunkBytes}',
          );
        }
        if (slot.randomAccessRequired && !chunk.randomAccess) {
          _fail('every unit must begin with a random-access chunk');
        }
        if (chunk.presentationTimestamp < 0 ||
            chunk.presentationTimestamp > maxSafeInteger ||
            chunk.duration < 0 ||
            chunk.duration > maxSafeInteger ||
            chunk.displayedFrameCount < 0 ||
            chunk.displayedFrameCount > maxSafeInteger) {
          _fail('encoded-chunk timeline fields must be nonnegative safe integers');
        }
        if (chunk.displayedFrameCount > 0 && chunk.duration == 0) {
          _fail('a displayed encoded chunk must have a positive duration');
        }
        displayedFrames = checkedAdd(
          displayedFrames,
          chunk.displayedFrameCount,
          budgets.maxTotalUnitFrames,
          'unit displayed frame count',
        );
        records.add(EncodedChunkRecord(
          byteOffset: cursor,
          byteLength: chunk.byteLength,
          presentationTimestamp: chunk.presentationTimestamp,
          duration: chunk.duration,
          randomAccess: chunk.randomAccess,
          displayedFrameCount: chunk.displayedFrameCount,
        ));
        cursor = checkedAdd(
          cursor,
          chunk.byteLength,
          budgets.maxFileBytes,
          'encoded-chunk payload end',
        );
      }
      if (displayedFrames != span.frameCount) {
        _fail(
            'unit ${span.unitId} rendition ${span.renditionId} must display exactly ${span.frameCount} frames');
      }
      unitBlobs.add(UnitBlobRange(
        rendition: span.renditionId,
        unit: span.unitId,
        chunkStart: span.chunkStart,
        chunkCount: span.chunkCount,
        frameCount: span.frameCount,
        sha256: descriptor.sha256,
        offset: blobOffset,
        length: cursor - blobOffset,
      ));
    }
    if (cursor > manifest.limits.maxCompiledBytes) {
      throw FormatError(
        FormatErrorCode.budgetExceeded,
        'compiled file exceeds manifest limits.maxCompiledBytes',
        const FormatErrorDetails(path: 'limits.maxCompiledBytes'),
      );
    }
    return CanonicalAssetPlan(
      indexOffset: indexOffset,
      indexLength: indexLength,
      records: records,
      frontIndexRange: _freezeRange(0, frontIndexEnd),
      unitBlobs: unitBlobs,
      paddingRanges: paddingRanges,
      fileRange: _freezeRange(0, cursor),
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
        FormatErrorCode.layoutInvalid, 'canonical asset layout could not be planned');
  }
}

/// Derive and validate the sole legal 1.0 byte layout.
CanonicalAssetLayout deriveCanonicalAssetLayout(
  FormatHeader header,
  CompiledManifest manifest,
  List<EncodedChunkRecord> records, [
  FormatOptions? options,
]) {
  try {
    final plan = planCanonicalAssetLayout(
      header.manifestLength,
      manifest,
      records
          .map((r) => ChunkPayloadShape(
                byteLength: r.byteLength,
                presentationTimestamp: r.presentationTimestamp,
                duration: r.duration,
                randomAccess: r.randomAccess,
                displayedFrameCount: r.displayedFrameCount,
              ))
          .toList(),
      options,
    );
    if (header.manifestOffset != formatHeaderLength) {
      _fail('manifest offset is not canonical',
          FormatErrorDetails(offset: header.manifestOffset));
    }
    if (header.indexOffset != plan.indexOffset) {
      _fail('encoded-chunk index offset is not canonical',
          FormatErrorDetails(offset: header.indexOffset));
    }
    if (header.indexLength != plan.indexLength) {
      _fail('encoded-chunk index length is not canonical',
          FormatErrorDetails(offset: header.indexOffset));
    }
    if (header.declaredFileLength != plan.fileRange.length) {
      _fail(
        header.declaredFileLength > plan.fileRange.length
            ? 'declared file contains trailing bytes'
            : 'payload layout extends beyond the declared file',
        FormatErrorDetails(
            offset: header.declaredFileLength < plan.fileRange.length
                ? header.declaredFileLength
                : plan.fileRange.length),
      );
    }
    for (var index = 0; index < plan.records.length; index += 1) {
      final actual = index < records.length ? records[index] : null;
      final expected = plan.records[index];
      if (actual == null ||
          actual.byteOffset != expected.byteOffset ||
          actual.byteLength != expected.byteLength ||
          actual.presentationTimestamp != expected.presentationTimestamp ||
          actual.duration != expected.duration ||
          actual.randomAccess != expected.randomAccess ||
          actual.displayedFrameCount != expected.displayedFrameCount) {
        _fail('encoded-chunk record is not canonical',
            FormatErrorDetails(offset: actual?.byteOffset ?? header.indexOffset));
      }
    }
    return CanonicalAssetLayout(
      frontIndexRange: plan.frontIndexRange,
      unitBlobs: plan.unitBlobs,
      paddingRanges: plan.paddingRanges,
      fileRange: plan.fileRange,
    );
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.layoutInvalid, 'asset layout could not be derived');
  }
}

void validateZeroPadding(Uint8List bytes, List<ByteRange> ranges) {
  try {
    for (final range in ranges) {
      final end =
          checkedAdd(range.offset, range.length, bytes.lengthInBytes, 'padding range end');
      for (var offset = range.offset; offset < end; offset += 1) {
        if (bytes[offset] != 0) {
          _fail('alignment padding must contain only zero bytes',
              FormatErrorDetails(offset: offset));
        }
      }
    }
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.layoutInvalid, 'asset padding could not be validated');
  }
}

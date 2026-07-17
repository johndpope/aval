/// Fixed-record version-1.0 decode-order encoded-chunk index codec.
///
/// Dart port of `packages/format/src/access-unit-index.ts`.
library;

import 'dart:typed_data';

import 'checked_integer.dart';
import 'chunk_plan.dart';
import 'constants.dart';
import 'errors.dart';
import 'model.dart';

const int _randomAccessFlag = 0x00000001;

int _recordByteOffset(int ordinal, int maximum) {
  return checkedAdd(
    chunkIndexHeaderLength,
    checkedMultiply(ordinal, chunkIndexRecordLength, maximum, 'encoded-chunk record offset'),
    maximum,
    'encoded-chunk record offset',
  );
}

Never _fail(String message, [int? offset]) {
  throw FormatError(
    FormatErrorCode.indexInvalid,
    message,
    offset == null ? null : FormatErrorDetails(offset: offset),
  );
}

void _assertMagic(Uint8List bytes) {
  for (var index = 0; index < chunkIndexMagic.length; index += 1) {
    if (bytes[index] != chunkIndexMagic[index]) {
      _fail('encoded-chunk index magic must be AVLI', index);
    }
  }
}

CanonicalChunkPlan _canonicalChunkPlan(
  CompiledManifest manifest, [
  FormatOptions? options,
]) {
  final budgets = resolveFormatBudgets(options);
  try {
    return createCanonicalChunkPlan(
      manifest.renditions,
      manifest.units,
      budgets.maxChunkRecords,
      budgets.maxTotalUnitFrames,
    );
  } on FormatError catch (error) {
    if (error.code == FormatErrorCode.budgetExceeded ||
        error.code == FormatErrorCode.integerUnsafe) {
      rethrow;
    }
    throw FormatError(
      FormatErrorCode.indexInvalid,
      error.message,
      error.path == null ? null : FormatErrorDetails(path: error.path),
    );
  } catch (_) {
    _fail('manifest chunk plan could not be derived');
  }
}

void _validateRecordSequence(
  List<EncodedChunkRecord> records,
  CanonicalChunkPlan plan, [
  FormatOptions? options,
]) {
  final budgets = resolveFormatBudgets(options);
  if (records.length != plan.recordCount) {
    _fail(
      'encoded-chunk record count must be ${plan.recordCount}, received ${records.length}',
      8,
    );
  }

  for (final span in plan.spans) {
    var displayedFrames = 0;
    final end = span.chunkStart + span.chunkCount;
    for (var ordinal = span.chunkStart; ordinal < end; ordinal += 1) {
      final record = ordinal < records.length ? records[ordinal] : null;
      final offset = _recordByteOffset(ordinal, budgets.maxIndexBytes);
      if (record == null) _fail('encoded-chunk record is missing', offset);
      if (record.byteLength < 1) {
        _fail('encoded-chunk byte length must be positive', offset + 8);
      }
      if (record.byteLength > budgets.maxChunkBytes) {
        throw FormatError(
          FormatErrorCode.budgetExceeded,
          'encoded-chunk byte length exceeds the active limit of ${budgets.maxChunkBytes}',
          FormatErrorDetails(offset: offset + 8),
        );
      }
      if (ordinal == span.chunkStart && !record.randomAccess) {
        _fail('every unit must begin with a random-access chunk', offset + 32);
      }
      if (record.displayedFrameCount > 0 && record.duration == 0) {
        _fail('a displayed encoded chunk must have a positive duration', offset + 24);
      }
      final lastTimestamp = BigInt.from(record.presentationTimestamp) +
          BigInt.from(record.duration) *
              BigInt.from(record.displayedFrameCount - 1 > 0
                  ? record.displayedFrameCount - 1
                  : 0);
      if (lastTimestamp > BigInt.from(maxSafeInteger)) {
        _fail('encoded-chunk presentation timeline exceeds the safe integer range',
            offset + 16);
      }
      displayedFrames = checkedAdd(
        displayedFrames,
        record.displayedFrameCount,
        budgets.maxTotalUnitFrames,
        'unit displayed frame count',
      );
    }
    if (displayedFrames != span.frameCount) {
      _fail(
        'unit ${span.unitId} rendition ${span.renditionId} must display exactly ${span.frameCount} frames',
        _recordByteOffset(span.chunkStart, budgets.maxIndexBytes) + 12,
      );
    }
  }
}

EncodedChunkRecord _parseRecord(Uint8List bytes, int ordinal, [FormatOptions? options]) {
  final budgets = resolveFormatBudgets(options);
  final offset = _recordByteOffset(ordinal, budgets.maxIndexBytes);
  final byteOffset = readUint64LE(
    bytes,
    offset,
    budgets.maxFileBytes,
    FormatErrorCode.indexInvalid,
    'encoded-chunk byte offset',
  );
  final byteLength =
      readUint32LE(bytes, offset + 8, FormatErrorCode.indexInvalid, 'encoded-chunk byte length');
  final displayedFrameCount = readUint32LE(
      bytes, offset + 12, FormatErrorCode.indexInvalid, 'encoded-chunk displayed frame count');
  final presentationTimestamp = readUint64LE(
    bytes,
    offset + 16,
    maxSafeInteger,
    FormatErrorCode.indexInvalid,
    'encoded-chunk presentation timestamp',
  );
  final duration = readUint64LE(
    bytes,
    offset + 24,
    maxSafeInteger,
    FormatErrorCode.indexInvalid,
    'encoded-chunk duration',
  );
  final flags =
      readUint32LE(bytes, offset + 32, FormatErrorCode.indexInvalid, 'encoded-chunk flags');
  if ((flags & ~_randomAccessFlag) != 0) {
    _fail('encoded-chunk record uses unknown flag bits', offset + 32);
  }
  for (var reserved = offset + 36; reserved < offset + 48; reserved += 1) {
    if (bytes[reserved] != 0) {
      _fail('encoded-chunk record reserved bytes must be zero', reserved);
    }
  }
  return EncodedChunkRecord(
    byteOffset: byteOffset,
    byteLength: byteLength,
    presentationTimestamp: presentationTimestamp,
    duration: duration,
    randomAccess: (flags & _randomAccessFlag) != 0,
    displayedFrameCount: displayedFrameCount,
  );
}

/// Parse the exact fixed-width 1.0 decode-order chunk index.
List<EncodedChunkRecord> parseEncodedChunkIndex(
  Uint8List bytes,
  CompiledManifest manifest, [
  FormatOptions? options,
]) {
  try {
    final budgets = resolveFormatBudgets(options);
    requireByteRange(
      bytes,
      0,
      chunkIndexHeaderLength,
      FormatErrorCode.indexInvalid,
      'encoded-chunk index header',
    );
    _assertMagic(bytes);
    final recordSize =
        readUint16LE(bytes, 4, FormatErrorCode.indexInvalid, 'encoded-chunk record size');
    if (recordSize != chunkIndexRecordLength) {
      _fail('encoded-chunk record size must be $chunkIndexRecordLength', 4);
    }
    if (readUint16LE(bytes, 6, FormatErrorCode.indexInvalid, 'index reserved field') != 0) {
      _fail('encoded-chunk index reserved field must be zero', 6);
    }
    final chunkCount =
        readUint32LE(bytes, 8, FormatErrorCode.indexInvalid, 'encoded-chunk count');
    if (readUint32LE(bytes, 12, FormatErrorCode.indexInvalid, 'index reserved field') != 0) {
      _fail('encoded-chunk index reserved field must be zero', 12);
    }
    if (chunkCount > budgets.maxChunkRecords) {
      throw FormatError(
        FormatErrorCode.budgetExceeded,
        'encoded-chunk count exceeds the active limit of ${budgets.maxChunkRecords}',
        const FormatErrorDetails(offset: 8),
      );
    }
    final expectedLength = checkedAdd(
      chunkIndexHeaderLength,
      checkedMultiply(
        chunkCount,
        chunkIndexRecordLength,
        budgets.maxIndexBytes,
        'encoded-chunk records length',
      ),
      budgets.maxIndexBytes,
      'encoded-chunk index length',
    );
    if (bytes.length != expectedLength) {
      _fail(
        'encoded-chunk index length must be exactly $expectedLength bytes',
        bytes.length < expectedLength ? bytes.length : expectedLength,
      );
    }
    final plan = _canonicalChunkPlan(manifest, options);
    if (chunkCount != plan.recordCount) {
      _fail('encoded-chunk count must match the manifest count of ${plan.recordCount}', 8);
    }
    final records = <EncodedChunkRecord>[];
    for (var ordinal = 0; ordinal < chunkCount; ordinal += 1) {
      records.add(_parseRecord(bytes, ordinal, options));
    }
    _validateRecordSequence(records, plan, options);
    return records;
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
        FormatErrorCode.indexInvalid, 'encoded-chunk index could not be parsed');
  }
}

/// Encode the exact fixed-width 1.0 decode-order chunk index.
Uint8List encodeEncodedChunkIndex(
  List<EncodedChunkRecord> records,
  CompiledManifest manifest, [
  FormatOptions? options,
]) {
  try {
    final budgets = resolveFormatBudgets(options);
    if (records.length > budgets.maxChunkRecords) {
      throw FormatError(
        FormatErrorCode.budgetExceeded,
        'encoded-chunk count exceeds the active limit',
        const FormatErrorDetails(offset: 8),
      );
    }
    final length = checkedAdd(
      chunkIndexHeaderLength,
      checkedMultiply(
        records.length,
        chunkIndexRecordLength,
        budgets.maxIndexBytes,
        'encoded-chunk records length',
      ),
      budgets.maxIndexBytes,
      'encoded-chunk index length',
    );
    final bytes = Uint8List(length);
    bytes.setRange(0, chunkIndexMagic.length, chunkIndexMagic);
    writeUint16LE(bytes, 4, chunkIndexRecordLength, FormatErrorCode.indexInvalid,
        'encoded-chunk record size');
    writeUint16LE(bytes, 6, 0, FormatErrorCode.indexInvalid, 'index reserved field');
    writeUint32LE(bytes, 8, records.length, FormatErrorCode.indexInvalid, 'encoded-chunk count');
    writeUint32LE(bytes, 12, 0, FormatErrorCode.indexInvalid, 'index reserved field');

    for (var ordinal = 0; ordinal < records.length; ordinal += 1) {
      final record = records[ordinal];
      final offset = _recordByteOffset(ordinal, budgets.maxIndexBytes);
      writeUint64LE(bytes, offset, record.byteOffset, FormatErrorCode.indexInvalid,
          'encoded-chunk byte offset');
      writeUint32LE(bytes, offset + 8, record.byteLength, FormatErrorCode.indexInvalid,
          'encoded-chunk byte length');
      writeUint32LE(bytes, offset + 12, record.displayedFrameCount,
          FormatErrorCode.indexInvalid, 'encoded-chunk displayed frame count');
      writeUint64LE(bytes, offset + 16, record.presentationTimestamp,
          FormatErrorCode.indexInvalid, 'encoded-chunk presentation timestamp');
      writeUint64LE(bytes, offset + 24, record.duration, FormatErrorCode.indexInvalid,
          'encoded-chunk duration');
      writeUint32LE(bytes, offset + 32, record.randomAccess ? _randomAccessFlag : 0,
          FormatErrorCode.indexInvalid, 'encoded-chunk flags');
    }
    parseEncodedChunkIndex(bytes, manifest, options);
    return bytes;
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
        FormatErrorCode.indexInvalid, 'encoded-chunk index could not be encoded');
  }
}

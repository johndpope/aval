/// Fixed-record version-0.1 access-unit index codec.
///
/// Dart port of `packages/format/src/access-unit-index.ts`.
library;

import 'dart:typed_data';

import 'checked_integer.dart';
import 'constants.dart';
import 'errors.dart';
import 'model.dart';
import 'sample_plan.dart';

const int _keyFlag = 0x0001;

int _recordByteOffset(int ordinal, int maximum) {
  return checkedAdd(
    accessUnitIndexHeaderLength,
    checkedMultiply(ordinal, accessUnitRecordLength, maximum, 'access-unit record offset'),
    maximum,
    'access-unit record offset',
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
  for (var index = 0; index < accessUnitIndexMagic.length; index += 1) {
    if (bytes[index] != accessUnitIndexMagic[index]) {
      _fail('access-unit index magic must be AVLI', index);
    }
  }
}

CanonicalSamplePlan _canonicalSamplePlan(
  CompiledManifestV01 manifest,
  int maximum,
  int maximumTotalFrames,
) {
  try {
    final plan = createCanonicalSamplePlan(
      manifest.renditions.map((r) => PlanRendition(id: r.id, profile: r.profile)).toList(),
      manifest.units.map((u) => PlanUnit(id: u.id, frameCount: u.frameCount)).toList(),
      maximum,
      maximumTotalFrames,
    );
    validateCanonicalSampleSpans(plan, manifest.units, FormatErrorCode.indexInvalid);
    return plan;
  } on FormatError catch (error) {
    if (error.code == FormatErrorCode.budgetExceeded || error.code == FormatErrorCode.integerUnsafe) {
      rethrow;
    }
    throw FormatError(
      FormatErrorCode.indexInvalid,
      error.message,
      error.path == null ? null : FormatErrorDetails(path: error.path),
    );
  } catch (_) {
    _fail('manifest sample plan could not be derived');
  }
}

void _validateRecordSequence(
  List<AccessUnitRecord> records,
  CompiledManifestV01 manifest,
  CanonicalSamplePlan plan, [
  FormatOptions? options,
]) {
  final budgets = resolveFormatBudgets(options);
  final expectedCount = plan.recordCount;
  if (records.length != expectedCount) {
    _fail('access-unit record count must be $expectedCount, received ${records.length}', 8);
  }

  for (final slot in plan.records()) {
    final record = slot.ordinal < records.length ? records[slot.ordinal] : null;
    final recordOffset = _recordByteOffset(slot.ordinal, budgets.maxIndexBytes);
    if (record == null) {
      _fail('access-unit record is missing', recordOffset);
    }
    if (record.renditionIndex != slot.renditionIndex ||
        record.unitIndex != slot.unitIndex ||
        record.frameIndex != slot.frameIndex) {
      _fail('access-unit records must be ordered by rendition, unit, then frame', recordOffset + 12);
    }
    if (record.payloadLength < 1) {
      _fail('access-unit payload length must be positive', recordOffset + 8);
    }
    if (record.payloadLength > budgets.maxSampleBytes) {
      throw FormatError(
        FormatErrorCode.budgetExceeded,
        'access-unit payload length exceeds the active limit of ${budgets.maxSampleBytes}',
        FormatErrorDetails(offset: recordOffset + 8),
      );
    }
    if (slot.keyRequired && !record.key) {
      _fail(
        slot.frameIndex == 0
            ? 'frame zero of every unit must be marked key'
            : 'every reference-rgba-v0 access unit must be marked key',
        recordOffset + 18,
      );
    }
  }
}

AccessUnitRecord _parseRecord(Uint8List bytes, int ordinal, [FormatOptions? options]) {
  final budgets = resolveFormatBudgets(options);
  final offset = _recordByteOffset(ordinal, budgets.maxIndexBytes);
  final payloadOffset = readUint64LE(
    bytes,
    offset,
    budgets.maxFileBytes,
    FormatErrorCode.indexInvalid,
    'access-unit payload offset',
  );
  final payloadLength =
      readUint32LE(bytes, offset + 8, FormatErrorCode.indexInvalid, 'access-unit payload length');
  final unitIndex =
      readUint32LE(bytes, offset + 12, FormatErrorCode.indexInvalid, 'access-unit unit index');
  final renditionIndex =
      readUint16LE(bytes, offset + 16, FormatErrorCode.indexInvalid, 'access-unit rendition index');
  final flags = readUint16LE(bytes, offset + 18, FormatErrorCode.indexInvalid, 'access-unit flags');
  if ((flags & ~_keyFlag) != 0) {
    _fail('access-unit record uses unknown flag bits', offset + 18);
  }
  final frameIndex =
      readUint32LE(bytes, offset + 20, FormatErrorCode.indexInvalid, 'access-unit frame index');
  for (var reserved = offset + 24; reserved < offset + 32; reserved += 1) {
    if (bytes[reserved] != 0) {
      _fail('access-unit record reserved bytes must be zero', reserved);
    }
  }

  return AccessUnitRecord(
    payloadOffset: payloadOffset,
    payloadLength: payloadLength,
    unitIndex: unitIndex,
    renditionIndex: renditionIndex,
    key: (flags & _keyFlag) != 0,
    frameIndex: frameIndex,
  );
}

/// Parses one exact version-0.1 access-unit index view.
///
/// The supplied view must contain the index and nothing else. The returned
/// records are detached numeric metadata and retain no input bytes.
List<AccessUnitRecord> parseAccessUnitIndex(
  Uint8List bytes,
  CompiledManifestV01 manifest, [
  FormatOptions? options,
]) {
  try {
    final budgets = resolveFormatBudgets(options);
    requireByteRange(
      bytes,
      0,
      accessUnitIndexHeaderLength,
      FormatErrorCode.indexInvalid,
      'access-unit index header',
    );
    _assertMagic(bytes);

    final recordSize =
        readUint16LE(bytes, 4, FormatErrorCode.indexInvalid, 'access-unit record size');
    if (recordSize != accessUnitRecordLength) {
      _fail('access-unit record size must be $accessUnitRecordLength', 4);
    }
    if (readUint16LE(bytes, 6, FormatErrorCode.indexInvalid, 'index reserved field') != 0) {
      _fail('access-unit index reserved field must be zero', 6);
    }
    final sampleCount =
        readUint32LE(bytes, 8, FormatErrorCode.indexInvalid, 'access-unit sample count');
    if (readUint32LE(bytes, 12, FormatErrorCode.indexInvalid, 'index reserved field') != 0) {
      _fail('access-unit index reserved field must be zero', 12);
    }
    if (sampleCount > budgets.maxSampleRecords) {
      throw FormatError(
        FormatErrorCode.budgetExceeded,
        'access-unit sample count exceeds the active limit of ${budgets.maxSampleRecords}',
        const FormatErrorDetails(offset: 8),
      );
    }

    final recordsLength = checkedMultiply(
      sampleCount,
      accessUnitRecordLength,
      budgets.maxIndexBytes,
      'access-unit records length',
    );
    final expectedLength = checkedAdd(
      accessUnitIndexHeaderLength,
      recordsLength,
      budgets.maxIndexBytes,
      'access-unit index length',
    );
    if (bytes.length != expectedLength) {
      _fail(
        'access-unit index length must be exactly $expectedLength bytes',
        bytes.length < expectedLength ? bytes.length : expectedLength,
      );
    }

    final plan = _canonicalSamplePlan(manifest, budgets.maxSampleRecords, budgets.maxTotalUnitFrames);
    if (sampleCount != plan.recordCount) {
      _fail('access-unit sample count must match the manifest count of ${plan.recordCount}', 8);
    }

    final records = <AccessUnitRecord>[];
    try {
      for (var ordinal = 0; ordinal < sampleCount; ordinal += 1) {
        records.add(_parseRecord(bytes, ordinal, options));
      }
    } on FormatError {
      rethrow;
    } catch (_) {
      throw FormatError(
        FormatErrorCode.indexInvalid,
        'access-unit index allocation for $sampleCount records failed',
      );
    }
    _validateRecordSequence(records, manifest, plan, options);
    return records;
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.indexInvalid, 'access-unit index could not be parsed');
  }
}

/// Encodes one exact version-0.1 access-unit index into a fresh byte array.
Uint8List encodeAccessUnitIndex(
  List<AccessUnitRecord> records,
  CompiledManifestV01 manifest, [
  FormatOptions? options,
]) {
  try {
    final budgets = resolveFormatBudgets(options);
    if (records.length > budgets.maxSampleRecords) {
      throw FormatError(
        FormatErrorCode.budgetExceeded,
        'access-unit sample count exceeds the active limit of ${budgets.maxSampleRecords}',
        const FormatErrorDetails(offset: 8),
      );
    }
    final length = checkedAdd(
      accessUnitIndexHeaderLength,
      checkedMultiply(
        records.length,
        accessUnitRecordLength,
        budgets.maxIndexBytes,
        'access-unit records length',
      ),
      budgets.maxIndexBytes,
      'access-unit index length',
    );
    Uint8List bytes;
    try {
      bytes = Uint8List(length);
    } catch (_) {
      throw FormatError(
        FormatErrorCode.indexInvalid,
        'access-unit index allocation of $length bytes failed',
      );
    }
    bytes.setRange(0, accessUnitIndexMagic.length, accessUnitIndexMagic);
    writeUint16LE(bytes, 4, accessUnitRecordLength, FormatErrorCode.indexInvalid, 'access-unit record size');
    writeUint16LE(bytes, 6, 0, FormatErrorCode.indexInvalid, 'index reserved field');
    writeUint32LE(bytes, 8, records.length, FormatErrorCode.indexInvalid, 'access-unit sample count');
    writeUint32LE(bytes, 12, 0, FormatErrorCode.indexInvalid, 'index reserved field');

    for (var ordinal = 0; ordinal < records.length; ordinal += 1) {
      final record = records[ordinal];
      final offset = _recordByteOffset(ordinal, budgets.maxIndexBytes);
      writeUint64LE(
        bytes,
        offset,
        record.payloadOffset,
        FormatErrorCode.indexInvalid,
        'access-unit payload offset',
      );
      writeUint32LE(
        bytes,
        offset + 8,
        record.payloadLength,
        FormatErrorCode.indexInvalid,
        'access-unit payload length',
      );
      writeUint32LE(
        bytes,
        offset + 12,
        record.unitIndex,
        FormatErrorCode.indexInvalid,
        'access-unit unit index',
      );
      writeUint16LE(
        bytes,
        offset + 16,
        record.renditionIndex,
        FormatErrorCode.indexInvalid,
        'access-unit rendition index',
      );
      writeUint16LE(
        bytes,
        offset + 18,
        record.key ? _keyFlag : 0,
        FormatErrorCode.indexInvalid,
        'access-unit flags',
      );
      writeUint32LE(
        bytes,
        offset + 20,
        record.frameIndex,
        FormatErrorCode.indexInvalid,
        'access-unit frame index',
      );
    }

    // Reuse the parser as the one semantic validation path for writer input.
    parseAccessUnitIndex(bytes, manifest, options);
    return bytes;
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.indexInvalid, 'access-unit index could not be encoded');
  }
}

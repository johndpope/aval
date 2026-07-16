/// Sole canonical byte-layout authority shared by the reader and writer.
///
/// Dart port of `packages/format/src/layout.ts`.
library;

import 'dart:typed_data';

import 'checked_integer.dart' show align8, checkedAdd, checkedMultiply;
import 'constants.dart';
import 'errors.dart';
import 'model.dart';
import 'sample_plan.dart' show createCanonicalSamplePlan, validateCanonicalSampleSpans, PlanRendition, PlanUnit;

/// Internal canonical geometry shared by the reader and writer.
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

class SamplePayloadShape {
  const SamplePayloadShape({required this.payloadLength, required this.key});

  final int payloadLength;
  final bool key;
}

/// Complete deterministic plan from which both index records and files derive.
class CanonicalAssetPlan extends CanonicalAssetLayout {
  const CanonicalAssetPlan({
    required super.frontIndexRange,
    required super.unitBlobs,
    required super.paddingRanges,
    required super.fileRange,
    required this.indexOffset,
    required this.indexLength,
    required this.records,
  });

  final int indexOffset;
  final int indexLength;
  final List<AccessUnitRecord> records;
}

Never _fail(String message, {int? offset, String? path}) {
  throw FormatError(
    FormatErrorCode.layoutInvalid,
    message,
    FormatErrorDetails(offset: offset, path: path),
  );
}

ByteRange _freezeRange(int offset, int length) => ByteRange(offset: offset, length: length);

void _addPaddingRange(List<ByteRange> ranges, int offset, int end) {
  if (end > offset) ranges.add(_freezeRange(offset, end - offset));
}

int _checkedEnd(int offset, int length, int limit, String label) =>
    checkedAdd(offset, length, limit, label);

/// Produces the sole legal version-0.1 layout from bounded payload
/// descriptors. This is the canonical owner of header/index geometry,
/// sample order, unit alignment and final file length.
CanonicalAssetPlan planCanonicalAssetLayout(
  int manifestLength,
  CompiledManifestV01 manifest,
  List<SamplePayloadShape> samples, [
  FormatOptions? options,
]) {
  try {
    return _planCanonicalAssetLayoutUnchecked(manifestLength, manifest, samples, options);
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(
      FormatErrorCode.layoutInvalid,
      'canonical layout allocation for ${samples.length} samples failed',
    );
  }
}

CanonicalAssetPlan _planCanonicalAssetLayoutUnchecked(
  int manifestLength,
  CompiledManifestV01 manifest,
  List<SamplePayloadShape> samples,
  FormatOptions? options,
) {
  final budgets = resolveFormatBudgets(options);
  final samplePlan = createCanonicalSamplePlan(
    manifest.renditions.map((r) => PlanRendition(id: r.id, profile: r.profile)).toList(),
    manifest.units.map((u) => PlanUnit(id: u.id, frameCount: u.frameCount)).toList(),
    budgets.maxSampleRecords,
    budgets.maxTotalUnitFrames,
  );
  validateCanonicalSampleSpans(samplePlan, manifest.units);

  if (samples.length != samplePlan.recordCount) {
    _fail(
      'sample payload count must be ${samplePlan.recordCount}, received ${samples.length}',
    );
  }
  final blobRangeCount = samplePlan.spans.length;
  if (blobRangeCount > budgets.maxBlobRanges) {
    throw FormatError(
      FormatErrorCode.budgetExceeded,
      'canonical blob range count exceeds the active budget',
    );
  }

  final manifestEnd =
      _checkedEnd(formatHeaderLength, manifestLength, budgets.maxFileBytes, 'manifest end');
  if (manifestLength > budgets.maxManifestBytes) {
    throw FormatError(
      FormatErrorCode.budgetExceeded,
      'manifest length exceeds the active limit of ${budgets.maxManifestBytes}',
    );
  }
  final indexOffset = align8(manifestEnd, budgets.maxFileBytes, 'access-unit index offset');
  final indexLength = checkedAdd(
    accessUnitIndexHeaderLength,
    checkedMultiply(
      samplePlan.recordCount,
      accessUnitRecordLength,
      budgets.maxIndexBytes,
      'access-unit records length',
    ),
    budgets.maxIndexBytes,
    'access-unit index length',
  );
  final frontIndexEnd = _checkedEnd(indexOffset, indexLength, budgets.maxFileBytes, 'front index end');

  final paddingRanges = <ByteRange>[];
  _addPaddingRange(paddingRanges, manifestEnd, indexOffset);
  final records = <AccessUnitRecord>[];
  final unitBlobs = <UnitBlobRange>[];
  var cursor = frontIndexEnd;

  for (final span in samplePlan.spans) {
    final aligned = align8(cursor, budgets.maxFileBytes, 'unit blob offset');
    _addPaddingRange(paddingRanges, cursor, aligned);
    cursor = aligned;
    final blobOffset = cursor;
    final unit = span.unitIndex < manifest.units.length ? manifest.units[span.unitIndex] : null;
    final descriptor =
        unit != null && span.renditionIndex < unit.samples.length ? unit.samples[span.renditionIndex] : null;
    if (unit == null || descriptor == null) {
      _fail('canonical unit sample descriptor is missing');
    }

    final spanEnd =
        checkedAdd(span.sampleStart, span.sampleCount, samplePlan.recordCount, 'sample span end');
    for (var ordinal = span.sampleStart; ordinal < spanEnd; ordinal += 1) {
      final slot = samplePlan.recordAt(ordinal);
      final sample = ordinal < samples.length ? samples[ordinal] : null;
      if (sample == null) {
        _fail('canonical sample payload is missing');
      }
      if (sample.payloadLength < 1) {
        _fail('sample payload length must be a positive safe integer');
      }
      if (sample.payloadLength > budgets.maxSampleBytes) {
        throw FormatError(
          FormatErrorCode.budgetExceeded,
          'sample payload length exceeds the active limit of ${budgets.maxSampleBytes}',
        );
      }
      if (slot.keyRequired && !sample.key) {
        _fail('canonical sample requiring random access must be marked key');
      }
      records.add(AccessUnitRecord(
        payloadOffset: cursor,
        payloadLength: sample.payloadLength,
        unitIndex: slot.unitIndex,
        renditionIndex: slot.renditionIndex,
        key: sample.key,
        frameIndex: slot.frameIndex,
      ));
      cursor = _checkedEnd(cursor, sample.payloadLength, budgets.maxFileBytes, 'access-unit payload end');
    }

    unitBlobs.add(UnitBlobRange(
      rendition: span.renditionId,
      unit: span.unitId,
      sampleStart: span.sampleStart,
      sampleCount: span.sampleCount,
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
}

/// Derives and validates the one legal version-0.1 byte layout.
CanonicalAssetLayout deriveCanonicalAssetLayout(
  FormatHeader header,
  CompiledManifestV01 manifest,
  List<AccessUnitRecord> records, [
  FormatOptions? options,
]) {
  try {
    final plan = planCanonicalAssetLayout(header.manifestLength, manifest, records.map((r) {
      return SamplePayloadShape(payloadLength: r.payloadLength, key: r.key);
    }).toList(), options);

    if (header.manifestOffset != formatHeaderLength) {
      _fail('manifest offset is not canonical', offset: header.manifestOffset);
    }
    if (header.indexOffset != plan.indexOffset) {
      _fail('access-unit index offset is not canonical', offset: header.indexOffset);
    }
    if (header.indexLength != plan.indexLength) {
      _fail('access-unit index length is not canonical', offset: header.indexOffset);
    }
    if (header.declaredFileLength != plan.fileRange.length) {
      _fail(
        header.declaredFileLength > plan.fileRange.length
            ? 'declared file contains trailing bytes'
            : 'payload layout extends beyond the declared file',
        offset: header.declaredFileLength < plan.fileRange.length
            ? header.declaredFileLength
            : plan.fileRange.length,
      );
    }

    for (var index = 0; index < plan.records.length; index += 1) {
      final actual = index < records.length ? records[index] : null;
      final expected = plan.records[index];
      if (actual == null ||
          actual.payloadOffset != expected.payloadOffset ||
          actual.payloadLength != expected.payloadLength ||
          actual.unitIndex != expected.unitIndex ||
          actual.renditionIndex != expected.renditionIndex ||
          actual.key != expected.key ||
          actual.frameIndex != expected.frameIndex) {
        _fail('access-unit record is not canonical', offset: actual?.payloadOffset ?? header.indexOffset);
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

/// Requires every byte in the supplied numeric ranges to be canonical zero.
void validateZeroPadding(Uint8List bytes, List<ByteRange> ranges) {
  try {
    for (final range in ranges) {
      final end = _checkedEnd(range.offset, range.length, bytes.length, 'padding range end');
      for (var offset = range.offset; offset < end; offset += 1) {
        if (bytes[offset] != 0) {
          _fail('alignment padding must contain only zero bytes', offset: offset);
        }
      }
    }
  } on FormatError {
    rethrow;
  } catch (_) {
    throw FormatError(FormatErrorCode.layoutInvalid, 'asset padding could not be validated');
  }
}

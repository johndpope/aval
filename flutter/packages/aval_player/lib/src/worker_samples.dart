/// The concrete worker sample factory: joins catalog records, timeline
/// identity, and sample bytes into one closed, atomically-committed batch.
///
/// Direct port of `packages/player-web/src/runtime/worker-samples.ts`. It
/// supersedes the earlier frozen-interface scaffold: [WorkerSampleFactory] is
/// now the concrete TS class (the path scheduler still binds to it by name, and
/// `implements WorkerSampleFactory` test doubles remain valid).
///
/// Judgment calls (with TS anchors):
/// - The TS `Reflect`-based hostile-object hardening in `captureResourceHost` /
///   `captureTransferLease` (worker-samples.ts:216-261) collapses to typed
///   interfaces ([WorkerSampleResourceHost] / [WorkerSampleTransferLease]) plus
///   the once-guard on release; Dart cannot invoke an accessor a value did not
///   declare, so the "inaccessible"/"malformed" reflection branches are moot.
/// - The `data instanceof ArrayBuffer` guard (worker-samples.ts:164) is dropped
///   because [WorkerSampleCatalog.copySample] is statically a `ByteBuffer`.
/// - `Object.freeze`/`Object.defineProperty(release)` (worker-samples.ts:196)
///   have no Dart analog; the batch is an immutable class with a `release()`
///   method and `List.unmodifiable` samples.
/// - `Number.isSafeInteger`/`Number.MAX_SAFE_INTEGER` map to explicit bounds
///   against [maxSafeInteger].
library;

import 'dart:typed_data';

import 'package:aval_format/aval_format.dart'
    show RenditionV01, UnitV01, isAvcCodec;

import 'asset_catalog_index.dart'
    show
        RuntimeCatalogAccessUnit,
        RuntimeCatalogIdIndex,
        RuntimeCatalogRecordIndex;
import 'decode_timeline.dart'
    show DecodeTimeline, DecodeTimelineFrameRequest;
import 'decoder_worker/protocol.dart'
    show
        DecoderWorkerHardLimits,
        DecoderWorkerLimits,
        DecoderWorkerSample,
        EncodedVideoChunkType;
import 'rational_time.dart' show maxSafeInteger;

/// The catalog surface a factory reads (a `Pick`-narrowed [RuntimeAssetCatalog];
/// worker-samples.ts:22-27).
abstract interface class WorkerSampleCatalog {
  RuntimeCatalogIdIndex<RenditionV01> get renditions;
  RuntimeCatalogIdIndex<UnitV01> get units;
  RuntimeCatalogRecordIndex get records;

  ByteBuffer copySample(String rendition, String unit, int localFrame);
}

/// One requested source/target frame.
class WorkerSampleFrameRequest {
  const WorkerSampleFrameRequest({
    required this.unitId,
    required this.unitFrame,
  });

  final String unitId;
  final int unitFrame;
}

/// Input to [WorkerSampleFactory.createBatch].
class CreateWorkerSampleBatchInput {
  const CreateWorkerSampleBatchInput({
    required this.frames,
    required this.pendingSamples,
    required this.outstandingFrames,
  });

  final List<WorkerSampleFrameRequest> frames;
  final int pendingSamples;
  final int outstandingFrames;
}

/// A batch of decoder samples with a transfer-claim release hook.
abstract interface class DecoderWorkerSampleBatch {
  int get generation;
  List<DecoderWorkerSample> get samples;

  /// Release the main-thread transfer claim after submit transfers ownership.
  void release();
}

/// A resource lease returned by [WorkerSampleResourceHost.claim].
abstract interface class WorkerSampleTransferLease {
  void release();
}

/// A resource host that charges the transferred access-unit bytes up front.
abstract interface class WorkerSampleResourceHost {
  WorkerSampleTransferLease claim(int byteLength);
}

/// Construction options for [WorkerSampleFactory].
class WorkerSampleFactoryOptions {
  const WorkerSampleFactoryOptions({
    required this.catalog,
    required this.timeline,
    required this.rendition,
    required this.limits,
    this.resourceHost,
  });

  final WorkerSampleCatalog catalog;
  final DecodeTimeline timeline;
  final String rendition;
  final DecoderWorkerLimits limits;
  final WorkerSampleResourceHost? resourceHost;
}

typedef _ClaimTransfer = WorkerSampleTransferLease Function(int byteLength);

class _ValidatedFrameRequest {
  const _ValidatedFrameRequest(this.request, this.unit, this.accessUnit);

  final WorkerSampleFrameRequest request;
  final UnitV01 unit;
  final RuntimeCatalogAccessUnit accessUnit;
}

/// Sole owner that joins catalog records, timeline identity, and sample bytes.
class WorkerSampleFactory {
  WorkerSampleFactory(WorkerSampleFactoryOptions options)
      : _catalog = options.catalog,
        _timeline = options.timeline,
        _rendition = options.rendition,
        _limits = DecoderWorkerLimits(
          maxDecodeQueueSize: options.limits.maxDecodeQueueSize,
          maxPendingSamples: options.limits.maxPendingSamples,
          maxOutstandingFrames: options.limits.maxOutstandingFrames,
          maxDecodedBytes: options.limits.maxDecodedBytes,
        ) {
    _validateWorkerLimits(options.limits);
    final rendition = options.catalog.renditions.require(options.rendition);
    if ((rendition.profile != 'avc-annexb-opaque-v0' &&
            rendition.profile != 'avc-annexb-packed-alpha-v0' &&
            rendition.profile != 'avc-annexb-opaque-v1' &&
            rendition.profile != 'avc-annexb-packed-alpha-v1') ||
        !isAvcCodec(rendition.codec)) {
      throw RangeError('worker sample factory requires an exact AVC rendition');
    }
    _claimTransfer = options.resourceHost == null
        ? null
        : _captureResourceHost(options.resourceHost!);
  }

  final WorkerSampleCatalog _catalog;
  final DecodeTimeline _timeline;
  final String _rendition;
  final DecoderWorkerLimits _limits;
  _ClaimTransfer? _claimTransfer;

  DecoderWorkerSampleBatch createBatch(CreateWorkerSampleBatchInput input) {
    _validateBatchCredit(input, _limits);

    final validated = <_ValidatedFrameRequest>[];
    final timelineFrames = <DecodeTimelineFrameRequest>[];
    var transferBytes = 0;
    for (final request in input.frames) {
      _validateFrameRequest(request);
      final unit = _catalog.units.require(request.unitId);
      final accessUnit = _catalog.records.require(
        _rendition,
        request.unitId,
        request.unitFrame,
      );
      _validateCatalogRecord(accessUnit, unit, _rendition, request);
      validated.add(_ValidatedFrameRequest(request, unit, accessUnit));
      transferBytes = _checkedTransferSum(transferBytes, accessUnit.range.length);
      timelineFrames.add(DecodeTimelineFrameRequest(
        unitId: request.unitId,
        unitFrame: request.unitFrame,
        unitFrameCount: unit.frameCount,
      ));
    }

    // Planning validates the complete occurrence grammar and clock without
    // advancing any counter. Payload allocation starts only after this point.
    final timelinePlan = _timeline.planSampleBatch(timelineFrames);
    final transferLease = _claimTransfer == null
        ? _noopTransferLease
        : _captureTransferLease(_claimTransfer!(transferBytes));
    final samples = <DecoderWorkerSample>[];
    final buffers = <ByteBuffer>{};
    try {
      for (var index = 0; index < validated.length; index += 1) {
        final frame = validated[index];
        final metadata = timelinePlan.samples[index];

        final data = _catalog.copySample(
          _rendition,
          frame.request.unitId,
          frame.request.unitFrame,
        );
        if (data.lengthInBytes != frame.accessUnit.range.length) {
          throw RangeError('catalog sample copy must have the exact record length');
        }
        if (buffers.contains(data)) {
          throw RangeError('every worker sample must own a distinct ArrayBuffer');
        }
        buffers.add(data);

        samples.add(DecoderWorkerSample(
          ordinal: metadata.ordinal,
          unitId: metadata.unitId,
          unitInstance: metadata.unitInstance,
          unitFrame: metadata.unitFrame,
          unitFrameCount: metadata.unitFrameCount,
          type: frame.accessUnit.record.key
              ? EncodedVideoChunkType.key
              : EncodedVideoChunkType.delta,
          timestamp: metadata.timestamp,
          duration: metadata.duration,
          data: data,
        ));
      }

      final batch = _WorkerSampleBatch(
        generation: timelinePlan.generation,
        samples: List<DecoderWorkerSample>.unmodifiable(samples),
        release: transferLease.release,
      );
      timelinePlan.commit();
      return batch;
    } catch (_) {
      transferLease.release();
      rethrow;
    }
  }
}

class _WorkerSampleBatch implements DecoderWorkerSampleBatch {
  _WorkerSampleBatch({
    required this.generation,
    required this.samples,
    required void Function() release,
  }) : _release = release;

  @override
  final int generation;

  @override
  final List<DecoderWorkerSample> samples;

  final void Function() _release;

  @override
  void release() => _release();
}

final WorkerSampleTransferLease _noopTransferLease = _NoopTransferLease();

class _NoopTransferLease implements WorkerSampleTransferLease {
  @override
  void release() {}
}

_ClaimTransfer _captureResourceHost(WorkerSampleResourceHost value) {
  return (byteLength) => value.claim(byteLength);
}

WorkerSampleTransferLease _captureTransferLease(WorkerSampleTransferLease value) {
  var released = false;
  return _GuardedTransferLease(() {
    if (released) return;
    released = true;
    value.release();
  });
}

class _GuardedTransferLease implements WorkerSampleTransferLease {
  _GuardedTransferLease(this._release);

  final void Function() _release;

  @override
  void release() => _release();
}

int _checkedTransferSum(int total, int bytes) {
  if (total < 0 ||
      bytes <= 0 ||
      total > maxSafeInteger ||
      bytes > maxSafeInteger ||
      total > maxSafeInteger - bytes) {
    throw RangeError('worker sample transfer bytes exceed the safe range');
  }
  return total + bytes;
}

void _validateWorkerLimits(DecoderWorkerLimits limits) {
  _validateBoundedPositiveInteger(
    limits.maxDecodeQueueSize,
    DecoderWorkerHardLimits.maxDecodeQueueSize,
    'worker decode queue limit',
  );
  _validateBoundedPositiveInteger(
    limits.maxPendingSamples,
    DecoderWorkerHardLimits.maxPendingSamples,
    'worker pending sample limit',
  );
  _validateBoundedPositiveInteger(
    limits.maxOutstandingFrames,
    DecoderWorkerHardLimits.maxOutstandingFrames,
    'worker outstanding frame limit',
  );
  _validateBoundedPositiveInteger(
    limits.maxDecodedBytes,
    DecoderWorkerHardLimits.maxDecodedBytes,
    'worker decoded byte limit',
  );
}

void _validateBatchCredit(
  CreateWorkerSampleBatchInput input,
  DecoderWorkerLimits limits,
) {
  if (input.frames.isEmpty ||
      input.frames.length > DecoderWorkerHardLimits.maxPendingSamples) {
    throw RangeError('worker sample batch length exceeds the hard sample limit');
  }
  _validateNonNegativeSafeInteger(input.pendingSamples, 'pending sample count');
  _validateNonNegativeSafeInteger(
    input.outstandingFrames,
    'outstanding frame count',
  );
  if (input.pendingSamples > limits.maxPendingSamples ||
      input.frames.length > limits.maxPendingSamples - input.pendingSamples) {
    throw RangeError('worker sample batch exceeds the pending sample limit');
  }
  if (input.outstandingFrames > limits.maxOutstandingFrames ||
      input.frames.length >
          limits.maxOutstandingFrames - input.outstandingFrames) {
    throw RangeError('worker sample batch exceeds the outstanding frame limit');
  }
}

void _validateFrameRequest(WorkerSampleFrameRequest request) {
  if (request.unitId.isEmpty || request.unitId.length > 128) {
    throw RangeError('worker sample unit ID length must be 1-128');
  }
  _validateNonNegativeSafeInteger(request.unitFrame, 'worker sample unit frame');
}

void _validateCatalogRecord(
  RuntimeCatalogAccessUnit accessUnit,
  UnitV01 unit,
  String rendition,
  WorkerSampleFrameRequest request,
) {
  if (unit.frameCount <= 0 ||
      unit.frameCount > maxSafeInteger ||
      request.unitFrame >= unit.frameCount) {
    throw RangeError('worker sample unit frame is outside its unit');
  }
  if (accessUnit.rendition != rendition ||
      accessUnit.unit != request.unitId ||
      accessUnit.localFrame != request.unitFrame ||
      accessUnit.record.frameIndex != request.unitFrame) {
    throw RangeError('catalog access-unit identity did not match the request');
  }
  if (accessUnit.range.length < 1 ||
      accessUnit.range.length > maxSafeInteger ||
      accessUnit.record.payloadLength != accessUnit.range.length) {
    throw RangeError('catalog sample byte length exceeds the worker limit');
  }
  // TS `typeof accessUnit.record.key !== "boolean"` cannot fail in Dart: the
  // field is statically `bool` (worker-samples.ts:371-373).
}

void _validateBoundedPositiveInteger(int value, int maximum, String label) {
  if (value <= 0 || value > maximum) {
    throw RangeError('$label must be a positive integer no greater than $maximum');
  }
}

void _validateNonNegativeSafeInteger(int value, String label) {
  if (value < 0 || value > maxSafeInteger) {
    throw RangeError('$label must be a non-negative safe integer');
  }
}

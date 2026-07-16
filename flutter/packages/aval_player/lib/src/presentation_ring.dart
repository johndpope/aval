/// Presentation-ring capacity bounds, validation, and the bounded FIFO ring.
///
/// Direct port of `packages/player-web/src/runtime/presentation-ring.ts`.
/// The Phase-2 frozen surface exposed only the capacity constants and
/// [validatePresentationRingCapacity] (the sole part `edge-lead.ts` /
/// `submission-horizon.ts` depend on). This file now also ports the
/// [PresentationRing] itself and its data shapes, because
/// `path-scheduler-output.ts` owns one directly (`new PresentationRing(...)`,
/// `enqueue`/`takeExpected`/`activatePath`/`clear`/`dispose`/`snapshot`).
///
/// TypeScript `bigint` presentation ordinals become Dart `BigInt`; `number`
/// counters become `int`. Discriminated unions (`PresentationRingEnqueueResult`,
/// `PresentationRingTakeResult`) become sealed-class hierarchies carrying the
/// same `kind` wire string. `Object.freeze`d records become immutable classes.
/// The TS `AggregateError` thrown by `#closeAllEntries` becomes a
/// [StateError] carrying the collected causes (Dart has no `AggregateError`).
library;

import 'decoder_worker/client_support.dart';
import 'rational_time.dart' show maxSafeInteger;

/// Minimum accepted presentation-ring capacity (`MIN_PRESENTATION_RING_CAPACITY`).
const int minPresentationRingCapacity = 6;

/// Maximum accepted presentation-ring capacity (`MAX_PRESENTATION_RING_CAPACITY`).
const int maxPresentationRingCapacity = 12;

const int _maxMediaIdLength = 128;

/// The exact identity a decoded frame must carry to enter/leave the ring.
class PresentationRingExpectedFrame {
  const PresentationRingExpectedFrame({
    required this.generation,
    required this.path,
    required this.unitId,
    required this.unitInstance,
    required this.unitFrame,
    required this.decodeOrdinal,
    required this.timestamp,
    required this.duration,
    required this.intendedPresentationOrdinal,
  });

  final int generation;
  final String path;
  final String unitId;
  final int unitInstance;
  final int unitFrame;
  final int decodeOrdinal;
  final int timestamp;
  final int duration;
  final BigInt intendedPresentationOrdinal;
}

/// One decoded frame plus its arrival timing, offered to [PresentationRing.enqueue].
class PresentationRingInsertion {
  const PresentationRingInsertion({
    required this.expected,
    required this.frame,
    required this.workerOutputTimeMs,
    required this.uploadReadyTimeMs,
  });

  final PresentationRingExpectedFrame expected;
  final ManagedDecoderWorkerFrame frame;
  final int workerOutputTimeMs;
  final int? uploadReadyTimeMs;
}

/// A retained ring entry: the expected identity plus its owned frame.
class PresentationRingEntry extends PresentationRingExpectedFrame {
  const PresentationRingEntry({
    required super.generation,
    required super.path,
    required super.unitId,
    required super.unitInstance,
    required super.unitFrame,
    required super.decodeOrdinal,
    required super.timestamp,
    required super.duration,
    required super.intendedPresentationOrdinal,
    required this.frameId,
    required this.decodedBytes,
    required this.workerOutputTimeMs,
    required this.uploadReadyTimeMs,
    required this.frame,
  });

  final int frameId;
  final int decodedBytes;
  final int workerOutputTimeMs;
  final int? uploadReadyTimeMs;
  final ManagedDecoderWorkerFrame frame;
}

/// Result of an [PresentationRing.enqueue].
sealed class PresentationRingEnqueueResult {
  const PresentationRingEnqueueResult();

  String get kind;
}

class PresentationRingEnqueueAccepted extends PresentationRingEnqueueResult {
  const PresentationRingEnqueueAccepted({required this.size});

  final int size;

  @override
  String get kind => 'accepted';
}

class PresentationRingEnqueueStale extends PresentationRingEnqueueResult {
  const PresentationRingEnqueueStale({
    required this.activeGeneration,
    required this.discardedGeneration,
  });

  final int activeGeneration;
  final int discardedGeneration;

  @override
  String get kind => 'stale';
}

/// Result of a [PresentationRing.takeExpected].
sealed class PresentationRingTakeResult {
  const PresentationRingTakeResult();

  String get kind;
}

class PresentationRingTakeFrame extends PresentationRingTakeResult {
  const PresentationRingTakeFrame({required this.entry});

  final PresentationRingEntry entry;

  @override
  String get kind => 'frame';
}

class PresentationRingTakeUnderflow extends PresentationRingTakeResult {
  const PresentationRingTakeUnderflow({required this.expected});

  final PresentationRingExpectedFrame expected;

  @override
  String get kind => 'underflow';
}

/// One entry of a ring snapshot (identity plus bookkeeping, no owned frame).
class PresentationRingSnapshotEntry extends PresentationRingExpectedFrame {
  const PresentationRingSnapshotEntry({
    required super.generation,
    required super.path,
    required super.unitId,
    required super.unitInstance,
    required super.unitFrame,
    required super.decodeOrdinal,
    required super.timestamp,
    required super.duration,
    required super.intendedPresentationOrdinal,
    required this.frameId,
    required this.decodedBytes,
    required this.workerOutputTimeMs,
    required this.uploadReadyTimeMs,
  });

  final int frameId;
  final int decodedBytes;
  final int workerOutputTimeMs;
  final int? uploadReadyTimeMs;
}

/// Observable ring counters and entries.
class PresentationRingSnapshot {
  const PresentationRingSnapshot({
    required this.capacity,
    required this.generation,
    required this.activePath,
    required this.size,
    required this.decodedBytes,
    required this.underflows,
    required this.staleFrames,
    required this.closedFrames,
    required this.disposed,
    required this.entries,
  });

  final int capacity;
  final int generation;
  final String activePath;
  final int size;
  final int decodedBytes;
  final int underflows;
  final int staleFrames;
  final int closedFrames;
  final bool disposed;
  final List<PresentationRingSnapshotEntry> entries;
}

/// Result of [PresentationRing.activatePath].
class PresentationRingActivateResult {
  const PresentationRingActivateResult({
    required this.closedFrames,
    required this.generation,
    required this.path,
  });

  final int closedFrames;
  final int generation;
  final String path;
}

/// Construction options for [PresentationRing].
class PresentationRingOptions {
  const PresentationRingOptions({
    required this.capacity,
    required this.generation,
    required this.path,
  });

  final int capacity;
  final int generation;
  final String path;
}

/// Bounded FIFO owner for one active streaming media path.
class PresentationRing {
  PresentationRing(PresentationRingOptions options)
      : _capacity = options.capacity,
        _generation = options.generation,
        _activePath = options.path {
    validatePresentationRingCapacity(options.capacity);
    _validatePositiveSafeInteger(options.generation, 'ring generation');
    _validateMediaId(options.path, 'ring path');
  }

  final int _capacity;
  int _generation;
  String _activePath;
  final List<PresentationRingEntry> _entries = <PresentationRingEntry>[];
  int _decodedBytes = 0;
  int _underflows = 0;
  int _staleFrames = 0;
  int _closedFrames = 0;
  bool _disposed = false;

  /// Takes ownership of `frame` on every success and failure path.
  PresentationRingEnqueueResult enqueue(PresentationRingInsertion insertion) {
    final frame = insertion.frame;
    try {
      _requireUsable();
      _validateExpected(insertion.expected);
      _validateTiming(
        insertion.workerOutputTimeMs,
        insertion.uploadReadyTimeMs,
      );
      _validatePositiveSafeInteger(frame.frameId, 'worker frame ID');
      _validatePositiveSafeInteger(frame.decodedBytes, 'decoded frame bytes');
      _validateFrameMatches(frame, insertion.expected);

      if (insertion.expected.generation < _generation) {
        _closeOwnedFrame(frame);
        _staleFrames += 1;
        return PresentationRingEnqueueStale(
          activeGeneration: _generation,
          discardedGeneration: insertion.expected.generation,
        );
      }
      if (insertion.expected.generation > _generation) {
        throw RangeError(
          'ring output generation is newer than the active generation',
        );
      }
      if (insertion.expected.path != _activePath) {
        throw RangeError('ring output did not target the active media path');
      }
      if (frame.closed) {
        throw RangeError('ring cannot own an already closed frame');
      }
      if (_entries.length >= _capacity) {
        throw RangeError('presentation ring capacity is full');
      }
      if (_entries.any((entry) =>
          entry.frameId == frame.frameId ||
          _sameExpected(entry, insertion.expected))) {
        throw RangeError('presentation ring rejected a duplicate identity');
      }

      final tail = _entries.isEmpty ? null : _entries.last;
      if (tail != null) {
        _validateNextFifoIdentity(tail, insertion.expected);
      }
      if (_decodedBytes > maxSafeInteger - frame.decodedBytes) {
        throw RangeError('presentation ring decoded bytes exceed safe range');
      }

      final entry = PresentationRingEntry(
        generation: insertion.expected.generation,
        path: insertion.expected.path,
        unitId: insertion.expected.unitId,
        unitInstance: insertion.expected.unitInstance,
        unitFrame: insertion.expected.unitFrame,
        decodeOrdinal: insertion.expected.decodeOrdinal,
        timestamp: insertion.expected.timestamp,
        duration: insertion.expected.duration,
        intendedPresentationOrdinal:
            insertion.expected.intendedPresentationOrdinal,
        frameId: frame.frameId,
        decodedBytes: frame.decodedBytes,
        workerOutputTimeMs: insertion.workerOutputTimeMs,
        uploadReadyTimeMs: insertion.uploadReadyTimeMs,
        frame: frame,
      );
      _entries.add(entry);
      _decodedBytes += frame.decodedBytes;
      return PresentationRingEnqueueAccepted(size: _entries.length);
    } catch (error) {
      _closeOwnedFrame(frame);
      rethrow;
    }
  }

  /// Removes only the exact expected head. A frame result transfers ownership
  /// to the renderer; the renderer becomes responsible for its single close.
  PresentationRingTakeResult takeExpected(
    PresentationRingExpectedFrame expected,
  ) {
    _requireUsable();
    _validateExpected(expected);
    if (expected.generation != _generation || expected.path != _activePath) {
      throw RangeError(
        'expected presentation does not target the active ring path',
      );
    }

    final head = _entries.isEmpty ? null : _entries.first;
    if (head == null) {
      _underflows += 1;
      return PresentationRingTakeUnderflow(expected: expected);
    }
    if (!_sameExpected(head, expected)) {
      throw RangeError(
        'ring head did not match the expected presentation identity',
      );
    }

    _removeHead(head);
    if (head.frame.closed) {
      throw RangeError('ring-owned frame was already closed before take');
    }
    return PresentationRingTakeFrame(entry: head);
  }

  /// Retires all old path frames before activating a strictly newer token.
  PresentationRingActivateResult activatePath({
    required int generation,
    required String path,
  }) {
    _requireUsable();
    _validatePositiveSafeInteger(generation, 'ring generation');
    _validateMediaId(path, 'ring path');

    if (generation == _generation && path == _activePath) {
      return PresentationRingActivateResult(
        closedFrames: 0,
        generation: _generation,
        path: _activePath,
      );
    }
    if (generation <= _generation) {
      throw RangeError(
        'ring generation must increase before replacing the active path',
      );
    }

    final closedFrames = _closeAllEntries();
    _generation = generation;
    _activePath = path;
    return PresentationRingActivateResult(
      closedFrames: closedFrames,
      generation: _generation,
      path: _activePath,
    );
  }

  int clear() {
    _requireUsable();
    return _closeAllEntries();
  }

  int dispose() {
    if (_disposed) return 0;
    _disposed = true;
    return _closeAllEntries();
  }

  PresentationRingSnapshot snapshot() {
    return PresentationRingSnapshot(
      capacity: _capacity,
      generation: _generation,
      activePath: _activePath,
      size: _entries.length,
      decodedBytes: _decodedBytes,
      underflows: _underflows,
      staleFrames: _staleFrames,
      closedFrames: _closedFrames,
      disposed: _disposed,
      entries: List<PresentationRingSnapshotEntry>.unmodifiable(
        _entries.map((entry) => PresentationRingSnapshotEntry(
              generation: entry.generation,
              path: entry.path,
              unitId: entry.unitId,
              unitInstance: entry.unitInstance,
              unitFrame: entry.unitFrame,
              decodeOrdinal: entry.decodeOrdinal,
              timestamp: entry.timestamp,
              duration: entry.duration,
              intendedPresentationOrdinal: entry.intendedPresentationOrdinal,
              frameId: entry.frameId,
              decodedBytes: entry.decodedBytes,
              workerOutputTimeMs: entry.workerOutputTimeMs,
              uploadReadyTimeMs: entry.uploadReadyTimeMs,
            )),
      ),
    );
  }

  void _requireUsable() {
    if (_disposed) {
      throw RangeError('presentation ring is disposed');
    }
  }

  void _removeHead(PresentationRingEntry head) {
    _entries.removeAt(0);
    _decodedBytes -= head.decodedBytes;
  }

  bool _closeOwnedFrame(ManagedDecoderWorkerFrame frame) {
    final wasOpen = !frame.closed;
    frame.close();
    if (wasOpen) {
      _closedFrames += 1;
    }
    return wasOpen;
  }

  int _closeAllEntries() {
    final entries = List<PresentationRingEntry>.of(_entries);
    _entries.clear();
    _decodedBytes = 0;
    var closedFrames = 0;
    final errors = <Object>[];
    for (final entry in entries) {
      try {
        if (_closeOwnedFrame(entry.frame)) {
          closedFrames += 1;
        }
      } catch (error) {
        errors.add(error);
      }
    }
    if (errors.isNotEmpty) {
      throw StateError(
        'presentation ring frame cleanup failed: ${errors.join(', ')}',
      );
    }
    return closedFrames;
  }
}

/// Rejects any capacity outside the inclusive `6-12` range.
void validatePresentationRingCapacity(int capacity) {
  if (capacity < minPresentationRingCapacity ||
      capacity > maxPresentationRingCapacity) {
    throw RangeError(
      'presentation ring capacity must be '
      '$minPresentationRingCapacity-$maxPresentationRingCapacity',
    );
  }
}

void _validateExpected(PresentationRingExpectedFrame expected) {
  _validatePositiveSafeInteger(expected.generation, 'frame generation');
  _validateMediaId(expected.path, 'frame path');
  _validateMediaId(expected.unitId, 'frame unit ID');
  _validateNonNegativeSafeInteger(expected.unitInstance, 'unit instance');
  _validateNonNegativeSafeInteger(expected.unitFrame, 'unit frame');
  _validateNonNegativeSafeInteger(expected.decodeOrdinal, 'decode ordinal');
  if (expected.decodeOrdinal >= maxSafeInteger) {
    throw RangeError('decode ordinal leaves no safe successor');
  }
  _validateNonNegativeSafeInteger(expected.timestamp, 'frame timestamp');
  _validatePositiveSafeInteger(expected.duration, 'frame duration');
  if (expected.timestamp > maxSafeInteger - expected.duration) {
    throw RangeError('frame timestamp plus duration exceeds safe range');
  }
  if (expected.intendedPresentationOrdinal < BigInt.zero) {
    throw RangeError('presentation ordinal must be non-negative');
  }
}

void _validateFrameMatches(
  ManagedDecoderWorkerFrame frame,
  PresentationRingExpectedFrame expected,
) {
  if (frame.generation != expected.generation ||
      frame.ordinal != expected.decodeOrdinal ||
      frame.unitId != expected.unitId ||
      frame.unitInstance != expected.unitInstance ||
      frame.unitFrame != expected.unitFrame ||
      frame.timestamp != expected.timestamp ||
      frame.duration != expected.duration) {
    throw RangeError(
      'managed decoder frame did not match its expected ring identity',
    );
  }
}

void _validateNextFifoIdentity(
  PresentationRingExpectedFrame previous,
  PresentationRingExpectedFrame next,
) {
  if (next.decodeOrdinal != previous.decodeOrdinal + 1 ||
      next.timestamp != previous.timestamp + previous.duration ||
      next.intendedPresentationOrdinal !=
          previous.intendedPresentationOrdinal + BigInt.one) {
    throw RangeError('presentation ring rejected noncontiguous FIFO order');
  }

  if (next.unitInstance == previous.unitInstance) {
    if (next.unitId != previous.unitId ||
        next.unitFrame != previous.unitFrame + 1) {
      throw RangeError('presentation ring rejected noncontiguous unit order');
    }
    return;
  }
  if (next.unitInstance != previous.unitInstance + 1 || next.unitFrame != 0) {
    throw RangeError(
      'presentation ring rejected noncontiguous occurrence order',
    );
  }
}

bool _sameExpected(
  PresentationRingExpectedFrame left,
  PresentationRingExpectedFrame right,
) {
  return left.generation == right.generation &&
      left.path == right.path &&
      left.unitId == right.unitId &&
      left.unitInstance == right.unitInstance &&
      left.unitFrame == right.unitFrame &&
      left.decodeOrdinal == right.decodeOrdinal &&
      left.timestamp == right.timestamp &&
      left.duration == right.duration &&
      left.intendedPresentationOrdinal == right.intendedPresentationOrdinal;
}

void _validateTiming(int workerOutputTimeMs, int? uploadReadyTimeMs) {
  if (workerOutputTimeMs < 0) {
    throw RangeError('worker output time must be finite and non-negative');
  }
  if (uploadReadyTimeMs != null && uploadReadyTimeMs < workerOutputTimeMs) {
    throw RangeError(
      'upload-ready time must be null or no earlier than worker output',
    );
  }
}

void _validateMediaId(String value, String label) {
  if (value.isEmpty || value.length > _maxMediaIdLength) {
    throw RangeError('$label length must be 1-$_maxMediaIdLength');
  }
}

void _validatePositiveSafeInteger(int value, String label) {
  if (value <= 0 || value > maxSafeInteger) {
    throw RangeError('$label must be a positive safe integer');
  }
}

void _validateNonNegativeSafeInteger(int value, String label) {
  if (value < 0 || value > maxSafeInteger) {
    throw RangeError('$label must be a non-negative safe integer');
  }
}

/// Scheduler input validation.
///
/// Direct port of `packages/player-web/src/runtime/path-scheduler-validation.ts`.
/// `graphBodyFrameAt` (from `body-frame-semantics.ts`, not yet ported as its own
/// module) is inlined here as [_graphBodyFrameAt] — the only consumer in this
/// task. `Number.isSafeInteger` bounds map onto `maxSafeInteger` from
/// `rational_time.dart`.
library;

import 'package:aval_graph/aval_graph.dart';

import 'decoder_worker/protocol.dart';
import 'path_scheduler_model.dart'
    show PathSchedulerResidentFrame, StartResidentRunwayInput;
import 'rational_time.dart' show maxSafeInteger;

const int _minResidentRunwayFrames = 6;
const int _maxResidentRunwayFrames = 12;

void validateScheduledBody(GraphBodyDefinition body) {
  validateSchedulerId(body.unitId, 'scheduled body unit');
  if (body.frameCount < 1 || body.frameCount > maxSafeInteger) {
    throw RangeError('scheduled body frame count must be positive');
  }
  if (body.kind == GraphBodyKind.held && body.frameCount != 1) {
    throw RangeError('held scheduled body must contain one frame');
  }
}

void validateResidentRunway(
  StartResidentRunwayInput input,
  String rendition,
) {
  validateSchedulerId(input.edgeId, 'resident edge');
  validateSchedulerId(input.targetState, 'resident target state');
  validateSchedulerId(input.path, 'resident path');
  validateScheduledBody(input.targetBody);
  if (input.frames.length < _minResidentRunwayFrames ||
      input.frames.length > _maxResidentRunwayFrames) {
    throw RangeError('resident runway must contain 6-12 frames');
  }
  for (var index = 0; index < input.frames.length; index += 1) {
    final frame = input.frames[index];
    _validateResidentFrame(frame);
    final expectedLocalFrame = _graphBodyFrameAt(input.targetBody, index);
    if (frame.frame.rendition != rendition ||
        frame.frame.unit != input.targetBody.unitId ||
        frame.frame.localFrame != expectedLocalFrame) {
      throw RangeError(
        'resident runway frame does not match the selected target body',
      );
    }
  }
}

void validateSchedulerLimits(DecoderWorkerLimits limits) {
  const pairs = <String>[
    'decode queue',
    'pending samples',
    'outstanding frames',
    'decoded bytes',
  ];
  final values = <int>[
    limits.maxDecodeQueueSize,
    limits.maxPendingSamples,
    limits.maxOutstandingFrames,
    limits.maxDecodedBytes,
  ];
  for (var index = 0; index < pairs.length; index += 1) {
    final value = values[index];
    if (value < 1 || value > maxSafeInteger) {
      throw RangeError('${pairs[index]} limit must be a positive safe integer');
    }
  }
}

void validateSchedulerId(String value, String label) {
  if (value.isEmpty || value.length > 128) {
    throw RangeError('$label length must be 1-128');
  }
}

void _validateResidentFrame(PathSchedulerResidentFrame frame) {
  validateSchedulerId(frame.frame.rendition, 'resident rendition');
  validateSchedulerId(frame.frame.unit, 'resident unit');
  _validateNonNegativeInteger(frame.frame.localFrame, 'resident local frame');
  _validateNonNegativeInteger(frame.unitInstance, 'resident unit instance');
  _validateNonNegativeInteger(frame.decodeOrdinal, 'resident decode ordinal');
  _validateNonNegativeInteger(frame.timestamp, 'resident timestamp');
}

void _validateNonNegativeInteger(int value, String label) {
  if (value < 0 || value > maxSafeInteger) {
    throw RangeError('$label must be a non-negative safe integer');
  }
}

/// Maps an unbounded logical body offset to its authored local frame
/// (`body-frame-semantics.ts:2`).
int _graphBodyFrameAt(GraphBodyDefinition body, int logicalFrame) {
  return body.kind == GraphBodyKind.loop
      ? logicalFrame % body.frameCount
      : (logicalFrame < body.frameCount - 1
          ? logicalFrame
          : body.frameCount - 1);
}

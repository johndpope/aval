/// The M5.5 locked/transitionless consecutive-lead formula.
///
/// Direct port of `packages/player-web/src/runtime/edge-lead.ts`. TypeScript
/// `number` counters become Dart `int`. The `"bridge" | "target-body"` string
/// union becomes the [EdgeLeadFirstPresentation] enum with wire values kept
/// exactly. `Number.MAX_SAFE_INTEGER` is kept as the literal JavaScript bound
/// for parity (see [maxSafeInteger] in `rational_time.dart`).
library;

import 'presentation_ring.dart';
import 'rational_time.dart' show maxSafeInteger;

/// Which presentation an edge lead begins with.
enum EdgeLeadFirstPresentation {
  bridge('bridge'),
  targetBody('target-body');

  const EdgeLeadFirstPresentation(this.wireValue);

  final String wireValue;
}

/// Inputs required to derive the required consecutive lead for an edge.
class RequiredEdgeLeadInput {
  const RequiredEdgeLeadInput({
    required this.transitionFrames,
    required this.ringCapacity,
  });

  /// Zero for a transitionless edge; otherwise the complete locked bridge.
  final int transitionFrames;
  final int ringCapacity;
}

/// [RequiredEdgeLeadInput] plus the measured available consecutive frames.
class EdgeLeadInput extends RequiredEdgeLeadInput {
  const EdgeLeadInput({
    required super.transitionFrames,
    required super.ringCapacity,
    required this.availableConsecutiveFrames,
  });

  final int availableConsecutiveFrames;
}

/// The resolved edge-lead plan.
class EdgeLeadPlan {
  const EdgeLeadPlan({
    required this.transitionFrames,
    required this.targetEntryOffset,
    required this.firstPresentation,
    required this.requiredConsecutiveFrames,
    required this.availableConsecutiveFrames,
    required this.missingConsecutiveFrames,
    required this.ready,
  });

  final int transitionFrames;

  /// Number of presentations before target body frame zero.
  final int targetEntryOffset;
  final EdgeLeadFirstPresentation firstPresentation;
  final int requiredConsecutiveFrames;
  final int availableConsecutiveFrames;
  final int missingConsecutiveFrames;
  final bool ready;

  @override
  bool operator ==(Object other) =>
      other is EdgeLeadPlan &&
      other.transitionFrames == transitionFrames &&
      other.targetEntryOffset == targetEntryOffset &&
      other.firstPresentation == firstPresentation &&
      other.requiredConsecutiveFrames == requiredConsecutiveFrames &&
      other.availableConsecutiveFrames == availableConsecutiveFrames &&
      other.missingConsecutiveFrames == missingConsecutiveFrames &&
      other.ready == ready;

  @override
  int get hashCode => Object.hash(
        transitionFrames,
        targetEntryOffset,
        firstPresentation,
        requiredConsecutiveFrames,
        availableConsecutiveFrames,
        missingConsecutiveFrames,
        ready,
      );

  @override
  String toString() =>
      'EdgeLeadPlan(transitionFrames: $transitionFrames, '
      'targetEntryOffset: $targetEntryOffset, '
      'firstPresentation: $firstPresentation, '
      'requiredConsecutiveFrames: $requiredConsecutiveFrames, '
      'availableConsecutiveFrames: $availableConsecutiveFrames, '
      'missingConsecutiveFrames: $missingConsecutiveFrames, ready: $ready)';
}

/// Sole owner of the M5.5 locked/transitionless consecutive-lead formula.
int calculateRequiredEdgeLeadFrames(RequiredEdgeLeadInput input) {
  validatePresentationRingCapacity(input.ringCapacity);
  _validateNonNegativeSafeInteger(
    input.transitionFrames,
    'transition frame count',
  );
  if (input.transitionFrames >= maxSafeInteger) {
    throw RangeError('transition frame count leaves no safe successor');
  }

  final sequenceThroughTargetEntry = input.transitionFrames + 1;
  return sequenceThroughTargetEntry <= input.ringCapacity
      ? (sequenceThroughTargetEntry > 2 ? sequenceThroughTargetEntry : 2)
      : input.ringCapacity;
}

EdgeLeadPlan planEdgeLead(EdgeLeadInput input) {
  final requiredConsecutiveFrames = calculateRequiredEdgeLeadFrames(input);
  _validateNonNegativeSafeInteger(
    input.availableConsecutiveFrames,
    'available consecutive frame count',
  );
  if (input.availableConsecutiveFrames > input.ringCapacity) {
    throw RangeError(
      'available consecutive frame count exceeds the presentation ring',
    );
  }

  final rawMissing =
      requiredConsecutiveFrames - input.availableConsecutiveFrames;
  final missingConsecutiveFrames = rawMissing > 0 ? rawMissing : 0;
  return EdgeLeadPlan(
    transitionFrames: input.transitionFrames,
    targetEntryOffset: input.transitionFrames,
    firstPresentation: input.transitionFrames == 0
        ? EdgeLeadFirstPresentation.targetBody
        : EdgeLeadFirstPresentation.bridge,
    requiredConsecutiveFrames: requiredConsecutiveFrames,
    availableConsecutiveFrames: input.availableConsecutiveFrames,
    missingConsecutiveFrames: missingConsecutiveFrames,
    ready: missingConsecutiveFrames == 0,
  );
}

void _validateNonNegativeSafeInteger(int value, String label) {
  if (value < 0) {
    throw RangeError('$label must be a non-negative safe integer');
  }
}

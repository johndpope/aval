/// Presentation-ring capacity bounds and validation.
///
/// **Partial port.** Only the capacity constants and
/// [validatePresentationRingCapacity] from
/// `packages/player-web/src/runtime/presentation-ring.ts` are ported here —
/// these are the sole part of that module the path-scheduler family
/// (`edge-lead.ts`, `submission-horizon.ts`) depends on. The rest of the
/// presentation ring (the ring buffer itself, `PresentationRingEntry`, the
/// take/enqueue state machine) is a later phase's responsibility and will
/// extend this file.
library;

/// Minimum accepted presentation-ring capacity (`MIN_PRESENTATION_RING_CAPACITY`).
const int minPresentationRingCapacity = 6;

/// Maximum accepted presentation-ring capacity (`MAX_PRESENTATION_RING_CAPACITY`).
const int maxPresentationRingCapacity = 12;

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

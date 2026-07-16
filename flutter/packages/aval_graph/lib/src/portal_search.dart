/// Body-frame and portal geometry, ported from
/// `packages/graph/src/portal-search.ts`.
library;

import 'errors.dart';
import 'model.dart';

/// The next local frame for a body's presentation.
class BodyFrameStep {
  const BodyFrameStep({
    required this.frameIndex,
    required this.didAdvance,
    required this.wrapped,
    required this.isHeld,
  });

  /// The local body frame to present on the next content tick.
  final int frameIndex;

  /// True when the next tick advances content, including a loop wrap.
  final bool didAdvance;

  /// True only when a looping body crosses its last-to-first seam.
  final bool wrapped;

  /// True when a finite or held body must keep its final frame displayed.
  final bool isHeld;

  @override
  bool operator ==(Object other) =>
      other is BodyFrameStep &&
      other.frameIndex == frameIndex &&
      other.didAdvance == didAdvance &&
      other.wrapped == wrapped &&
      other.isHeld == isHeld;

  @override
  int get hashCode => Object.hash(frameIndex, didAdvance, wrapped, isHeld);

  @override
  String toString() =>
      'BodyFrameStep(frameIndex: $frameIndex, didAdvance: $didAdvance, '
      'wrapped: $wrapped, isHeld: $isHeld)';
}

/// The result of searching a body for its next eligible departure boundary.
class BodyBoundarySearch {
  const BodyBoundarySearch({
    required this.boundaryFrame,
    required this.waitFrames,
    required this.eligibleNow,
    required this.wraps,
  });

  final int boundaryFrame;

  /// Number of body-frame advances between the displayed frame and boundary.
  final int waitFrames;

  /// True when the currently displayed frame is already the boundary.
  final bool eligibleNow;

  /// True when a looping body must cross its last-to-first seam.
  final bool wraps;

  @override
  bool operator ==(Object other) =>
      other is BodyBoundarySearch &&
      other.boundaryFrame == boundaryFrame &&
      other.waitFrames == waitFrames &&
      other.eligibleNow == eligibleNow &&
      other.wraps == wraps;

  @override
  int get hashCode =>
      Object.hash(boundaryFrame, waitFrames, eligibleNow, wraps);

  @override
  String toString() =>
      'BodyBoundarySearch(boundaryFrame: $boundaryFrame, waitFrames: $waitFrames, '
      'eligibleNow: $eligibleNow, wraps: $wraps)';
}

/// Return the next local frame for a body without introducing a wall clock.
///
/// Finite bodies stop on their final authored frame; held bodies never
/// advance.
BodyFrameStep nextBodyFrame(GraphBodyDefinition body, int currentFrame) {
  _assertBody(body);
  _assertCurrentFrame(body, currentFrame);

  if (body.kind == GraphBodyKind.loop) {
    final wrapped = currentFrame == body.frameCount - 1;
    return BodyFrameStep(
      frameIndex: wrapped ? 0 : currentFrame + 1,
      didAdvance: true,
      wrapped: wrapped,
      isHeld: false,
    );
  }

  final isHeld = currentFrame == body.frameCount - 1;
  return BodyFrameStep(
    frameIndex: isHeld ? currentFrame : currentFrame + 1,
    didAdvance: !isHeld,
    wrapped: false,
    isHeld: isHeld,
  );
}

/// Find the next eligible portal at or after the currently displayed body
/// frame. Looping bodies search circularly. Finite bodies never wrap and are
/// valid for portal departure only when their final held frame is a portal.
BodyBoundarySearch findNextPortalBoundary(
  GraphBodyDefinition body,
  String portId,
  int currentFrame,
) {
  final port = _resolveDeparturePort(body, portId);
  _assertCurrentFrame(body, currentFrame);

  int? directBoundary;
  for (final portalFrame in port.portalFrames) {
    if (portalFrame >= currentFrame) {
      directBoundary = portalFrame;
      break;
    }
  }

  if (directBoundary != null) {
    final waitFrames = directBoundary - currentFrame;
    return _freezeBoundary(directBoundary, waitFrames, false);
  }

  // _resolveDeparturePort guarantees that finite and held bodies end on a
  // portal, so only a loop can reach this circular-search branch.
  final boundaryFrame = port.portalFrames[0];
  final waitFrames = body.frameCount - currentFrame + boundaryFrame;
  return _freezeBoundary(boundaryFrame, waitFrames, true);
}

/// Compute the worst authored-frame wait to this port from any body phase.
///
/// This is O(portal count), not O(frame count), so hostile large frame
/// counts cannot turn validation into an unbounded scan.
int greatestPortalWaitFrames(GraphBodyDefinition body, String portId) {
  final port = _resolveDeparturePort(body, portId);
  final portals = port.portalFrames;

  if (body.kind == GraphBodyKind.loop) {
    var greatestWait = 0;
    for (var index = 0; index < portals.length; index += 1) {
      final previous = portals[index];
      final next = portals[(index + 1) % portals.length];
      final circularDistance = index == portals.length - 1
          ? body.frameCount - previous + next
          : next - previous;
      greatestWait = greatestWait > circularDistance - 1
          ? greatestWait
          : circularDistance - 1;
    }
    return greatestWait;
  }

  var greatestWait = portals[0];
  for (var index = 1; index < portals.length; index += 1) {
    final candidate = portals[index] - portals[index - 1] - 1;
    greatestWait = greatestWait > candidate ? greatestWait : candidate;
  }
  return greatestWait;
}

/// Return the finite/held final-frame boundary from the displayed frame.
BodyBoundarySearch findFinishBoundary(
  GraphBodyDefinition body,
  int currentFrame,
) {
  _assertFinishBody(body);
  _assertCurrentFrame(body, currentFrame);
  final boundaryFrame = body.frameCount - 1;
  return _freezeBoundary(boundaryFrame, boundaryFrame - currentFrame, false);
}

/// Return the greatest possible authored-frame wait for a finish policy.
int greatestFinishWaitFrames(GraphBodyDefinition body) {
  _assertFinishBody(body);
  return body.frameCount - 1;
}

GraphPortDefinition _resolveDeparturePort(
  GraphBodyDefinition body,
  String portId,
) {
  _assertBody(body);
  final matchingPorts = body.ports.where((port) => port.id == portId).toList();
  if (matchingPorts.length != 1) {
    throw MotionGraphValidationError(
      matchingPorts.isEmpty
          ? 'body ${body.unitId} has no port $portId'
          : 'body ${body.unitId} has duplicate port $portId',
    );
  }

  final port = matchingPorts[0];
  if (port.entryFrame != 0) {
    throw MotionGraphValidationError(
      'port $portId on body ${body.unitId} must enter at frame zero',
    );
  }
  if (port.portalFrames.isEmpty) {
    throw MotionGraphValidationError(
      'port $portId on body ${body.unitId} must declare a portal frame',
    );
  }

  var previous = -1;
  for (final portalFrame in port.portalFrames) {
    if (portalFrame < 0 || portalFrame >= body.frameCount) {
      throw MotionGraphValidationError(
        'port $portId on body ${body.unitId} has an out-of-range portal frame',
      );
    }
    if (portalFrame <= previous) {
      throw MotionGraphValidationError(
        'port $portId on body ${body.unitId} portal frames must be sorted and unique',
      );
    }
    previous = portalFrame;
  }

  if (body.kind != GraphBodyKind.loop &&
      port.portalFrames.last != body.frameCount - 1) {
    throw MotionGraphValidationError(
      'finite port $portId on body ${body.unitId} must include the final frame',
    );
  }

  return port;
}

void _assertBody(GraphBodyDefinition body) {
  if (body.frameCount <= 0) {
    throw MotionGraphValidationError(
      'body ${body.unitId} frameCount must be a positive safe integer',
    );
  }
  if (body.kind == GraphBodyKind.held && body.frameCount != 1) {
    throw MotionGraphValidationError(
      'held body ${body.unitId} must contain exactly one frame',
    );
  }
}

void _assertFinishBody(GraphBodyDefinition body) {
  _assertBody(body);
  if (body.kind == GraphBodyKind.loop) {
    throw MotionGraphValidationError(
      'looping body ${body.unitId} cannot use a finish boundary',
    );
  }
}

void _assertCurrentFrame(GraphBodyDefinition body, int currentFrame) {
  if (currentFrame < 0 || currentFrame >= body.frameCount) {
    throw MotionGraphValidationError(
      'current frame for body ${body.unitId} is out of range',
    );
  }
}

BodyBoundarySearch _freezeBoundary(
  int boundaryFrame,
  int waitFrames,
  bool wraps,
) {
  return BodyBoundarySearch(
    boundaryFrame: boundaryFrame,
    waitFrames: waitFrames,
    eligibleNow: waitFrames == 0,
    wraps: wraps,
  );
}

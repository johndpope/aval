/// Maps a validated compiled manifest into the sole M3 graph representation.
///
/// Dart port of `packages/format/src/graph-adapter.ts`. Depends on the
/// sibling `aval_graph` package (path dependency) for
/// `validateMotionGraphDefinition`, which — like the TypeScript original —
/// accepts a genuinely untrusted, dynamically shaped `Object?` value (a
/// `Map`/`List` tree with the exact field names `unitId`, `kind`,
/// `frameCount`, `ports`, `portalFrames`, `entryFrame`, `initialUnit`,
/// `id`, `from`, `to`, `trigger`/`type`/`name`, `start`/`type`/`sourcePort`/
/// `targetPort`/`maxWaitFrames`, `transition`/`kind`/`unitId`/`frameCount`/
/// `direction`/`reverseOf`, `continuity`) rather than the typed
/// `MotionGraphDefinition` class, exactly mirroring how
/// `packages/graph/src/validate.ts` walks its input as `unknown`. This was
/// confirmed by reading `flutter/packages/aval_graph/lib/src/validate.dart`
/// directly (see `_cloneState`/`_cloneBody`/`_clonePort`/`_cloneEdge`/
/// `_cloneTrigger`/`_cloneStart`/`_cloneTransition`).
library;

import 'package:aval_graph/aval_graph.dart' show
    MotionGraphValidationError,
    ValidatedMotionGraph,
    validateMotionGraphDefinition;

import 'errors.dart';
import 'model.dart';

/// Maps a validated compiled manifest into the sole M3 graph representation.
ValidatedMotionGraph adaptManifestToMotionGraph(CompiledManifestV01 manifest) {
  try {
    final unitsById = {for (final unit in manifest.units) unit.id: unit};
    final definition = <String, Object?>{
      'initialState': manifest.initialState,
      'states': manifest.states.map((state) => _adaptState(state, unitsById)).toList(),
      'edges': manifest.edges.map((edge) => _adaptEdge(edge, unitsById)).toList(),
    };
    return validateMotionGraphDefinition(definition);
  } on MotionGraphValidationError catch (error) {
    throw FormatError(
      FormatErrorCode.graphInvalid,
      'compiled manifest does not define a valid motion graph: ${error.message}',
    );
  } on FormatError catch (error) {
    if (error.code == FormatErrorCode.graphInvalid) rethrow;
    throw FormatError(
      FormatErrorCode.graphInvalid,
      'compiled manifest does not define a valid motion graph: ${error.message}',
    );
  } catch (error) {
    throw FormatError(
      FormatErrorCode.graphInvalid,
      'compiled manifest does not define a valid motion graph: $error',
    );
  }
}

Map<String, Object?> _adaptState(StateV01 state, Map<String, UnitV01> unitsById) {
  final body = unitsById[state.bodyUnit];
  if (body is! BodyUnitV01) {
    _graphInvalid('state ${_quote(state.id)} has no body unit');
  }
  final graphBody = <String, Object?>{
    'unitId': body.id,
    'kind': body.playback == 'loop' ? 'loop' : (body.frameCount == 1 ? 'held' : 'finite'),
    'frameCount': body.frameCount,
    'ports': body.ports
        .map((port) => <String, Object?>{
              'id': port.id,
              'entryFrame': 0,
              'portalFrames': [...port.portalFrames],
            })
        .toList(),
  };
  final base = <String, Object?>{'id': state.id, 'body': graphBody};
  if (state.initialUnit == null) {
    return base;
  }
  final initial = unitsById[state.initialUnit];
  if (initial is! OneShotUnitV01) {
    _graphInvalid('state ${_quote(state.id)} has no one-shot initial unit');
  }
  return {
    ...base,
    'initialUnit': {'unitId': initial.id, 'frameCount': initial.frameCount},
  };
}

Map<String, Object?> _adaptEdge(EdgeV01 edge, Map<String, UnitV01> unitsById) {
  final base = <String, Object?>{
    'id': edge.id,
    'from': edge.from,
    'to': edge.to,
    'start': _adaptStart(edge.start),
    'continuity': edge.continuity,
  };
  if (edge.trigger != null) {
    base['trigger'] = _adaptTrigger(edge.trigger!);
  }
  if (edge is NonCutEdgeV01 && edge.transition != null) {
    base['transition'] = _adaptTransition(edge.transition!, unitsById);
  }
  return base;
}

Map<String, Object?> _adaptTrigger(TriggerV01 trigger) {
  if (trigger is EventTriggerV01) {
    return {'type': 'event', 'name': trigger.name};
  }
  return {'type': 'completion'};
}

Map<String, Object?> _adaptStart(StartV01 start) {
  if (start is PortalStartV01) {
    return {
      'type': 'portal',
      'sourcePort': start.sourcePort,
      'targetPort': start.targetPort,
      'maxWaitFrames': start.maxWaitFrames,
    };
  }
  if (start is FinishStartV01) {
    return {'type': 'finish', 'targetPort': start.targetPort, 'maxWaitFrames': start.maxWaitFrames};
  }
  return {'type': 'cut', 'targetPort': start.targetPort, 'maxWaitFrames': 1};
}

Map<String, Object?> _adaptTransition(TransitionV01 transition, Map<String, UnitV01> unitsById) {
  final unit = unitsById[transition.unit];
  if (transition is LockedTransitionV01) {
    if (unit is! BridgeUnitV01) {
      _graphInvalid('locked transition has no bridge unit ${_quote(transition.unit)}');
    }
    return {'kind': 'locked', 'unitId': unit.id, 'frameCount': unit.frameCount};
  }
  final reversible = transition as ReversibleTransitionV01;
  if (unit is! ReversibleUnitV01) {
    _graphInvalid('reversible transition has no reversible unit ${_quote(transition.unit)}');
  }
  final base = <String, Object?>{
    'kind': 'reversible',
    'unitId': unit.id,
    'frameCount': unit.frameCount,
    'direction': reversible.direction,
  };
  return reversible.reverseOf == null ? base : {...base, 'reverseOf': reversible.reverseOf};
}

Never _graphInvalid(String message) {
  throw FormatError(FormatErrorCode.graphInvalid, message);
}

String _quote(String value) => '"$value"';

/// Maps a validated compiled manifest into the canonical motion graph.
///
/// Dart port of `packages/format/src/graph-adapter.ts` (1.0). Depends on the
/// sibling `aval_graph` package for `validateMotionGraphDefinition`, which —
/// like the TypeScript original — accepts a genuinely untrusted, dynamically
/// shaped `Object?` value (a `Map`/`List` tree with the exact field names
/// `unitId`, `kind`, `frameCount`, `ports`, `portalFrames`, `entryFrame`,
/// `initialUnit`, `id`, `from`, `to`, `trigger`/`type`/`name`, `start`/`type`/
/// `sourcePort`/`targetPort`/`maxWaitFrames`, `transition`/`kind`/`unitId`/
/// `frameCount`/`direction`/`reverseOf`, `continuity`) rather than a typed
/// definition class, mirroring how `packages/graph/src/validate.ts` walks its
/// input as `unknown`.
library;

import 'package:aval_graph/aval_graph.dart'
    show MotionGraphValidationError, ValidatedMotionGraph, validateMotionGraphDefinition;

import 'errors.dart';
import 'model.dart';

/// Map a validated compiled manifest into the canonical motion graph.
ValidatedMotionGraph adaptManifestToMotionGraph(CompiledManifest manifest) {
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

Map<String, Object?> _adaptState(State state, Map<String, Unit> unitsById) {
  final body = unitsById[state.bodyUnit];
  if (body is! BodyUnit) {
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
  if (initial is! OneShotUnit) {
    _graphInvalid('state ${_quote(state.id)} has no one-shot initial unit');
  }
  return {
    ...base,
    'initialUnit': {'unitId': initial.id, 'frameCount': initial.frameCount},
  };
}

Map<String, Object?> _adaptEdge(Edge edge, Map<String, Unit> unitsById) {
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
  if (edge is NonCutEdge && edge.transition != null) {
    base['transition'] = _adaptTransition(edge.transition!, unitsById);
  }
  return base;
}

Map<String, Object?> _adaptTrigger(Trigger trigger) {
  if (trigger is EventTrigger) {
    return {'type': 'event', 'name': trigger.name};
  }
  return {'type': 'completion'};
}

Map<String, Object?> _adaptStart(Start start) {
  if (start is PortalStart) {
    return {
      'type': 'portal',
      'sourcePort': start.sourcePort,
      'targetPort': start.targetPort,
      'maxWaitFrames': start.maxWaitFrames,
    };
  }
  if (start is FinishStart) {
    return {'type': 'finish', 'targetPort': start.targetPort, 'maxWaitFrames': start.maxWaitFrames};
  }
  return {'type': 'cut', 'targetPort': start.targetPort, 'maxWaitFrames': 1};
}

Map<String, Object?> _adaptTransition(Transition transition, Map<String, Unit> unitsById) {
  final unit = unitsById[transition.unit];
  if (transition is LockedTransition) {
    if (unit is! BridgeUnit) {
      _graphInvalid('locked transition has no bridge unit ${_quote(transition.unit)}');
    }
    return {'kind': 'locked', 'unitId': unit.id, 'frameCount': unit.frameCount};
  }
  final reversible = transition as ReversibleTransition;
  if (unit is! ReversibleUnit) {
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

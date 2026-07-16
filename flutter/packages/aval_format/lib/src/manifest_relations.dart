/// Cross-referential manifest validation: state/edge/unit/binding relations.
///
/// Dart port of `packages/format/src/manifest-relations.ts`.
library;

import 'manifest_validation.dart';
import 'model.dart';

class ManifestRelationInput {
  const ManifestRelationInput({
    required this.initialState,
    required this.renditions,
    required this.units,
    required this.states,
    required this.edges,
    required this.bindings,
    required this.readiness,
  });

  final String initialState;
  final List<RenditionV01> renditions;
  final List<UnitV01> units;
  final List<StateV01> states;
  final List<EdgeV01> edges;
  final List<BindingV01> bindings;
  final ReadinessV01 readiness;
}

void validateManifestRelations(ManifestRelationInput input) {
  final unitsById = {for (final unit in input.units) unit.id: unit};
  final statesById = {for (final state in input.states) state.id: state};
  final edgesById = {for (final edge in input.edges) edge.id: edge};
  if (!statesById.containsKey(input.initialState)) {
    invalid('initialState', 'does not reference a state');
  }

  final unitUseCount = {for (final unit in input.units) unit.id: 0};
  for (var index = 0; index < input.states.length; index += 1) {
    final state = input.states[index];
    final path = 'states[$index]';
    final body = unitsById[state.bodyUnit];
    if (body is! BodyUnitV01) {
      invalid('$path.bodyUnit', 'must reference a body unit');
    }
    _incrementUse(unitUseCount, body.id);
    if (state.initialUnit != null) {
      if (state.id != input.initialState) {
        invalid('$path.initialUnit', 'is allowed only on the initial state');
      }
      final initial = unitsById[state.initialUnit];
      if (initial is! OneShotUnitV01) {
        invalid('$path.initialUnit', 'must reference a one-shot unit');
      }
      _incrementUse(unitUseCount, initial.id);
    }
  }

  final reversibleEdges = <String, List<({EdgeV01 edge, int index})>>{};
  final eventNames = <String>{};
  for (var index = 0; index < input.edges.length; index += 1) {
    final edge = input.edges[index];
    _validateEdgeReferences(edge, index, statesById, unitsById, unitUseCount);
    final trigger = edge.trigger;
    if (trigger is EventTriggerV01) {
      eventNames.add(trigger.name);
    }
    final transition = edge is NonCutEdgeV01 ? edge.transition : null;
    if (transition is ReversibleTransitionV01) {
      final group = reversibleEdges.putIfAbsent(transition.unit, () => []);
      group.add((edge: edge, index: index));
    }
  }

  _validateReversibleGroups(reversibleEdges, unitsById);
  _validateUseCounts(input.units, unitUseCount);
  for (var index = 0; index < input.bindings.length; index += 1) {
    if (!eventNames.contains(input.bindings[index].event)) {
      invalid('bindings[$index].event', 'is not used by an event-triggered edge');
    }
  }
  _validateReadiness(input.readiness, input.initialState, statesById, edgesById, unitsById);
}

void validateBlobCount(List<UnitV01> units, List<RenditionV01> renditions, FormatBudgets budgets) {
  _rejectBlobCount(units.length * renditions.length, budgets);
}

void validateRawBlobCount(Object? units, int renditionCount, FormatBudgets budgets) {
  if (units is! List) {
    invalid('units', 'must be an array');
  }
  _rejectBlobCount(units.length * renditionCount, budgets);
}

void _rejectBlobCount(int count, FormatBudgets budgets) {
  if (count > budgets.maxBlobRanges) {
    invalid('manifest', 'declares $count blobs, exceeding ${budgets.maxBlobRanges}');
  }
}

void _validateEdgeReferences(
  EdgeV01 edge,
  int index,
  Map<String, StateV01> statesById,
  Map<String, UnitV01> unitsById,
  Map<String, int> unitUseCount,
) {
  final path = 'edges[$index]';
  final source = statesById[edge.from];
  final target = statesById[edge.to];
  if (source == null) {
    invalid('$path.from', 'does not reference a state');
  }
  if (target == null) {
    invalid('$path.to', 'does not reference a state');
  }
  final sourceBody = unitsById[source.bodyUnit];
  final targetBody = unitsById[target.bodyUnit];
  if (sourceBody is! BodyUnitV01 || targetBody is! BodyUnitV01) {
    invalid(path, 'state body reference is invalid');
  }
  if (!targetBody.ports.any((port) => port.id == edge.start.targetPort)) {
    invalid('$path.start.targetPort', 'does not reference the target body');
  }
  final start = edge.start;
  if (start is PortalStartV01) {
    final sourcePortId = start.sourcePort;
    PortV01? sourcePort;
    for (final port in sourceBody.ports) {
      if (port.id == sourcePortId) {
        sourcePort = port;
        break;
      }
    }
    if (sourcePort == null) {
      invalid('$path.start.sourcePort', 'does not reference the source body');
    }
    if (sourceBody.playback == 'finite' &&
        (sourcePort.portalFrames.isEmpty ||
            sourcePort.portalFrames.last != sourceBody.frameCount - 1)) {
      invalid('$path.start.sourcePort', 'finite source port must include the held final frame');
    }
  } else if (start is FinishStartV01 && sourceBody.playback == 'loop') {
    invalid('$path.start.type', 'finish cannot originate from a looping body');
  }

  final transition = edge is NonCutEdgeV01 ? edge.transition : null;
  if (transition is LockedTransitionV01) {
    final unit = unitsById[transition.unit];
    if (unit is! BridgeUnitV01) {
      invalid('$path.transition.unit', 'must reference a bridge unit');
    }
    _incrementUse(unitUseCount, unit.id);
    if (edge.continuity != 'exact-authored') {
      invalid('$path.continuity', 'locked transitions require exact-authored');
    }
  } else if (transition is ReversibleTransitionV01) {
    final unit = unitsById[transition.unit];
    if (unit is! ReversibleUnitV01) {
      invalid('$path.transition.unit', 'must reference a reversible unit');
    }
    _incrementUse(unitUseCount, unit.id);
  } else if (edge.start.type != 'cut' && edge.continuity != 'exact-authored') {
    invalid('$path.continuity', 'transitionless edges require exact-authored');
  }
}

void _validateReversibleGroups(
  Map<String, List<({EdgeV01 edge, int index})>> groups,
  Map<String, UnitV01> unitsById,
) {
  for (final entry in groups.entries) {
    final unitId = entry.key;
    final group = entry.value;
    if (group.length != 2) {
      invalid('edges', 'reversible unit ${quote(unitId)} must have two inverse edges');
    }
    final first = group[0];
    final second = group[1];
    ({EdgeV01 edge, int index})? primary;
    ({EdgeV01 edge, int index})? inverse;
    for (final candidate in [first, second]) {
      final transition =
          candidate.edge is NonCutEdgeV01 ? (candidate.edge as NonCutEdgeV01).transition : null;
      if (transition is ReversibleTransitionV01 && transition.direction == 'forward') {
        primary = candidate;
      }
      if (transition is ReversibleTransitionV01 && transition.direction == 'reverse') {
        inverse = candidate;
      }
    }
    if (primary == null || inverse == null) {
      invalid('edges', 'reversible unit ${quote(unitId)} needs forward and reverse edges');
    }
    final primaryTransition =
        primary.edge is NonCutEdgeV01 ? (primary.edge as NonCutEdgeV01).transition : null;
    final inverseTransition =
        inverse.edge is NonCutEdgeV01 ? (inverse.edge as NonCutEdgeV01).transition : null;
    if (primaryTransition is! ReversibleTransitionV01 || inverseTransition is! ReversibleTransitionV01) {
      invalid('edges', 'reversible unit ${quote(unitId)} has invalid transitions');
    }
    if (primaryTransition.reverseOf != null) {
      invalid('edges[${primary.index}].transition.reverseOf', 'must be omitted on the primary edge');
    }
    if (inverseTransition.reverseOf != primary.edge.id) {
      invalid('edges[${inverse.index}].transition.reverseOf', 'must reference the primary edge');
    }
    if (primary.edge.continuity != 'exact-authored' || inverse.edge.continuity != 'exact-reverse') {
      invalid('edges', 'reversible pair continuity is invalid');
    }
    if (primary.edge.from != inverse.edge.to || primary.edge.to != inverse.edge.from) {
      invalid('edges', 'reversible pair must reverse its states');
    }
    final unit = unitsById[unitId];
    if (unit is! ReversibleUnitV01) {
      invalid('edges', 'reversible unit ${quote(unitId)} is missing');
    }
    _validateResidencyForEdge(unit, primary.edge, primary.index);
    _validateResidencyForEdge(unit, inverse.edge, inverse.index);
  }
}

void _validateResidencyForEdge(ReversibleUnitV01 unit, EdgeV01 edge, int index) {
  final path = 'edges[$index]';
  ResidencyEndpointV01? source;
  ResidencyEndpointV01? target;
  for (final endpoint in unit.residency.endpoints) {
    if (endpoint.state == edge.from) source = endpoint;
    if (endpoint.state == edge.to) target = endpoint;
  }
  if (source == null || target == null || source == target) {
    invalid(path, 'must connect the reversible residency states');
  }
  final start = edge.start;
  if (start is PortalStartV01 && start.sourcePort != source.port) {
    invalid('$path.start.sourcePort', 'must match source residency endpoint');
  }
  if (edge.start.targetPort != target.port) {
    invalid('$path.start.targetPort', 'must match target residency endpoint');
  }
}

void _validateUseCounts(List<UnitV01> units, Map<String, int> counts) {
  for (final unit in units) {
    final count = counts[unit.id] ?? 0;
    final expected = unit is ReversibleUnitV01 ? 2 : 1;
    if (count != expected) {
      invalid(
        'units',
        '${unit.kind} unit ${quote(unit.id)} must be referenced exactly $expected time${expected == 1 ? '' : 's'}',
      );
    }
  }
}

void _validateReadiness(
  ReadinessV01 readiness,
  String initialStateId,
  Map<String, StateV01> statesById,
  Map<String, EdgeV01> edgesById,
  Map<String, UnitV01> unitsById,
) {
  final immediate = edgesById.values.where((edge) => edge.from == initialStateId).map((edge) => edge.id).toList()
    ..sort(compareAscii);
  if (!_sameStrings(readiness.immediateEdges, immediate)) {
    invalid('readiness.immediateEdges', 'must exactly list edges originating at initialState');
  }
  final bootstrap = readiness.bootstrapUnits.toSet();
  for (var index = 0; index < readiness.bootstrapUnits.length; index += 1) {
    if (!unitsById.containsKey(readiness.bootstrapUnits[index])) {
      invalid('readiness.bootstrapUnits[$index]', 'does not reference a unit');
    }
  }
  final initial = statesById[initialStateId]!;
  final required = <String>{initial.bodyUnit};
  if (initial.initialUnit != null) required.add(initial.initialUnit!);
  for (final edgeId in immediate) {
    final edge = edgesById[edgeId]!;
    required.add(statesById[edge.to]!.bodyUnit);
    final transition = edge is NonCutEdgeV01 ? edge.transition : null;
    if (transition != null) required.add(transition.unit);
  }
  for (final unitId in required) {
    if (!bootstrap.contains(unitId)) {
      invalid('readiness.bootstrapUnits', 'must include required unit ${quote(unitId)}');
    }
  }
}

bool _sameStrings(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

void _incrementUse(Map<String, int> counts, String id) {
  counts[id] = (counts[id] ?? 0) + 1;
}

/// State, edge, binding, and readiness schema validation.
///
/// Dart port of `packages/format/src/manifest-graph-schema.ts` (1.0).
library;

import 'manifest_constraints.dart';
import 'manifest_validation.dart';
import 'model.dart';

const Set<String> _bindingSources = {
  'activate',
  'engagement.off',
  'engagement.on',
  'focus.in',
  'focus.out',
  'hidden',
  'pointer.enter',
  'pointer.leave',
  'visible',
};

List<State> cloneStates(Object? value, FormatBudgets budgets, String path) {
  final inputs = boundedArray(value, path, 1, budgets.maxStates);
  final states = <State>[
    for (var index = 0; index < inputs.length; index += 1)
      _cloneState(inputs[index], '$path[$index]'),
  ];
  requireIdOrder<State>(states, (s) => s.id, path);
  return states;
}

State _cloneState(Object? entry, String statePath) {
  final input = record(entry, statePath);
  exactKeys(input, ['id', 'bodyUnit'], statePath, ['initialUnit']);
  final id = identifier(input['id'], '$statePath.id');
  final bodyUnit = identifier(input['bodyUnit'], '$statePath.bodyUnit');
  if (!owns(input, 'initialUnit')) {
    return State(id: id, bodyUnit: bodyUnit);
  }
  return State(
    id: id,
    bodyUnit: bodyUnit,
    initialUnit: identifier(input['initialUnit'], '$statePath.initialUnit'),
  );
}

List<Edge> cloneEdges(Object? value, FormatBudgets budgets, String path) {
  final inputs = boundedArray(value, path, 0, budgets.maxEdges);
  final edges = <Edge>[
    for (var index = 0; index < inputs.length; index += 1)
      _cloneEdge(inputs[index], '$path[$index]'),
  ];
  requireIdOrder<Edge>(edges, (e) => e.id, path);
  return edges;
}

Edge _cloneEdge(Object? value, String path) {
  final input = record(value, path);
  final startProbe = record(input['start'], '$path.start');
  final cut = startProbe['type'] == 'cut';
  exactKeys(
    input,
    cut
        ? ['id', 'from', 'to', 'start', 'continuity', 'targetRunwayFrames']
        : ['id', 'from', 'to', 'start', 'continuity'],
    path,
    cut ? ['trigger'] : ['trigger', 'transition'],
  );
  final id = identifier(input['id'], '$path.id');
  final from = identifier(input['from'], '$path.from');
  final to = identifier(input['to'], '$path.to');
  if (from == to) {
    invalid('$path.to', 'must differ from from');
  }
  final trigger =
      owns(input, 'trigger') ? _cloneTrigger(input['trigger'], '$path.trigger') : null;
  final start = _cloneStart(input['start'], '$path.start');

  if (start.type == 'cut') {
    literal(input['continuity'], 'cut', '$path.continuity');
    final targetRunwayFrames = integerInRange(
      input['targetRunwayFrames'],
      '$path.targetRunwayFrames',
      minRunwayFrames,
      maxRunwayFrames,
    );
    return CutEdge(
      id: id,
      from: from,
      to: to,
      trigger: trigger,
      start: start as CutStart,
      targetRunwayFrames: targetRunwayFrames,
    );
  }

  final continuity =
      oneOf(input['continuity'], ['exact-authored', 'exact-reverse'], '$path.continuity');
  final transition =
      owns(input, 'transition') ? _cloneTransition(input['transition'], '$path.transition') : null;
  return NonCutEdge(
    id: id,
    from: from,
    to: to,
    trigger: trigger,
    start: start,
    continuity: continuity,
    transition: transition,
  );
}

Trigger _cloneTrigger(Object? value, String path) {
  final input = record(value, path);
  if (input['type'] == 'completion') {
    exactKeys(input, ['type'], path);
    return const CompletionTrigger();
  }
  if (input['type'] == 'event') {
    exactKeys(input, ['type', 'name'], path);
    return EventTrigger(identifier(input['name'], '$path.name'));
  }
  invalid('$path.type', 'must be event or completion');
}

Start _cloneStart(Object? value, String path) {
  final input = record(value, path);
  if (input['type'] == 'portal') {
    exactKeys(input, ['type', 'sourcePort', 'targetPort', 'maxWaitFrames'], path);
    return PortalStart(
      sourcePort: identifier(input['sourcePort'], '$path.sourcePort'),
      targetPort: identifier(input['targetPort'], '$path.targetPort'),
      maxWaitFrames: nonNegativeInteger(input['maxWaitFrames'], '$path.maxWaitFrames'),
    );
  }
  if (input['type'] == 'finish') {
    exactKeys(input, ['type', 'targetPort', 'maxWaitFrames'], path);
    return FinishStart(
      targetPort: identifier(input['targetPort'], '$path.targetPort'),
      maxWaitFrames: nonNegativeInteger(input['maxWaitFrames'], '$path.maxWaitFrames'),
    );
  }
  if (input['type'] == 'cut') {
    exactKeys(input, ['type', 'targetPort', 'maxWaitFrames'], path);
    literal(input['maxWaitFrames'], 1, '$path.maxWaitFrames');
    return CutStart(targetPort: identifier(input['targetPort'], '$path.targetPort'));
  }
  invalid('$path.type', 'must be portal, finish, or cut');
}

Transition _cloneTransition(Object? value, String path) {
  final input = record(value, path);
  if (input['kind'] == 'locked') {
    exactKeys(input, ['kind', 'unit'], path);
    return LockedTransition(unit: identifier(input['unit'], '$path.unit'));
  }
  if (input['kind'] == 'reversible') {
    exactKeys(input, ['kind', 'unit', 'direction'], path, ['reverseOf']);
    final unit = identifier(input['unit'], '$path.unit');
    final direction = oneOf(input['direction'], ['forward', 'reverse'], '$path.direction');
    if (!owns(input, 'reverseOf')) {
      return ReversibleTransition(unit: unit, direction: direction);
    }
    return ReversibleTransition(
      unit: unit,
      direction: direction,
      reverseOf: identifier(input['reverseOf'], '$path.reverseOf'),
    );
  }
  invalid('$path.kind', 'must be locked or reversible');
}

List<Binding> cloneBindings(Object? value, FormatBudgets budgets, String path) {
  final inputs = boundedArray(value, path, 0, budgets.maxBindings);
  final bindings = <Binding>[
    for (var index = 0; index < inputs.length; index += 1)
      _cloneBinding(inputs[index], '$path[$index]'),
  ];
  for (var index = 1; index < bindings.length; index += 1) {
    final previous = bindings[index - 1];
    final current = bindings[index];
    final order = compareAscii(previous.source, current.source) != 0
        ? compareAscii(previous.source, current.source)
        : compareAscii(previous.event, current.event);
    if (order >= 0) {
      invalid(path, 'must be sorted and unique by source then event');
    }
    if (previous.source == current.source) {
      invalid('$path[$index].source', 'duplicates a binding source');
    }
  }
  return bindings;
}

Binding _cloneBinding(Object? entry, String bindingPath) {
  final input = record(entry, bindingPath);
  exactKeys(input, ['source', 'event'], bindingPath);
  final source = input['source'];
  if (source is! String || !_bindingSources.contains(source)) {
    invalid('$bindingPath.source', 'is not a supported binding source');
  }
  return Binding(source: source, event: identifier(input['event'], '$bindingPath.event'));
}

Readiness cloneReadiness(Object? value, FormatBudgets budgets, String path) {
  final input = record(value, path);
  exactKeys(input, ['policy', 'bootstrapUnits', 'immediateEdges'], path);
  literal(input['policy'], 'all-routes', '$path.policy');
  final bootstrapUnits =
      _cloneIdArray(input['bootstrapUnits'], budgets.maxUnits, '$path.bootstrapUnits');
  final immediateEdges =
      _cloneIdArray(input['immediateEdges'], budgets.maxEdges, '$path.immediateEdges');
  return Readiness(bootstrapUnits: bootstrapUnits, immediateEdges: immediateEdges);
}

List<String> _cloneIdArray(Object? value, int maximum, String path) {
  final inputs = boundedArray(value, path, 0, maximum);
  final ids = <String>[
    for (var index = 0; index < inputs.length; index += 1)
      identifier(inputs[index], '$path[$index]'),
  ];
  requireStringOrder(ids, path);
  return ids;
}

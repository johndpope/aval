// Ported from packages/graph/test/validate.test.ts
//
// The TypeScript original constructs plain object/array literals — some
// deliberately malformed (sparse arrays, wrong-typed fields) — because
// validate.ts treats its input as fully untrusted at runtime regardless of
// its nominal `MotionGraphDefinition` parameter type. This port mirrors that
// intent literally: every fixture here is a `Map<String, Object?>` /
// `List<Object?>` tree (the natural Dart shape for untrusted/JSON-like data)
// rather than the package's own typed model classes, and
// `validateMotionGraphDefinition` is exercised exactly as it is meant to be
// used at a real trust boundary (e.g. a JSON graph asset loaded at runtime).
import 'package:aval_graph/aval_graph.dart';
import 'package:aval_graph/src/validate.dart' show getValidatedGraphIndexes;
import 'package:test/test.dart';

void main() {
  group('validateMotionGraphDefinition', () {
    test('returns a detached definition with independently queryable indexes', () {
      final input = _reversibleGraph();
      final validated = validateMotionGraphDefinition(input);
      final indexes = getValidatedGraphIndexes(validated);

      expect(validated.definition.states[0].id, 'idle');
      expect(indexes.statesById['idle'], same(validated.definition.states[0]));
      expect(indexes.edgesById['idle-to-hover'], same(validated.definition.edges[0]));
      expect(indexes.portsByState['idle']!['handoff']!.entryFrame, 0);
      expect(indexes.directEdgesByState['idle']!['hover']!.id, 'idle-to-hover');
      expect(indexes.eventEdgesByState['hover']!['hover.leave']!.id, 'hover-to-idle');
      expect(indexes.inverseEdgesById['idle-to-hover']!.id, 'hover-to-idle');
      expect(indexes.inverseEdgesById['hover-to-idle']!.id, 'idle-to-hover');

      // Mutating the untrusted input after validation must not affect the
      // already-produced validated graph (structural detachment).
      (input['states']! as List)[0] = _state('changed', 'loop');
      expect(validated.definition.states[0].id, 'idle');
    });

    test('rejects a ValidatedMotionGraph instance not produced by this validator', () {
      final fake = ValidatedMotionGraph(
        MotionGraphDefinition(
          initialState: 'idle',
          states: [
            GraphStateDefinition(
              id: 'idle',
              body: GraphBodyDefinition(
                unitId: 'idle-body',
                kind: GraphBodyKind.loop,
                frameCount: 1,
                ports: [GraphPortDefinition(id: 'handoff', portalFrames: const [0])],
              ),
            ),
          ],
          edges: const [],
        ),
      );
      expect(() => getValidatedGraphIndexes(fake), throwsA(isA<MotionGraphValidationError>()));
    });

    test('enforces state and edge count limits', () {
      final empty = _simpleGraph();
      empty['states'] = <Object?>[];
      _expectInvalid(empty, RegExp('states must contain between 1 and 32'));

      final tooManyStates = _simpleGraph();
      tooManyStates['states'] = [
        for (var index = 0; index < GraphLimits.maxStates + 1; index += 1)
          _state('state-$index', 'held'),
      ];
      tooManyStates['initialState'] = 'state-0';
      _expectInvalid(tooManyStates, RegExp('states must contain between 1 and 32'));

      final tooManyEdges = _simpleGraph();
      tooManyEdges['edges'] = [
        for (var index = 0; index < GraphLimits.maxEdges + 1; index += 1)
          {
            'id': 'edge-$index',
            'from': 'idle',
            'to': 'hover',
            'start': {'type': 'cut', 'targetPort': 'handoff', 'maxWaitFrames': 1},
            'continuity': 'cut',
          },
      ];
      _expectInvalid(tooManyEdges, RegExp('edges must contain at most 64'));
    });

    test('rejects malformed array entries with a stable validation error', () {
      final sparseStates = _simpleGraph();
      sparseStates['states'] = [null];
      _expectInvalid(sparseStates, RegExp(r'states\[0\] must be an object'));

      final sparseEdges = _simpleGraph();
      sparseEdges['edges'] = [null];
      _expectInvalid(sparseEdges, RegExp(r'edges\[0\] must be an object'));

      final sparsePorts = _simpleGraph();
      final states = sparsePorts['states']! as List;
      final state0 = Map<String, Object?>.from(states[0]! as Map);
      final body0 = Map<String, Object?>.from(state0['body']! as Map);
      body0['ports'] = [null];
      state0['body'] = body0;
      states[0] = state0;
      _expectInvalid(sparsePorts, RegExp(r'states\[0\]\.body\.ports\[0\] must be an object'));
    });

    test('validates IDs, initial ownership, frames, and state-level uniqueness', () {
      final invalidId = _simpleGraph();
      final statesA = invalidId['states']! as List;
      statesA[0] = {...(statesA[0]! as Map<String, Object?>), 'id': 'Idle'};
      _expectInvalid(invalidId, RegExp('must match'));

      final missingInitial = _simpleGraph();
      missingInitial['initialState'] = 'missing';
      _expectInvalid(missingInitial, RegExp('does not reference a state'));

      final duplicateState = _simpleGraph();
      final statesB = duplicateState['states']! as List;
      statesB[1] = {...(statesB[1]! as Map<String, Object?>), 'id': 'idle'};
      _expectInvalid(duplicateState, RegExp('duplicates state ID'));

      final duplicateUnit = _simpleGraph();
      final statesC = duplicateUnit['states']! as List;
      final state1 = Map<String, Object?>.from(statesC[1]! as Map);
      state1['body'] = {...(state1['body']! as Map<String, Object?>), 'unitId': 'idle-body'};
      statesC[1] = state1;
      _expectInvalid(duplicateUnit, RegExp('duplicates unit ID'));

      final heldLength = _simpleGraph();
      final statesD = heldLength['states']! as List;
      final state0d = Map<String, Object?>.from(statesD[0]! as Map);
      state0d['body'] = {...(state0d['body']! as Map<String, Object?>), 'kind': 'held', 'frameCount': 2};
      statesD[0] = state0d;
      _expectInvalid(heldLength, RegExp('must be 1 for a held body'));

      final nonInitialIntro = _simpleGraph();
      final statesE = nonInitialIntro['states']! as List;
      statesE[1] = {
        ...(statesE[1]! as Map<String, Object?>),
        'initialUnit': {'unitId': 'wrong-intro', 'frameCount': 2},
      };
      _expectInvalid(nonInitialIntro, RegExp('allowed only on the initial state'));

      final duplicateIntroUnit = _simpleGraph();
      final statesF = duplicateIntroUnit['states']! as List;
      statesF[0] = {
        ...(statesF[0]! as Map<String, Object?>),
        'initialUnit': {'unitId': 'idle-body', 'frameCount': 2},
      };
      _expectInvalid(duplicateIntroUnit, RegExp('duplicates unit ID'));
    });

    test('validates port counts, identities, entry frames, and portal frames', () {
      final tooMany = _simpleGraph();
      final statesA = tooMany['states']! as List;
      final state0a = Map<String, Object?>.from(statesA[0]! as Map);
      state0a['body'] = {
        ...(state0a['body']! as Map<String, Object?>),
        'ports': [
          for (var index = 0; index < GraphLimits.maxPortsPerBody + 1; index += 1)
            {'id': 'port-$index', 'entryFrame': 0, 'portalFrames': [0]},
        ],
      };
      statesA[0] = state0a;
      _expectInvalid(tooMany, RegExp('ports must contain at most 16'));

      final duplicate = _simpleGraph();
      final statesB = duplicate['states']! as List;
      final state0b = Map<String, Object?>.from(statesB[0]! as Map);
      state0b['body'] = {...(state0b['body']! as Map<String, Object?>), 'ports': [_port(), _port()]};
      statesB[0] = state0b;
      _expectInvalid(duplicate, RegExp('duplicates port ID'));

      final wrongEntry = _simpleGraph();
      final statesC = wrongEntry['states']! as List;
      final state0c = Map<String, Object?>.from(statesC[0]! as Map);
      state0c['body'] = {
        ...(state0c['body']! as Map<String, Object?>),
        'ports': [{..._port(), 'entryFrame': 1}],
      };
      statesC[0] = state0c;
      _expectInvalid(wrongEntry, RegExp('entryFrame must be 0'));

      final empty = _simpleGraph();
      final statesD = empty['states']! as List;
      statesD[0] = _withPortalFrames(statesD[0]! as Map<String, Object?>, const []);
      _expectInvalid(empty, RegExp('must contain at least one frame'));

      final unsorted = _simpleGraph();
      final statesE = unsorted['states']! as List;
      statesE[0] = _withPortalFrames(statesE[0]! as Map<String, Object?>, const [2, 1]);
      _expectInvalid(unsorted, RegExp('sorted and unique'));

      final duplicateFrame = _simpleGraph();
      final statesF = duplicateFrame['states']! as List;
      statesF[0] = _withPortalFrames(statesF[0]! as Map<String, Object?>, const [0, 0]);
      _expectInvalid(duplicateFrame, RegExp('sorted and unique'));

      final outside = _simpleGraph();
      final statesG = outside['states']! as List;
      statesG[0] = _withPortalFrames(statesG[0]! as Map<String, Object?>, const [4]);
      _expectInvalid(outside, RegExp('must be less than frameCount'));
    });

    test('rejects missing references and ambiguous direct, event, and completion routes', () {
      final missingSource = _simpleGraph();
      missingSource['edges'] = [_cutEdge('missing-source', 'missing', 'hover')];
      _expectInvalid(missingSource, RegExp('from does not reference a state'));

      final missingTarget = _simpleGraph();
      missingTarget['edges'] = [_cutEdge('missing-target', 'idle', 'missing')];
      _expectInvalid(missingTarget, RegExp('to does not reference a state'));

      final self = _simpleGraph();
      self['edges'] = [_cutEdge('self', 'idle', 'idle')];
      _expectInvalid(self, RegExp('must connect distinct states'));

      final direct = _simpleGraph();
      direct['edges'] = [_cutEdge('first', 'idle', 'hover'), _cutEdge('second', 'idle', 'hover')];
      _expectInvalid(direct, RegExp('duplicates direct route'));

      final event = _threeStateGraph();
      event['edges'] = [
        _eventCutEdge('first', 'idle', 'hover', 'activate'),
        _eventCutEdge('second', 'idle', 'error', 'activate'),
      ];
      _expectInvalid(event, RegExp('duplicates event'));

      final completion = _threeStateGraph('finite');
      final completionStates = completion['states']! as List;
      completionStates[0] = _withPortalFrames(completionStates[0]! as Map<String, Object?>, const [0, 3]);
      completion['edges'] = [
        _completionFinishEdge('first', 'idle', 'hover', 3),
        _completionFinishEdge('second', 'idle', 'error', 3),
      ];
      _expectInvalid(completion, RegExp('duplicates completion route'));

      final loopCompletion = _simpleGraph();
      loopCompletion['edges'] = [_completionFinishEdge('complete', 'idle', 'hover', 3)];
      _expectInvalid(loopCompletion, RegExp('completion trigger cannot originate from a loop'));
    });

    test('enforces source and target ports and loop portal wait geometry', () {
      final missingSourcePort = _simpleGraph();
      missingSourcePort['edges'] = [
        {
          ..._portalEdge('edge', 'idle', 'hover', 1),
          'start': {'type': 'portal', 'sourcePort': 'missing', 'targetPort': 'handoff', 'maxWaitFrames': 1},
        },
      ];
      _expectInvalid(missingSourcePort, RegExp('source port .* does not exist'));

      final missingTargetPort = _simpleGraph();
      missingTargetPort['edges'] = [
        {
          ..._cutEdge('edge', 'idle', 'hover'),
          'start': {'type': 'cut', 'targetPort': 'missing', 'maxWaitFrames': 1},
        },
      ];
      _expectInvalid(missingTargetPort, RegExp('target port .* does not exist'));

      final loopGeometry = _simpleGraph();
      final loopStates = loopGeometry['states']! as List;
      loopStates[0] = _withPortalFrames(loopStates[0]! as Map<String, Object?>, const [0, 2]);
      loopGeometry['edges'] = [_portalEdge('edge', 'idle', 'hover', 0)];
      _expectInvalid(loopGeometry, RegExp('geometric minimum 1'));

      final loopValid = _simpleGraph();
      final loopValidStates = loopValid['states']! as List;
      loopValidStates[0] = _withPortalFrames(loopValidStates[0]! as Map<String, Object?>, const [0, 2]);
      loopValid['edges'] = [_portalEdge('edge', 'idle', 'hover', 1)];
      expect(() => validateMotionGraphDefinition(loopValid), returnsNormally);
    });

    test('computes loop portal geometry correctly at very large frame counts', () {
      final graph = _simpleGraph();
      final states = graph['states']! as List;
      final state0 = Map<String, Object?>.from(states[0]! as Map);
      state0['body'] = {
        ...(state0['body']! as Map<String, Object?>),
        'frameCount': 9007199254740991,
        'ports': [
          {'id': 'handoff', 'entryFrame': 0, 'portalFrames': [2]},
        ],
      };
      states[0] = state0;
      graph['edges'] = [_portalEdge('idle-to-hover', 'idle', 'hover', 9007199254740991 - 2)];
      _expectInvalid(graph, RegExp('below the geometric minimum 9007199254740990'));
    });

    test('enforces finite portal and finish geometry without wrapping', () {
      final missingHeldPortal = _simpleGraph('finite');
      final s1 = missingHeldPortal['states']! as List;
      s1[0] = _withPortalFrames(s1[0]! as Map<String, Object?>, const [0, 2]);
      missingHeldPortal['edges'] = [_portalEdge('edge', 'idle', 'hover', 1)];
      _expectInvalid(missingHeldPortal, RegExp('must include the held final frame'));

      final finiteWait = _simpleGraph('finite');
      final s2 = finiteWait['states']! as List;
      s2[0] = _withPortalFrames(s2[0]! as Map<String, Object?>, const [2, 3]);
      finiteWait['edges'] = [_portalEdge('edge', 'idle', 'hover', 1)];
      _expectInvalid(finiteWait, RegExp('geometric minimum 2'));

      final finishLoop = _simpleGraph();
      finishLoop['edges'] = [_finishEdge('edge', 'idle', 'hover', 3)];
      _expectInvalid(finishLoop, RegExp('finish cannot originate from a loop'));

      final finishWait = _simpleGraph('finite');
      finishWait['edges'] = [_finishEdge('edge', 'idle', 'hover', 2)];
      _expectInvalid(finishWait, RegExp('finish minimum 3'));

      final held = _simpleGraph('held');
      held['edges'] = [_finishEdge('edge', 'idle', 'hover', 0)];
      expect(() => validateMotionGraphDefinition(held), returnsNormally);
    });

    test('enforces cut and continuity invariants', () {
      final cutBridge = _simpleGraph();
      cutBridge['edges'] = [
        {
          ..._cutEdge('edge', 'idle', 'hover'),
          'transition': {'kind': 'locked', 'unitId': 'bridge', 'frameCount': 2},
        },
      ];
      _expectInvalid(cutBridge, RegExp('cut cannot own a transition unit'));

      final wrongCutContinuity = _simpleGraph();
      wrongCutContinuity['edges'] = [
        {..._cutEdge('edge', 'idle', 'hover'), 'continuity': 'exact-authored'},
      ];
      _expectInvalid(wrongCutContinuity, RegExp('must declare continuity cut'));

      final cutContinuityOnPortal = _simpleGraph();
      cutContinuityOnPortal['edges'] = [
        {..._portalEdge('edge', 'idle', 'hover', 3), 'continuity': 'cut'},
      ];
      _expectInvalid(cutContinuityOnPortal, RegExp('requires start policy cut'));

      final wrongCutWait = _simpleGraph();
      wrongCutWait['edges'] = [
        {
          'id': 'edge',
          'from': 'idle',
          'to': 'hover',
          'start': {'type': 'cut', 'targetPort': 'handoff', 'maxWaitFrames': 2},
          'continuity': 'cut',
        },
      ];
      _expectInvalid(wrongCutWait, RegExp('must be 1 for a cut'));
    });

    test('validates complete reversible pairs', () {
      final unpaired = _reversibleGraph();
      (unpaired['edges']! as List).removeLast();
      _expectInvalid(unpaired, RegExp('must be used by exactly two inverse edges'));

      final sameDirection = _reversibleGraph();
      final edgesA = sameDirection['edges']! as List;
      edgesA[1] = _replaceReversible(edgesA[1]! as Map<String, Object?>,
          direction: 'forward', reverseOf: 'idle-to-hover');
      _expectInvalid(sameDirection, RegExp('must use opposite directions'));

      final wrongEndpoints = _threeStateGraph();
      final baseEdges = (_reversibleGraph()['edges']! as List).cast<Map<String, Object?>>();
      wrongEndpoints['edges'] = [
        for (var i = 0; i < baseEdges.length; i += 1)
          i == 1 ? {...baseEdges[i], 'from': 'error'} : baseEdges[i],
      ];
      _expectInvalid(wrongEndpoints, RegExp('must reverse its endpoints'));

      final wrongCount = _reversibleGraph();
      final edgesB = wrongCount['edges']! as List;
      edgesB[1] = _replaceReversible(edgesB[1]! as Map<String, Object?>,
          frameCount: 4, direction: 'reverse', reverseOf: 'idle-to-hover');
      _expectInvalid(wrongCount, RegExp('must use one frame count'));

      final noDeclaration = _reversibleGraph();
      final edgesC = noDeclaration['edges']! as List;
      edgesC[1] = {
        ..._replaceReversible(edgesC[1]! as Map<String, Object?>, direction: 'reverse'),
        'continuity': 'exact-authored',
      };
      _expectInvalid(noDeclaration, RegExp('exactly one inverse edge with reverseOf'));

      final twoDeclarations = _reversibleGraph();
      final edgesD = twoDeclarations['edges']! as List;
      edgesD[0] = _replaceReversible(edgesD[0]! as Map<String, Object?>,
          direction: 'forward', reverseOf: 'hover-to-idle');
      _expectInvalid(twoDeclarations, RegExp('exactly one inverse edge with reverseOf'));

      final wrongReference = _reversibleGraph();
      final edgesE = wrongReference['edges']! as List;
      edgesE[1] = _replaceReversible(edgesE[1]! as Map<String, Object?>,
          direction: 'reverse', reverseOf: 'hover-to-idle');
      _expectInvalid(wrongReference, RegExp('must reference "idle-to-hover"'));

      final wrongContinuity = _reversibleGraph();
      final edgesF = wrongContinuity['edges']! as List;
      edgesF[1] = {...(edgesF[1]! as Map<String, Object?>), 'continuity': 'exact-authored'};
      _expectInvalid(wrongContinuity, RegExp('must declare continuity exact-reverse'));

      final formerlyTooLong = _reversibleGraph();
      final edgesG = formerlyTooLong['edges']! as List;
      edgesG[0] = _replaceReversible(edgesG[0]! as Map<String, Object?>, frameCount: 25, direction: 'forward');
      edgesG[1] = _replaceReversible(edgesG[1]! as Map<String, Object?>,
          frameCount: 25, direction: 'reverse', reverseOf: 'idle-to-hover');
      expect(() => validateMotionGraphDefinition(formerlyTooLong), returnsNormally);
    });

    test('prevents illegal animation-unit aliases', () {
      final bodyCollision = _reversibleGraph();
      final edgesA = bodyCollision['edges']! as List;
      edgesA[0] = _replaceReversible(edgesA[0]! as Map<String, Object?>, unitId: 'idle-body', direction: 'forward');
      _expectInvalid(bodyCollision, RegExp('already used by a body or initial unit'));

      final lockedCollision = _threeStateGraph();
      lockedCollision['edges'] = [
        _lockedEdge('first', 'idle', 'hover', 'shared'),
        _lockedEdge('second', 'hover', 'error', 'shared'),
      ];
      _expectInvalid(lockedCollision, RegExp('already used by another transition'));

      final mixedCollision = _threeStateGraph();
      mixedCollision['edges'] = [
        _lockedEdge('locked', 'idle', 'error', 'shared'),
        _reversibleEdge('forward', 'idle', 'hover', 'forward', 'shared'),
        _reversibleEdge('reverse', 'hover', 'idle', 'reverse', 'shared', reverseOf: 'forward'),
      ];
      _expectInvalid(mixedCollision, RegExp('already used by a locked transition'));
    });

    test('rejects immediate transitionless completion cycles between held states', () {
      final graph = _simpleGraph('held');
      final states = graph['states']! as List;
      states[1] = _state('hover', 'held');
      graph['edges'] = [
        _completionFinishEdge('idle-complete', 'idle', 'hover', 0),
        _completionFinishEdge('hover-complete', 'hover', 'idle', 0),
      ];
      _expectInvalid(graph, RegExp('immediate cycle'));
    });

    test('rejects immediate completion cycles between one-frame finite states', () {
      final graph = _simpleGraph('finite');
      graph['states'] = [
        for (final id in ['idle', 'hover'])
          {
            ..._state(id, 'finite'),
            'body': {
              ...(_state(id, 'finite')['body']! as Map<String, Object?>),
              'frameCount': 1,
              'ports': [
                {'id': 'handoff', 'entryFrame': 0, 'portalFrames': [0]},
              ],
            },
          },
      ];
      graph['edges'] = [
        _completionFinishEdge('idle-complete', 'idle', 'hover', 0),
        _completionFinishEdge('hover-complete', 'hover', 'idle', 0),
      ];
      _expectInvalid(graph, RegExp('immediate cycle'));
    });

    test('indexes one valid completion edge per finite source', () {
      final graph = _simpleGraph('finite');
      graph['edges'] = [_completionFinishEdge('idle-complete', 'idle', 'hover', 3)];
      final validated = validateMotionGraphDefinition(graph);
      expect(getValidatedGraphIndexes(validated).completionEdgesByState['idle']!.id, 'idle-complete');
    });
  });
}

Map<String, Object?> _simpleGraph([String initialKind = 'loop']) {
  return {
    'initialState': 'idle',
    'states': [_state('idle', initialKind), _state('hover', 'loop')],
    'edges': <Object?>[],
  };
}

Map<String, Object?> _threeStateGraph([String initialKind = 'loop']) {
  final graph = _simpleGraph(initialKind);
  (graph['states']! as List).add(_state('error', 'held'));
  return graph;
}

Map<String, Object?> _reversibleGraph() {
  final graph = _simpleGraph();
  graph['edges'] = [
    {
      ..._portalEdge('idle-to-hover', 'idle', 'hover', 1),
      'trigger': {'type': 'event', 'name': 'hover.enter'},
      'transition': {
        'kind': 'reversible',
        'unitId': 'hover-clip',
        'frameCount': 3,
        'direction': 'forward',
      },
    },
    {
      ..._portalEdge('hover-to-idle', 'hover', 'idle', 1),
      'trigger': {'type': 'event', 'name': 'hover.leave'},
      'transition': {
        'kind': 'reversible',
        'unitId': 'hover-clip',
        'frameCount': 3,
        'direction': 'reverse',
        'reverseOf': 'idle-to-hover',
      },
      'continuity': 'exact-reverse',
    },
  ];
  return graph;
}

Map<String, Object?> _state(String id, String kind) {
  final frameCount = kind == 'held' ? 1 : 4;
  final List<int> portalFrames;
  if (kind == 'loop') {
    portalFrames = const [0, 2];
  } else if (kind == 'finite') {
    portalFrames = [0, frameCount - 1];
  } else {
    portalFrames = const [0];
  }
  return {
    'id': id,
    'body': {
      'unitId': '$id-body',
      'kind': kind,
      'frameCount': frameCount,
      'ports': [
        {'id': 'handoff', 'entryFrame': 0, 'portalFrames': portalFrames},
      ],
    },
  };
}

Map<String, Object?> _port() => {'id': 'handoff', 'entryFrame': 0, 'portalFrames': const [0]};

Map<String, Object?> _withPortalFrames(Map<String, Object?> state, List<int> portalFrames) {
  final body = Map<String, Object?>.from(state['body']! as Map);
  final ports = List<Object?>.from(body['ports']! as List);
  final port = Map<String, Object?>.from(ports[0]! as Map);
  port['portalFrames'] = portalFrames;
  ports[0] = port;
  body['ports'] = ports;
  return {...state, 'body': body};
}

Map<String, Object?> _portalEdge(String id, String from, String to, int maxWaitFrames) {
  return {
    'id': id,
    'from': from,
    'to': to,
    'start': {
      'type': 'portal',
      'sourcePort': 'handoff',
      'targetPort': 'handoff',
      'maxWaitFrames': maxWaitFrames,
    },
    'continuity': 'exact-authored',
  };
}

Map<String, Object?> _finishEdge(String id, String from, String to, int maxWaitFrames) {
  return {
    'id': id,
    'from': from,
    'to': to,
    'start': {'type': 'finish', 'targetPort': 'handoff', 'maxWaitFrames': maxWaitFrames},
    'continuity': 'exact-authored',
  };
}

Map<String, Object?> _cutEdge(String id, String from, String to) {
  return {
    'id': id,
    'from': from,
    'to': to,
    'start': {'type': 'cut', 'targetPort': 'handoff', 'maxWaitFrames': 1},
    'continuity': 'cut',
  };
}

Map<String, Object?> _eventCutEdge(String id, String from, String to, String name) {
  return {
    ..._cutEdge(id, from, to),
    'trigger': {'type': 'event', 'name': name},
  };
}

Map<String, Object?> _completionFinishEdge(String id, String from, String to, int maxWaitFrames) {
  return {
    ..._finishEdge(id, from, to, maxWaitFrames),
    'trigger': {'type': 'completion'},
  };
}

Map<String, Object?> _lockedEdge(String id, String from, String to, String unitId) {
  return {
    ..._portalEdge(id, from, to, 1),
    'transition': {'kind': 'locked', 'unitId': unitId, 'frameCount': 2},
  };
}

Map<String, Object?> _reversibleEdge(
  String id,
  String from,
  String to,
  String direction,
  String unitId, {
  String? reverseOf,
}) {
  final transition = <String, Object?>{
    'kind': 'reversible',
    'unitId': unitId,
    'frameCount': 3,
    'direction': direction,
  };
  if (reverseOf != null) transition['reverseOf'] = reverseOf;
  return {
    ..._portalEdge(id, from, to, 1),
    'transition': transition,
    'continuity': reverseOf == null ? 'exact-authored' : 'exact-reverse',
  };
}

Map<String, Object?> _replaceReversible(
  Map<String, Object?> edge, {
  String? unitId,
  int? frameCount,
  required String direction,
  String? reverseOf,
}) {
  final current = edge['transition']! as Map;
  final transition = <String, Object?>{
    'kind': 'reversible',
    'unitId': unitId ?? current['unitId'],
    'frameCount': frameCount ?? current['frameCount'],
    'direction': direction,
  };
  if (reverseOf != null) transition['reverseOf'] = reverseOf;
  return {...edge, 'transition': transition};
}

void _expectInvalid(Map<String, Object?> graph, Pattern message) {
  expect(
    () => validateMotionGraphDefinition(graph),
    throwsA(isA<MotionGraphValidationError>().having((e) => e.message, 'message', matches(message))),
  );
}

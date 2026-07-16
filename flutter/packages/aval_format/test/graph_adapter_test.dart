// Dart port of packages/format/test/graph-adapter.test.ts.
//
// `GraphStateDefinition`/`GraphEdgeDefinition`/etc. in aval_graph do not
// override `==`, so this port asserts field-by-field rather than one deep
// `toEqual`, and drops the `Object.isFrozen`-style checks (no Dart
// equivalent; aval_graph's `List.unmodifiable` copies play the same
// "cannot be caller-mutated" role structurally).
import 'package:aval_format/src/errors.dart';
import 'package:aval_format/src/graph_adapter.dart';
import 'package:aval_format/src/manifest_schema.dart';
import 'package:aval_graph/aval_graph.dart';
import 'package:test/test.dart';

import 'manifest_fixture.dart';

void main() {
  group('adaptManifestToMotionGraph', () {
    test('maps the complete manifest graph to the hand-written M3 golden', () {
      final graph = adaptManifestToMotionGraph(validateCompiledManifestV01(validManifest()));
      final definition = graph.definition;

      expect(definition.initialState, 'a-a');
      expect(definition.states.map((s) => s.id).toList(), ['a-a', 'a-b', 'a-c']);

      final stateA = definition.states[0];
      expect(stateA.body.unitId, 'body-a');
      expect(stateA.body.kind, GraphBodyKind.loop);
      expect(stateA.body.frameCount, 4);
      expect(stateA.body.ports[0].id, 'default');
      expect(stateA.body.ports[0].portalFrames, [0, 2]);
      expect(stateA.initialUnit?.unitId, 'intro-a');
      expect(stateA.initialUnit?.frameCount, 2);

      final stateB = definition.states[1];
      expect(stateB.body.kind, GraphBodyKind.finite);
      expect(stateB.body.frameCount, 3);
      expect(stateB.body.ports[0].portalFrames, [2]);
      expect(stateB.initialUnit, isNull);

      final stateC = definition.states[2];
      expect(stateC.body.kind, GraphBodyKind.held);
      expect(stateC.body.frameCount, 1);
      expect(stateC.body.ports[0].portalFrames, [0]);

      expect(definition.edges.map((e) => e.id).toList(), [
        'edge-ab',
        'edge-ac',
        'edge-ba',
        'edge-bc',
        'edge-cb',
      ]);

      final edgeAb = definition.edges[0];
      expect(edgeAb.from, 'a-a');
      expect(edgeAb.to, 'a-b');
      expect((edgeAb.trigger as GraphEdgeTriggerEvent).name, 'go-b');
      final startAb = edgeAb.start as GraphStartPolicyPortal;
      expect(startAb.sourcePort, 'default');
      expect(startAb.targetPort, 'default');
      expect(startAb.maxWaitFrames, 1);
      final transitionAb = edgeAb.transition as GraphTransitionLocked;
      expect(transitionAb.unitId, 'bridge-ab');
      expect(transitionAb.frameCount, 2);
      expect(edgeAb.continuity, GraphContinuity.exactAuthored);

      final edgeAc = definition.edges[1];
      expect(edgeAc.start, isA<GraphStartPolicyCut>());
      expect(edgeAc.continuity, GraphContinuity.cut);
      expect(edgeAc.transition, isNull);

      final edgeBa = definition.edges[2];
      expect(edgeBa.trigger, isA<GraphEdgeTriggerCompletion>());
      expect(edgeBa.start, isA<GraphStartPolicyFinish>());

      final edgeBc = definition.edges[3];
      final transitionBc = edgeBc.transition as GraphTransitionReversible;
      expect(transitionBc.unitId, 'rev-bc');
      expect(transitionBc.frameCount, 6);
      expect(transitionBc.direction, TransitionDirection.forward);
      expect(transitionBc.reverseOf, isNull);
      expect(edgeBc.continuity, GraphContinuity.exactAuthored);

      final edgeCb = definition.edges[4];
      final transitionCb = edgeCb.transition as GraphTransitionReversible;
      expect(transitionCb.direction, TransitionDirection.reverse);
      expect(transitionCb.reverseOf, 'edge-bc');
      expect(edgeCb.continuity, GraphContinuity.exactReverse);
    });

    test('returns a graph detached from the manifest', () {
      final manifest = validateCompiledManifestV01(validManifest());
      final graph = adaptManifestToMotionGraph(manifest);

      expect(graph.definition.states, isNot(same(manifest.states)));
    });

    test('wraps M3 geometry and ambiguity failures as GRAPH_INVALID', () {
      final manifest = validManifest();
      final edges = (manifest['edges'] as List).cast<Map<String, Object?>>();
      final edge0 = Map<String, Object?>.from(edges[0]);
      final start = Map<String, Object?>.from(edge0['start'] as Map);
      start['maxWaitFrames'] = 0;
      edge0['start'] = start;
      final newEdges = [edge0, ...edges.skip(1)];
      final mutated = Map<String, Object?>.from(manifest)..['edges'] = newEdges;

      final schemaValid = validateCompiledManifestV01(mutated);
      expect(
        () => adaptManifestToMotionGraph(schemaValid),
        throwsA(predicate((e) => e is FormatError && e.code == FormatErrorCode.graphInvalid)),
      );
    });
  });
}

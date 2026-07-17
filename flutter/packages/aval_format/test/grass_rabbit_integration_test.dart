// Format-1.0 integration checkpoint: prove the ported Dart parser produces,
// for the real `examples/grass-rabbit/public/grass-rabbit/h264.avl` asset, the
// exact structure authored in `motion.json`, and that the resulting graph
// installs into `aval_graph`'s `MotionGraphEngine`.
//
// Unlike the other tests in this directory, which build synthetic fixtures,
// this one reads the shipped example asset end-to-end. The `.avl` lives outside
// the package (in `examples/`), so the asset is located by walking up from the
// current directory to the repo root — which works whether the suite is
// launched with `dart test` or `flutter test` from the package directory (the
// documented run convention).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aval_format/aval_format.dart';
import 'package:aval_graph/aval_graph.dart';
import 'package:test/test.dart';

/// Resolves a path relative to the repository root by walking up from
/// [Directory.current] until the grass-rabbit 1.0 asset is found.
Directory _repoRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 12; i += 1) {
    final marker =
        File('${dir.path}/examples/grass-rabbit/public/grass-rabbit/h264.avl');
    if (marker.existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'could not locate the aval repository root '
    '(examples/grass-rabbit/public/grass-rabbit/h264.avl) '
    'from ${Directory.current.path}',
  );
}

File _repoFile(String relative) => File('${_repoRoot().path}/$relative');

void main() {
  group('grass-rabbit h264.avl end-to-end parse vs. motion.json source', () {
    late Uint8List assetBytes;
    late Map<String, Object?> motionJson;
    late ParsedFrontIndex frontIndex;

    setUpAll(() {
      assetBytes = _repoFile('examples/grass-rabbit/public/grass-rabbit/h264.avl')
          .readAsBytesSync();
      motionJson = jsonDecode(
        _repoFile('examples/grass-rabbit/motion.json').readAsStringSync(),
      ) as Map<String, Object?>;
      frontIndex = parseFrontIndex(assetBytes);
    });

    test('parses the format-1.0 header consistently with the real asset', () {
      final header = frontIndex.header;
      // Fixed version-1.0 container invariants.
      expect(header.major, 1);
      expect(header.minor, 0);
      expect(header.headerLength, 64);
      expect(header.requiredFeatureFlags, 0);
      expect(header.manifestOffset, 64);
      // Declared file length matches the actual asset bytes.
      expect(header.declaredFileLength, assetBytes.length);
      expect(header.declaredFileLength, 450174);
      // Layout: header + manifest + index + aligned blobs.
      expect(header.manifestLength, 3472);
      expect(header.indexOffset, 3536);
      expect(header.indexLength, 14944);
      // Index ends exactly where the first chunk payload begins.
      expect(
        header.indexOffset + header.indexLength,
        frontIndex.records.first.byteOffset,
        reason: 'first chunk payload begins immediately after the front index',
      );
    });

    test('manifest carries the format-1.0 top-level fields', () {
      final manifest = frontIndex.manifest;
      expect(manifest.formatVersion, '1.0');
      expect(manifest.codec, 'h264');
      expect(manifest.bitstream, 'annex-b');
      expect(manifest.layout, 'opaque');
      expect(manifest.initialState, 'idle');
      expect(manifest.generator, 'aval-compiler/1.0');
      expect(manifest.canvas.width, 1280);
      expect(manifest.canvas.height, 720);
      expect(manifest.canvas.fit, 'contain');
      expect(manifest.canvas.pixelAspect, const [1, 1]);
      expect(manifest.frameRate.numerator, 24);
      expect(manifest.frameRate.denominator, 1);
    });

    test('manifest counts agree with motion.json', () {
      final manifest = frontIndex.manifest;
      expect(manifest.units.length, (motionJson['units'] as List).length);
      expect(manifest.states.length, (motionJson['states'] as List).length);
      expect(manifest.edges.length, (motionJson['edges'] as List).length);
      expect(manifest.bindings.length, (motionJson['bindings'] as List).length);
      expect(manifest.units.length, 5);
      expect(manifest.states.length, 4);
      expect(manifest.edges.length, 5);
      expect(manifest.bindings.length, 2);
    });

    test('unit list: ids, kinds, playback, frame counts, and chunk spans', () {
      final units = frontIndex.manifest.units;
      // The compiler reorders units alphabetically by id in the manifest:
      // hover-in, hover-loop, hover-out, idle-loop, intro.
      expect(units.map((u) => u.id).toList(), const [
        'hover-in',
        'hover-loop',
        'hover-out',
        'idle-loop',
        'intro',
      ]);
      // Each unit has exactly one chunk span (closed-GOP per unit).
      for (final unit in units) {
        expect(unit.chunks.length, 1, reason: '${unit.id} should have one span');
        final span = unit.chunks.single;
        expect(span.rendition, 'video.1x');
        expect(span.chunkCount, unit.frameCount,
            reason: '${unit.id} chunkCount should equal frameCount');
        expect(span.frameCount, unit.frameCount,
            reason: '${unit.id} span.frameCount should equal unit.frameCount');
      }

      // Frame counts match motion.json source ranges (end - start).
      final motionUnits = {
        for (final u in (motionJson['units'] as List))
          (u as Map)['id'] as String: u,
      };
      final frameCountById = {
        'intro': 30,
        'idle-loop': 70,
        'hover-in': 67,
        'hover-loop': 96,
        'hover-out': 48,
      };
      for (final unit in units) {
        expect(unit.frameCount, frameCountById[unit.id],
            reason: '${unit.id} frame count');
        final src = motionUnits[unit.id]!;
        expect(unit.kind, src['kind']);
        if (unit is BodyUnit) {
          expect(unit.playback, src['playback']);
          expect(unit.ports.length, (src['ports'] as List).length);
        }
      }

      // Chunk spans are laid out in manifest order with a running cursor
      // (each unit's chunkStart = sum of prior units' frameCount).
      var running = 0;
      for (final unit in units) {
        expect(unit.chunks.single.chunkStart, running,
            reason: '${unit.id} chunkStart should be running cursor');
        running += unit.frameCount;
      }
      expect(running, 311, reason: 'total chunk count across all units');
    });

    test('state list matches motion.json (canonical order is alphabetical)', () {
      final states = frontIndex.manifest.states;
      expect(states.map((s) => s.id).toList(), const [
        'entering',
        'exiting',
        'hover',
        'idle',
      ]);
      final motionStates = {
        for (final s in (motionJson['states'] as List))
          (s as Map)['id'] as String: s,
      };
      for (final state in states) {
        final src = motionStates[state.id]!;
        expect(state.bodyUnit, src['bodyUnit']);
        expect(state.initialUnit, src['initialUnit']);
      }
      // idle is the initial state and bootstraps via the intro one-shot.
      final idle = states.firstWhere((s) => s.id == 'idle');
      expect(idle.initialUnit, 'intro');
      // Other states have no initialUnit.
      for (final state in states.where((s) => s.id != 'idle')) {
        expect(state.initialUnit, isNull,
            reason: '${state.id} should not declare an initialUnit');
      }
    });

    test('edge list matches motion.json topology and triggers', () {
      final edges = frontIndex.manifest.edges;
      expect(edges.length, 5);
      final motionEdgesById = {
        for (final e in (motionJson['edges'] as List))
          (e as Map)['id'] as String: e,
      };
      for (final edge in edges) {
        final src = motionEdgesById[edge.id]!;
        expect(edge.from, src['from']);
        expect(edge.to, src['to']);
        expect(edge.continuity, src['continuity']);
        final srcStart = src['start'] as Map;
        expect(edge.start.type, srcStart['type']);
      }
      // Portal edges carry event triggers; finish edges carry completion or
      // event triggers per motion.json.
      final eventNames = edges
          .map((e) => e.trigger)
          .whereType<EventTrigger>()
          .map((t) => t.name)
          .toSet();
      expect(eventNames, {'hover.enter', 'hover.leave'});
      // Edges with start.type=portal must be event-triggered; start.type=finish
      // may be event or completion.
      for (final edge in edges) {
        final trig = edge.trigger;
        if (edge.start.type == 'portal') {
          expect(trig, isA<EventTrigger>(),
              reason: '${edge.id} portal start must be event-triggered');
        }
      }
    });

    test('single rendition with AVC 1.0 geometry', () {
      final renditions = frontIndex.manifest.renditions;
      expect(renditions.length, 1);
      final rendition = renditions.single;
      expect(rendition.id, 'video.1x');
      expect(rendition.codec, 'avc1.64001E');
      expect(rendition.bitDepth, 8);
      expect(rendition.codedWidth, 640);
      expect(rendition.codedHeight, 368);
      expect(rendition.alphaLayout, isA<OpaqueAlphaLayout>());
      expect(rendition.bitrate.average, rendition.bitrate.peak,
          reason: 'CBR asset has average == peak');
      expect(rendition.bitrate.average, greaterThan(0));
    });

    test('encoded-chunk index: 311 records, contiguous within aligned blobs', () {
      final records = frontIndex.records;
      expect(records.length, 311);
      final units = frontIndex.manifest.units;

      // Walk records grouped by unit. Each unit's records live in a single
      // formatAlignment-aligned blob; within a blob they are contiguous.
      var cursor = 0;
      var previousBlobEnd =
          frontIndex.header.indexOffset + frontIndex.header.indexLength;
      for (final unit in units) {
        final span = unit.chunks.single;
        final blobStart = records[cursor].byteOffset;
        expect(blobStart % formatAlignment, 0,
            reason: '${unit.id} blob must be formatAlignment-aligned');
        expect(blobStart, greaterThanOrEqualTo(previousBlobEnd),
            reason: '${unit.id} blob must not overlap the previous');
        var expectedOffset = blobStart;
        for (var i = 0; i < span.chunkCount; i += 1) {
          final record = records[cursor];
          expect(record.byteOffset, expectedOffset,
              reason: '${unit.id} chunk $i must be contiguous within blob');
          expect(record.displayedFrameCount, 1,
              reason: '${unit.id} chunk $i covers one displayed frame');
          if (i == 0) {
            expect(record.randomAccess, isTrue,
                reason: '${unit.id} first chunk must be random access (IDR)');
          }
          expectedOffset += record.byteLength;
          cursor += 1;
        }
        previousBlobEnd = expectedOffset;
      }
      expect(cursor, records.length);
      // The final blob ends exactly at the declared file length (no trailing pad).
      expect(previousBlobEnd, frontIndex.header.declaredFileLength);
    });

    test('validateCompleteAsset accepts the real asset end-to-end', () {
      final validated = validateCompleteAsset(bytes: assetBytes);
      expect(validated.fileRange.offset, 0);
      expect(validated.fileRange.length, assetBytes.length);
      expect(validated.frontIndex.records.length, 311);
      // Supplying the already-parsed front index must agree.
      expect(
        () => validateCompleteAsset(bytes: assetBytes, frontIndex: frontIndex),
        returnsNormally,
      );
    });

    test('parsed graph installs into MotionGraphEngine with expected topology', () {
      final graph = frontIndex.graph;

      // State names in manifest (canonical alphabetical) order.
      final stateNames = graph.definition.states.map((s) => s.id).toList();
      expect(stateNames, const ['entering', 'exiting', 'hover', 'idle']);
      expect(graph.definition.initialState, 'idle');

      // Event names come from authored bindings: hover.enter / hover.leave.
      final eventNames = graph.definition.edges
          .map((e) => e.trigger)
          .whereType<GraphEdgeTriggerEvent>()
          .map((t) => t.name)
          .toSet();
      expect(eventNames, {'hover.enter', 'hover.leave'});
      final motionEvents = (motionJson['edges'] as List)
          .cast<Map<String, Object?>>()
          .map((e) => e['trigger'] as Map)
          .where((t) => t['type'] == 'event')
          .map((t) => t['name'])
          .toSet();
      expect(eventNames, motionEvents);

      // The engine installs the graph successfully and settles on the initial
      // state in the preparing phase.
      final engine = MotionGraphEngine();
      final result = engine.install(graph);
      expect(result.snapshot.readiness, MotionGraphReadiness.preparing);
      expect(result.snapshot.requestedState, 'idle');
      expect(result.snapshot.visualState, 'idle');
      expect(result.snapshot.presentation,
          const GraphPresentationStatic(state: 'idle'));
    });
  });
}

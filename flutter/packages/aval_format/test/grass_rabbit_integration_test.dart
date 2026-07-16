// Phase 1 integration checkpoint (ARCHITECTURE.md §7): prove the ported Dart
// parser produces, for the real `examples/grass-rabbit/public/grass-rabbit.avl`
// asset, exactly the structure the TypeScript build recorded in its
// `.avl.build.json` ground-truth sidecar, and that the resulting graph installs
// into `aval_graph`'s `MotionGraphEngine`.
//
// Unlike the other tests in this directory, which build synthetic fixtures, this
// one reads the shipped example asset end-to-end. The `.avl` and its
// `.build.json` live outside the package (in `examples/`), so the fixtures are
// located by walking up from the current directory to the repo root — which
// works whether the suite is launched with `dart test` or `flutter test` from
// the package directory (the documented run convention).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aval_format/aval_format.dart';
import 'package:aval_format/src/manifest_json.dart' show compiledManifestToJson;
import 'package:aval_graph/aval_graph.dart';
import 'package:test/test.dart';

/// Resolves a path expressed relative to the repository root by walking up from
/// [Directory.current] until the grass-rabbit asset is found. Returns the repo
/// root directory.
Directory _repoRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 12; i += 1) {
    final marker =
        File('${dir.path}/examples/grass-rabbit/public/grass-rabbit.avl');
    if (marker.existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'could not locate the aval repository root (examples/grass-rabbit/public/'
    'grass-rabbit.avl) from ${Directory.current.path}',
  );
}

File _repoFile(String relative) => File('${_repoRoot().path}/$relative');

/// Structural deep-equality over the plain JSON tree shapes produced by both
/// `compiledManifestToJson` (Map/List/scalars) and `jsonDecode`.
bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Returns a copy of a manifest-JSON map with every unit's sample spans reduced
/// to the `{rendition, sha256}` shape that `build.json` records — the TS build's
/// manifest sidecar omits the wire-only `sampleStart`/`sampleCount` fields.
Map<String, Object?> _reduceSamplesToBuildJsonShape(Map<String, Object?> manifest) {
  final copy = Map<String, Object?>.from(manifest);
  final units = (manifest['units'] as List).cast<Map<String, Object?>>();
  copy['units'] = units.map((unit) {
    final unitCopy = Map<String, Object?>.from(unit);
    final samples = (unit['samples'] as List).cast<Map<String, Object?>>();
    unitCopy['samples'] = samples
        .map((sample) => <String, Object?>{
              'rendition': sample['rendition'],
              'sha256': sample['sha256'],
            })
        .toList();
    return unitCopy;
  }).toList();
  return copy;
}

void main() {
  group('grass-rabbit end-to-end parse vs. TS build.json ground truth', () {
    late Uint8List assetBytes;
    late Map<String, Object?> buildJson;
    late Map<String, Object?> motionJson;
    late ParsedFrontIndex frontIndex;

    setUpAll(() {
      assetBytes = _repoFile('examples/grass-rabbit/public/grass-rabbit.avl')
          .readAsBytesSync();
      buildJson = jsonDecode(
        _repoFile('examples/grass-rabbit/public/grass-rabbit.avl.build.json')
            .readAsStringSync(),
      ) as Map<String, Object?>;
      motionJson = jsonDecode(
        _repoFile('examples/grass-rabbit/motion.json').readAsStringSync(),
      ) as Map<String, Object?>;
      frontIndex = parseFrontIndex(assetBytes);
    });

    Map<String, Object?> buildManifest() =>
        (buildJson['buildDetails'] as Map)['manifest'] as Map<String, Object?>;
    Map<String, Object?> buildAsset() =>
        buildJson['asset'] as Map<String, Object?>;
    Map<String, Object?> buildDetails() =>
        buildJson['buildDetails'] as Map<String, Object?>;

    test('parses the real asset header consistently with build.json', () {
      final header = frontIndex.header;
      // Fixed version-0.1 container invariants.
      expect(header.major, 0);
      expect(header.minor, 1);
      expect(header.headerLength, 64);
      expect(header.requiredFeatureFlags, 0);
      expect(header.manifestOffset, 64);
      // Declared file length is the ground truth's total byte count.
      expect(header.declaredFileLength, buildAsset()['bytes']);
      expect(header.declaredFileLength, assetBytes.length);
      // Layout is internally consistent: manifest -> index -> payload blobs.
      expect(
        header.indexOffset,
        greaterThanOrEqualTo(header.manifestOffset + header.manifestLength),
      );
      expect(
        header.indexOffset + header.indexLength,
        frontIndex.records.first.payloadOffset,
        reason: 'first access-unit blob begins immediately after the front index',
      );
    });

    test('parsed manifest matches every field build.json records', () {
      final parsedJson = compiledManifestToJson(frontIndex.manifest);
      final reduced = _reduceSamplesToBuildJsonShape(parsedJson);
      // Whole-manifest deep-equal: units (ids, frame counts, kinds, playback,
      // ports/portalFrames, sample digests), states, edges (triggers, starts,
      // continuity), rendition list + geometry, canvas, frameRate, limits,
      // readiness, bindings, initialState, generator, formatVersion.
      expect(
        _deepEquals(reduced, buildManifest()),
        isTrue,
        reason: 'reduced Dart manifest must equal build.json buildDetails.manifest',
      );
    });

    test('unit list: names, kinds, playback, and frame counts match build.json', () {
      final buildUnits = (buildManifest()['units'] as List).cast<Map<String, Object?>>();
      final parsedUnits = frontIndex.manifest.units;
      expect(parsedUnits.length, buildUnits.length);
      expect(parsedUnits.length, 5, reason: 'grass-rabbit has 5 units');

      // Sample spans use a global cursor: each unit's sampleStart is the running
      // total of all prior units' frame counts, and sampleCount == frameCount.
      var runningSampleStart = 0;
      for (var i = 0; i < parsedUnits.length; i += 1) {
        final parsed = parsedUnits[i];
        final expected = buildUnits[i];
        expect(parsed.id, expected['id']);
        expect(parsed.kind, expected['kind']);
        expect(parsed.frameCount, expected['frameCount']);
        // Compiled manifest carries exactly one full-span sample per unit.
        expect(parsed.samples.length, 1);
        expect(parsed.samples.single.sampleStart, runningSampleStart);
        expect(parsed.samples.single.sampleCount, parsed.frameCount);
        runningSampleStart += parsed.frameCount;
        final expectedSample = (expected['samples'] as List).first as Map;
        expect(parsed.samples.single.rendition, expectedSample['rendition']);
        expect(parsed.samples.single.sha256, expectedSample['sha256']);
        if (parsed is BodyUnitV01) {
          expect(parsed.playback, expected['playback']);
        }
      }
    });

    test('state list matches build.json', () {
      final buildStates = (buildManifest()['states'] as List).cast<Map<String, Object?>>();
      final parsedStates = frontIndex.manifest.states;
      expect(parsedStates.length, buildStates.length);
      expect(parsedStates.length, 4, reason: 'grass-rabbit has 4 states');
      for (var i = 0; i < parsedStates.length; i += 1) {
        expect(parsedStates[i].id, buildStates[i]['id']);
        expect(parsedStates[i].bodyUnit, buildStates[i]['bodyUnit']);
        expect(parsedStates[i].initialUnit, buildStates[i]['initialUnit']);
      }
    });

    test('edge list matches build.json', () {
      final buildEdges = (buildManifest()['edges'] as List).cast<Map<String, Object?>>();
      final parsedEdges = frontIndex.manifest.edges;
      expect(parsedEdges.length, buildEdges.length);
      expect(parsedEdges.length, 5, reason: 'grass-rabbit has 5 edges');
      for (var i = 0; i < parsedEdges.length; i += 1) {
        final parsed = parsedEdges[i];
        final expected = buildEdges[i];
        expect(parsed.id, expected['id']);
        expect(parsed.from, expected['from']);
        expect(parsed.to, expected['to']);
        expect(parsed.continuity, expected['continuity']);
        final expectedStart = expected['start'] as Map;
        expect(parsed.start.type, expectedStart['type']);
        expect(parsed.start.targetPort, expectedStart['targetPort']);
        expect(parsed.start.maxWaitFrames, expectedStart['maxWaitFrames']);
        final expectedTrigger = expected['trigger'] as Map?;
        if (expectedTrigger == null) {
          expect(parsed.trigger, isNull);
        } else if (parsed.trigger is EventTriggerV01) {
          expect(expectedTrigger['type'], 'event');
          expect((parsed.trigger as EventTriggerV01).name, expectedTrigger['name']);
        } else {
          expect(expectedTrigger['type'], 'completion');
        }
      }
    });

    test('rendition list and geometry match build.json', () {
      final parsed = frontIndex.manifest.renditions;
      final buildRenditions = (buildManifest()['renditions'] as List).cast<Map<String, Object?>>();
      expect(parsed.length, buildRenditions.length);
      expect(parsed.length, 1);

      final rendition = parsed.single as AvcOpaqueRenditionV01;
      final expected = buildRenditions.single;
      expect(rendition.id, expected['id']);
      expect(rendition.profile, expected['profile']);
      expect(rendition.codec, expected['codec']);
      expect(rendition.codedWidth, expected['codedWidth']);
      expect(rendition.codedHeight, expected['codedHeight']);
      final expectedAlpha = expected['alphaLayout'] as Map;
      expect(rendition.colorRect.toList(), expectedAlpha['colorRect']);
      final expectedBitrate = expected['bitrate'] as Map;
      expect(rendition.bitrate.average, expectedBitrate['average']);
      expect(rendition.bitrate.peak, expectedBitrate['peak']);

      // Cross-check against the compiler-derived geometry block.
      final geometry = (buildDetails()['renditions'] as List)
          .cast<Map<String, Object?>>()
          .single['geometry'] as Map;
      expect(rendition.codedWidth, geometry['codedWidth']);
      expect(rendition.codedHeight, geometry['codedHeight']);
      expect(rendition.profile, geometry['profile']);
      expect(rendition.colorRect.toList(), geometry['visibleColorRect']);
    });

    test('access-unit index counts and offsets match build.json', () {
      final records = frontIndex.records;
      // Total access-unit count.
      expect(records.length, buildDetails()['accessUnits']);
      expect(records.length, 311);
      final buildRendition =
          (buildDetails()['renditions'] as List).cast<Map<String, Object?>>().single;
      expect(records.length, buildRendition['accessUnits']);

      // Encoded payload byte total matches the ground truth.
      final totalPayload = records.fold<int>(0, (sum, r) => sum + r.payloadLength);
      expect(totalPayload, buildDetails()['encodedPayloadBytes']);

      // Per-unit record counts equal each unit's frame count; records are
      // grouped and ordered by unit then contiguous frame index; the first
      // record of each unit carries the structural key bit; access units are
      // contiguous within a unit blob, and unit blobs are placed at
      // `formatAlignment`-aligned offsets (padding may sit between blobs).
      final units = frontIndex.manifest.units;
      var cursor = 0;
      var previousBlobEnd = records.first.payloadOffset;
      for (var unitIndex = 0; unitIndex < units.length; unitIndex += 1) {
        final unit = units[unitIndex];
        final blobStart = records[cursor].payloadOffset;
        expect(
          blobStart,
          greaterThanOrEqualTo(previousBlobEnd),
          reason: 'unit blobs are laid out in order',
        );
        expect(blobStart % formatAlignment, 0, reason: 'unit blobs are aligned');
        var expectedOffset = blobStart;
        for (var frame = 0; frame < unit.frameCount; frame += 1) {
          final record = records[cursor];
          expect(record.unitIndex, unitIndex);
          expect(record.renditionIndex, 0);
          expect(record.frameIndex, frame);
          if (frame == 0) {
            expect(record.key, isTrue, reason: 'first frame of a unit is a key access unit');
          }
          expect(
            record.payloadOffset,
            expectedOffset,
            reason: 'access units are contiguous within a unit blob',
          );
          expectedOffset += record.payloadLength;
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
      expect(validated.fileRange.length, buildAsset()['bytes']);
      expect(validated.frontIndex.records.length, 311);
      // The independently reparsed front index should match the supplied one.
      expect(
        () => validateCompleteAsset(bytes: assetBytes, frontIndex: frontIndex),
        returnsNormally,
      );
    });

    test('parsed graph installs into MotionGraphEngine with expected states/events', () {
      // The graph produced by the format-side adapter feeds aval_graph directly.
      final graph = frontIndex.graph;

      // Counts agree with motion.json (the authored source) and the architecture
      // doc: 5 units, 4 states, 5 edges.
      expect((motionJson['units'] as List).length, 5);
      expect((motionJson['states'] as List).length, 4);
      expect((motionJson['edges'] as List).length, 5);
      expect(frontIndex.manifest.units.length, 5);
      expect(graph.definition.states.length, 4);
      expect(graph.definition.edges.length, 5);

      // State names, in manifest (canonical) order.
      final stateNames = graph.definition.states.map((s) => s.id).toList();
      expect(stateNames, ['entering', 'exiting', 'hover', 'idle']);
      expect(graph.definition.initialState, 'idle');

      // Event names come from the authored bindings/edges: hover.enter / leave.
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
      expect(result.snapshot.presentation, const GraphPresentationStatic(state: 'idle'));
    });
  });
}

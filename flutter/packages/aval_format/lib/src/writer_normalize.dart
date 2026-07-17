/// Clones, canonicalizes, and validates writer metadata without copying
/// payload bytes.
///
/// Dart port of `packages/format/src/writer-normalize.ts`. Unlike the TS source
/// (which receives fully `unknown` JSON), this port's public entry point takes
/// the strongly-typed `CanonicalAssetInput` from `model.dart`. It first
/// serializes that typed tree into the same untyped `Map<String, Object?>`
/// shape the TS normalizer works with, then reuses the identical
/// canonicalization/validation pipeline before handing off to
/// `validateCompiledManifest`.
library;

import 'dart:typed_data';

import 'checked_integer.dart' show checkedAdd;
import 'constants.dart' show resolveFormatBudgets;
import 'errors.dart';
import 'graph_adapter.dart' show adaptManifestToMotionGraph;
import 'manifest_schema.dart' show validateCompiledManifest;
import 'manifest_validation.dart';
import 'model.dart';

const List<String> _bindingSources = [
  'activate',
  'engagement.off',
  'engagement.on',
  'focus.in',
  'focus.out',
  'hidden',
  'pointer.enter',
  'pointer.leave',
  'visible',
];
const List<String> _unitKinds = ['body', 'bridge', 'reversible', 'one-shot'];
const List<String> _manifestInputKeys = [
  'formatVersion',
  'generator',
  'codec',
  'bitstream',
  'layout',
  'canvas',
  'frameRate',
  'renditions',
  'units',
  'initialState',
  'states',
  'edges',
  'bindings',
  'readiness',
  'limits',
];

class NormalizedWriterInput {
  const NormalizedWriterInput({required this.manifest, required this.chunks});

  final CompiledManifest manifest;
  final List<EncodedChunkInput> chunks;
}

class _NormalizedUnitBase {
  const _NormalizedUnitBase({
    required this.value,
    required this.id,
    required this.frameCount,
    required this.digests,
  });

  final Map<String, Object?> value;
  final String id;
  final int frameCount;
  final Map<String, String> digests;
}

/// Clones, canonicalizes, and validates writer metadata without copying
/// payloads.
NormalizedWriterInput normalizeWriterInput(CanonicalAssetInput input,
    [FormatOptions? options]) {
  try {
    final budgets = resolveFormatBudgets(options);
    final root = <String, Object?>{
      'manifest': _manifestInputToMap(input.manifest),
      'chunks': input.chunks.map(_chunkInputToMap).toList(),
    };
    exactKeys(root, ['manifest', 'chunks'], 'writer input');
    final sourceManifest = record(root['manifest'], 'manifest input');
    exactKeys(sourceManifest, _manifestInputKeys, 'manifest input');
    final sourceRenditions = _boundedInputObjectArray(
        sourceManifest['renditions'], 'manifest.renditions', budgets.maxRenditions, 1);
    final renditionIds = _authoredRenditionIds(sourceRenditions);
    final sourceUnits = _sortById(
        _boundedInputObjectArray(sourceManifest['units'], 'manifest.units', budgets.maxUnits, 1),
        'units');
    final unitBases = <_NormalizedUnitBase>[
      for (var unitIndex = 0; unitIndex < sourceUnits.length; unitIndex += 1)
        _normalizeUnitBase(sourceUnits[unitIndex], unitIndex, renditionIds, budgets),
    ];
    final blobCount = unitBases.length * renditionIds.length;
    if (blobCount > budgets.maxBlobRanges) {
      _budget('blob range count');
    }

    final suppliedChunks = _normalizeChunkInputs(
      _boundedInputObjectArray(root['chunks'], 'chunks', budgets.maxChunkRecords, 1),
      budgets.maxChunkBytes,
    );
    final groups = _groupChunks(suppliedChunks);
    final unitSpans =
        List<List<Map<String, Object?>>>.generate(unitBases.length, (_) => <Map<String, Object?>>[]);
    final orderedChunks = <EncodedChunkInput>[];
    var chunkStart = 0;
    for (final rendition in renditionIds) {
      for (var unitIndex = 0; unitIndex < unitBases.length; unitIndex += 1) {
        final unit = unitBases[unitIndex];
        final key = _chunkGroupKey(rendition, unit.id);
        final group = groups[key];
        if (group == null || group.isEmpty) {
          _invalid('missing encoded chunks for $rendition/${unit.id}');
        }
        groups.remove(key);
        group.sort((left, right) => left.decodeIndex - right.decodeIndex);
        var displayedFrames = 0;
        for (var index = 0; index < group.length; index += 1) {
          final chunk = group[index];
          if (chunk.decodeIndex != index) {
            _invalid('$rendition/${unit.id} decode indexes must be contiguous from zero');
          }
          if (index == 0 && !chunk.randomAccess) {
            _invalid('$rendition/${unit.id} must begin with a random-access chunk');
          }
          displayedFrames = checkedAdd(
            displayedFrames,
            chunk.displayedFrameCount,
            budgets.maxTotalUnitFrames,
            'unit displayed frame count',
          );
          orderedChunks.add(chunk);
        }
        if (displayedFrames != unit.frameCount) {
          _invalid('$rendition/${unit.id} must display exactly ${unit.frameCount} frames');
        }
        final sha256 = unit.digests[rendition];
        if (sha256 == null) _invalid('${unit.id} is missing digest for $rendition');
        unitSpans[unitIndex].add(<String, Object?>{
          'rendition': rendition,
          'chunkStart': chunkStart,
          'chunkCount': group.length,
          'frameCount': unit.frameCount,
          'sha256': sha256,
        });
        chunkStart =
            checkedAdd(chunkStart, group.length, budgets.maxChunkRecords, 'chunk span end');
      }
    }
    if (groups.isNotEmpty) _invalid('chunks contain an unknown rendition or unit');
    if (orderedChunks.length != suppliedChunks.length) {
      _invalid('chunks contain duplicate identities');
    }

    final sourceStates = _boundedInputObjectArray(
        sourceManifest['states'], 'manifest.states', budgets.maxStates, 1);
    final sourceEdges =
        _boundedInputObjectArray(sourceManifest['edges'], 'manifest.edges', budgets.maxEdges);
    final sourceBindings = _boundedInputObjectArray(
        sourceManifest['bindings'], 'manifest.bindings', budgets.maxBindings);
    final units = <Map<String, Object?>>[
      for (var index = 0; index < unitBases.length; index += 1)
        {...unitBases[index].value, 'chunks': unitSpans[index]},
    ];
    final manifestCandidate = <String, Object?>{
      ...sourceManifest,
      'renditions': sourceRenditions,
      'units': units,
      'states': _sortById(sourceStates, 'states'),
      'edges': _sortById(sourceEdges, 'edges'),
      'bindings': _normalizeBindings(sourceBindings),
      'readiness': _normalizeReadiness(sourceManifest['readiness'], budgets),
    };
    final manifest = validateCompiledManifest(manifestCandidate, options);
    adaptManifestToMotionGraph(manifest);
    return NormalizedWriterInput(manifest: manifest, chunks: orderedChunks);
  } on FormatError catch (error) {
    if (error.code == FormatErrorCode.budgetExceeded ||
        error.code == FormatErrorCode.integerUnsafe) {
      rethrow;
    }
    throw FormatError(
      FormatErrorCode.writerInvalid,
      error.message,
      FormatErrorDetails(path: error.path, offset: error.offset),
    );
  } catch (_) {
    throw FormatError(
        FormatErrorCode.writerInvalid, 'writer input could not be normalized');
  }
}

// --- Typed CompiledManifestInput -> untyped Map serialization -------------

Map<String, Object?> _manifestInputToMap(CompiledManifestInput manifest) => {
      'formatVersion': manifest.formatVersion,
      'generator': manifest.generator,
      'codec': manifest.codec,
      'bitstream': manifest.bitstream,
      'layout': manifest.layout,
      'canvas': _canvasToMap(manifest.canvas),
      'frameRate': _rationalToMap(manifest.frameRate),
      'renditions': manifest.renditions.map(_renditionToMap).toList(),
      'units': manifest.units.map(_unitInputToMap).toList(),
      'initialState': manifest.initialState,
      'states': manifest.states.map(_stateToMap).toList(),
      'edges': manifest.edges.map(_edgeToMap).toList(),
      'bindings': manifest.bindings.map(_bindingToMap).toList(),
      'readiness': _readinessToMap(manifest.readiness),
      'limits': _limitsToMap(manifest.limits),
    };

Map<String, Object?> _canvasToMap(Canvas canvas) => {
      'width': canvas.width,
      'height': canvas.height,
      'fit': canvas.fit,
      'pixelAspect': canvas.pixelAspect,
      'colorSpace': canvas.colorSpace,
    };

Map<String, Object?> _rationalToMap(Rational rational) =>
    {'numerator': rational.numerator, 'denominator': rational.denominator};

Map<String, Object?> _alphaLayoutToMap(AlphaLayout alphaLayout) {
  if (alphaLayout is StackedAlphaLayout) {
    return {
      'type': 'stacked',
      'colorRect': alphaLayout.colorRect.toList(),
      'alphaRect': alphaLayout.alphaRect.toList(),
    };
  }
  return {'type': 'opaque', 'colorRect': alphaLayout.colorRect.toList()};
}

Map<String, Object?> _renditionToMap(ProductionRendition rendition) => {
      'id': rendition.id,
      'codec': rendition.codec,
      'bitDepth': rendition.bitDepth,
      'codedWidth': rendition.codedWidth,
      'codedHeight': rendition.codedHeight,
      'alphaLayout': _alphaLayoutToMap(rendition.alphaLayout),
      'bitrate': {'average': rendition.bitrate.average, 'peak': rendition.bitrate.peak},
    };

Map<String, Object?> _chunkDigestToMap(ChunkDigestInput chunk) =>
    {'rendition': chunk.rendition, 'sha256': chunk.sha256};

Map<String, Object?> _portToMap(Port port) =>
    {'id': port.id, 'entryFrame': port.entryFrame, 'portalFrames': port.portalFrames};

Map<String, Object?> _residencyEndpointToMap(ResidencyEndpoint endpoint) =>
    {'state': endpoint.state, 'port': endpoint.port, 'frames': endpoint.frames};

Map<String, Object?> _unitInputToMap(UnitInput unit) {
  final base = <String, Object?>{
    'id': unit.id,
    'kind': unit.kind,
    'frameCount': unit.frameCount,
    'chunks': unit.chunks.map(_chunkDigestToMap).toList(),
  };
  if (unit is BodyUnitInput) {
    return {
      ...base,
      'playback': unit.playback,
      'ports': unit.ports.map(_portToMap).toList(),
    };
  }
  if (unit is ReversibleUnitInput) {
    return {
      ...base,
      'residency': {
        'endpoints': unit.residency.endpoints.map(_residencyEndpointToMap).toList(),
      },
    };
  }
  return base;
}

Map<String, Object?> _stateToMap(State state) {
  final base = <String, Object?>{'id': state.id, 'bodyUnit': state.bodyUnit};
  return state.initialUnit == null ? base : {...base, 'initialUnit': state.initialUnit};
}

Map<String, Object?> _startToMap(Start start) {
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

Map<String, Object?> _triggerToMap(Trigger trigger) {
  if (trigger is EventTrigger) {
    return {'type': 'event', 'name': trigger.name};
  }
  return {'type': 'completion'};
}

Map<String, Object?> _transitionToMap(Transition transition) {
  if (transition is LockedTransition) {
    return {'kind': 'locked', 'unit': transition.unit};
  }
  final reversible = transition as ReversibleTransition;
  final base = <String, Object?>{
    'kind': 'reversible',
    'unit': reversible.unit,
    'direction': reversible.direction,
  };
  return reversible.reverseOf == null ? base : {...base, 'reverseOf': reversible.reverseOf};
}

Map<String, Object?> _edgeToMap(Edge edge) {
  final base = <String, Object?>{
    'id': edge.id,
    'from': edge.from,
    'to': edge.to,
    'start': _startToMap(edge.start),
    'continuity': edge.continuity,
  };
  if (edge.trigger != null) {
    base['trigger'] = _triggerToMap(edge.trigger!);
  }
  if (edge is CutEdge) {
    base['targetRunwayFrames'] = edge.targetRunwayFrames;
  } else if (edge is NonCutEdge && edge.transition != null) {
    base['transition'] = _transitionToMap(edge.transition!);
  }
  return base;
}

Map<String, Object?> _bindingToMap(Binding binding) =>
    {'source': binding.source, 'event': binding.event};

Map<String, Object?> _readinessToMap(Readiness readiness) => {
      'policy': readiness.policy,
      'bootstrapUnits': readiness.bootstrapUnits,
      'immediateEdges': readiness.immediateEdges,
    };

Map<String, Object?> _limitsToMap(DeclaredLimits limits) => {
      'maxCompiledBytes': limits.maxCompiledBytes,
      'maxRuntimeBytes': limits.maxRuntimeBytes,
      'decodedPixelBytes': limits.decodedPixelBytes,
      'persistentCacheBytes': limits.persistentCacheBytes,
      'runtimeWorkingSetBytes': limits.runtimeWorkingSetBytes,
    };

Map<String, Object?> _chunkInputToMap(EncodedChunkInput chunk) => {
      'rendition': chunk.rendition,
      'unit': chunk.unit,
      'decodeIndex': chunk.decodeIndex,
      'presentationTimestamp': chunk.presentationTimestamp,
      'duration': chunk.duration,
      'randomAccess': chunk.randomAccess,
      'displayedFrameCount': chunk.displayedFrameCount,
      'bytes': chunk.bytes,
    };

// --- Untyped canonicalization pipeline (mirrors writer-normalize.ts) -------

_NormalizedUnitBase _normalizeUnitBase(
  Map<String, Object?> value,
  int unitIndex,
  List<String> renditionIds,
  FormatBudgets budgets,
) {
  final path = 'units[$unitIndex]';
  final kind = oneOf(value['kind'], _unitKinds, '$path.kind');
  if (kind == 'body') {
    exactKeys(value, ['id', 'kind', 'playback', 'frameCount', 'ports', 'chunks'], path);
  } else if (kind == 'reversible') {
    exactKeys(value, ['id', 'kind', 'frameCount', 'residency', 'chunks'], path);
  } else {
    exactKeys(value, ['id', 'kind', 'frameCount', 'chunks'], path);
  }
  final id = identifier(value['id'], '$path.id');
  final frameCount = positiveInteger(value['frameCount'], '$path.frameCount');
  final digests = _normalizeDigests(value['chunks'], renditionIds, '$path.chunks');

  final rest = <String, Object?>{...value}..remove('chunks');
  if (kind == 'body') {
    final sortedPorts = _sortById(
      _boundedInputObjectArray(value['ports'], '$path.ports', budgets.maxPortsPerBody),
      '$path.ports',
    );
    final ports = <Map<String, Object?>>[];
    for (var index = 0; index < sortedPorts.length; index += 1) {
      final port = sortedPorts[index];
      final portPath = '$path.ports[$index]';
      exactKeys(port, ['id', 'entryFrame', 'portalFrames'], portPath);
      ports.add({
        ...port,
        'portalFrames': _numericSort(
          _boundedInputArray(port['portalFrames'], '$portPath.portalFrames', frameCount, 1),
          '$portPath.portalFrames',
        ),
      });
    }
    return _NormalizedUnitBase(
      value: {...rest, 'kind': kind, 'ports': ports},
      id: id,
      frameCount: frameCount,
      digests: digests,
    );
  }
  if (kind == 'reversible') {
    final residency = record(value['residency'], '$path.residency');
    exactKeys(residency, ['endpoints'], '$path.residency');
    final endpoints = _exactInputArray(residency['endpoints'], '$path.residency.endpoints', 2)
        .map((endpoint) => record(endpoint, '$path.residency.endpoints'))
        .toList();
    final normalizedEndpoints = <Map<String, Object?>>[];
    for (var index = 0; index < endpoints.length; index += 1) {
      final endpointPath = '$path.residency.endpoints[$index]';
      final endpoint = endpoints[index];
      exactKeys(endpoint, ['state', 'port', 'frames'], endpointPath);
      normalizedEndpoints.add({
        ...endpoint,
        'state': identifier(endpoint['state'], '$endpointPath.state'),
        'port': identifier(endpoint['port'], '$endpointPath.port'),
      });
    }
    normalizedEndpoints.sort((left, right) {
      final byState = compareAscii(left['state'] as String, right['state'] as String);
      return byState != 0 ? byState : compareAscii(left['port'] as String, right['port'] as String);
    });
    return _NormalizedUnitBase(
      value: {...rest, 'kind': kind, 'residency': {...residency, 'endpoints': normalizedEndpoints}},
      id: id,
      frameCount: frameCount,
      digests: digests,
    );
  }
  return _NormalizedUnitBase(
    value: {...rest, 'kind': kind},
    id: id,
    frameCount: frameCount,
    digests: digests,
  );
}

Map<String, String> _normalizeDigests(
    Object? value, List<String> renditionIds, String path) {
  final inputs = _exactInputArray(value, path, renditionIds.length);
  final supplied = <String, String>{};
  for (var index = 0; index < inputs.length; index += 1) {
    final input = record(inputs[index], '$path[$index]');
    exactKeys(input, ['rendition', 'sha256'], '$path[$index]');
    final rendition = identifier(input['rendition'], '$path[$index].rendition');
    if (input['sha256'] is! String) _invalid('$path[$index].sha256 must be a string');
    if (supplied.containsKey(rendition)) _invalid('$path duplicates rendition $rendition');
    supplied[rendition] = input['sha256'] as String;
  }
  for (final rendition in renditionIds) {
    if (!supplied.containsKey(rendition)) _invalid('$path is missing rendition $rendition');
  }
  if (supplied.length != renditionIds.length) {
    _invalid('$path references an unknown rendition');
  }
  return supplied;
}

List<String> _authoredRenditionIds(List<Map<String, Object?>> values) {
  final seen = <String>{};
  final ids = <String>[];
  for (var index = 0; index < values.length; index += 1) {
    final id = identifier(values[index]['id'], 'renditions[$index].id');
    if (seen.contains(id)) _invalid('renditions[$index].id duplicates $id');
    seen.add(id);
    ids.add(id);
  }
  return ids;
}

List<EncodedChunkInput> _normalizeChunkInputs(
    List<Map<String, Object?>> values, int maxBytes) {
  final result = <EncodedChunkInput>[];
  for (var index = 0; index < values.length; index += 1) {
    final path = 'chunks[$index]';
    final input = values[index];
    exactKeys(
      input,
      [
        'rendition',
        'unit',
        'decodeIndex',
        'presentationTimestamp',
        'duration',
        'randomAccess',
        'displayedFrameCount',
        'bytes',
      ],
      path,
    );
    if (input['randomAccess'] is! bool) _invalid('$path.randomAccess must be boolean');
    final bytes = input['bytes'];
    if (bytes is! Uint8List) _invalid('$path.bytes must be a Uint8Array');
    if (bytes.length < 1) _invalid('$path.bytes must not be empty');
    if (bytes.length > maxBytes) _budget('$path.bytes');
    final displayedFrameCount =
        nonNegativeInteger(input['displayedFrameCount'], '$path.displayedFrameCount');
    final duration = nonNegativeInteger(input['duration'], '$path.duration');
    if (displayedFrameCount > 0 && duration == 0) {
      _invalid('$path.duration must be positive when the chunk displays frames');
    }
    result.add(EncodedChunkInput(
      rendition: identifier(input['rendition'], '$path.rendition'),
      unit: identifier(input['unit'], '$path.unit'),
      decodeIndex: nonNegativeInteger(input['decodeIndex'], '$path.decodeIndex'),
      presentationTimestamp:
          nonNegativeInteger(input['presentationTimestamp'], '$path.presentationTimestamp'),
      duration: duration,
      randomAccess: input['randomAccess'] as bool,
      displayedFrameCount: displayedFrameCount,
      bytes: bytes,
    ));
  }
  return result;
}

Map<String, List<EncodedChunkInput>> _groupChunks(List<EncodedChunkInput> values) {
  final groups = <String, List<EncodedChunkInput>>{};
  final identities = <String>{};
  for (final chunk in values) {
    final identity = '${_chunkGroupKey(chunk.rendition, chunk.unit)} ${chunk.decodeIndex}';
    if (identities.contains(identity)) _invalid('duplicate encoded chunk $identity');
    identities.add(identity);
    final key = _chunkGroupKey(chunk.rendition, chunk.unit);
    (groups[key] ??= <EncodedChunkInput>[]).add(chunk);
  }
  return groups;
}

List<Map<String, Object?>> _normalizeBindings(List<Map<String, Object?>> values) {
  final bindings = <Map<String, Object?>>[];
  for (var index = 0; index < values.length; index += 1) {
    final value = values[index];
    final path = 'bindings[$index]';
    exactKeys(value, ['source', 'event'], path);
    bindings.add({
      ...value,
      'source': oneOf(value['source'], _bindingSources, '$path.source'),
      'event': identifier(value['event'], '$path.event'),
    });
  }
  bindings.sort((left, right) {
    final source = compareAscii(left['source'] as String, right['source'] as String);
    return source != 0 ? source : compareAscii(left['event'] as String, right['event'] as String);
  });
  return bindings;
}

Map<String, Object?> _normalizeReadiness(Object? value, FormatBudgets budgets) {
  final readiness = record(value, 'manifest.readiness');
  exactKeys(readiness, ['policy', 'bootstrapUnits', 'immediateEdges'], 'manifest.readiness');
  final bootstrapUnits = _stringArray(
    _boundedInputArray(readiness['bootstrapUnits'], 'readiness.bootstrapUnits', budgets.maxUnits),
    'readiness.bootstrapUnits',
  )..sort(compareAscii);
  final immediateEdges = _stringArray(
    _boundedInputArray(readiness['immediateEdges'], 'readiness.immediateEdges', budgets.maxEdges),
    'readiness.immediateEdges',
  )..sort(compareAscii);
  return {...readiness, 'bootstrapUnits': bootstrapUnits, 'immediateEdges': immediateEdges};
}

List<Map<String, Object?>> _sortById(List<Map<String, Object?>> values, String path) {
  final identified = values
      .map((entry) => (entry: entry, id: identifier(entry['id'], '$path.id')))
      .toList();
  identified.sort((left, right) => compareAscii(left.id, right.id));
  return identified.map((e) => e.entry).toList();
}

List<int> _numericSort(List<Object?> values, String path) {
  final numbers = <int>[
    for (var index = 0; index < values.length; index += 1)
      nonNegativeInteger(values[index], '$path[$index]'),
  ];
  numbers.sort();
  return numbers;
}

List<String> _stringArray(List<Object?> value, String path) {
  return [
    for (var index = 0; index < value.length; index += 1)
      identifier(value[index], '$path[$index]')
  ];
}

List<Object?> _requireArray(Object? value, String path) {
  if (value is! List) _invalid('$path must be an array');
  return value;
}

List<Object?> _boundedInputArray(Object? value, String path, int maximum, [int minimum = 0]) {
  final array = _requireArray(value, path);
  if (array.length > maximum) _budget('$path count');
  if (array.length < minimum) {
    _invalid('$path must contain at least $minimum entries');
  }
  return array;
}

List<Object?> _exactInputArray(Object? value, String path, int expectedLength) {
  final array = _requireArray(value, path);
  if (array.length != expectedLength) {
    _invalid('$path must contain exactly $expectedLength entries');
  }
  return array;
}

List<Map<String, Object?>> _boundedInputObjectArray(Object? value, String path, int maximum,
    [int minimum = 0]) {
  return _boundedInputArray(value, path, maximum, minimum)
      .map((entry) => record(entry, path))
      .toList();
}

String _chunkGroupKey(String rendition, String unit) => '$rendition $unit';

Never _budget(String label) {
  throw FormatError(FormatErrorCode.budgetExceeded, '$label exceeds the active budget');
}

Never _invalid(String message) {
  throw FormatError(FormatErrorCode.writerInvalid, message);
}

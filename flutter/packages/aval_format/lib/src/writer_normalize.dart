/// Clones, canonicalizes, and validates writer metadata without copying
/// payload bytes.
///
/// Dart port of `packages/format/src/writer-normalize.ts`. Unlike the TS
/// source (which receives fully `unknown` JSON and defensively validates
/// every field at runtime), this port's public entry point
/// (`CanonicalAssetInputV01.manifest`) is already the strongly-typed
/// `CompiledManifestInputV01` from `model.dart` — Dart's type system rules
/// out the "wrong shape" failure modes TS guards against. This file first
/// serializes that typed tree into the same untyped `Map<String, Object?>`
/// shape the TS normalizer works with, then reuses the identical
/// canonicalization/validation pipeline (sorting by id, recomputing
/// sampleStart/sampleCount from the canonical plan rather than trusting
/// caller-supplied values, sorting portalFrames/capabilities/bindings,
/// bounds/budget checks) before handing off to
/// `validateCompiledManifestV01`, the single composition root for the
/// final typed `CompiledManifestV01`.
library;

import 'dart:typed_data';

import 'constants.dart' show resolveFormatBudgets;
import 'errors.dart';
import 'graph_adapter.dart' show adaptManifestToMotionGraph;
import 'manifest_schema.dart' show validateCompiledManifestV01;
import 'manifest_validation.dart';
import 'model.dart';
import 'sample_plan.dart';

const List<String> _renditionProfiles = [
  'reference-rgba-v0',
  'avc-annexb-opaque-v0',
  'avc-annexb-packed-alpha-v0',
  'avc-annexb-opaque-v1',
  'avc-annexb-packed-alpha-v1',
];
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
  const NormalizedWriterInput({required this.manifest, required this.accessUnits});

  final CompiledManifestV01 manifest;
  final List<AccessUnitInputV01> accessUnits;
}

/// Clones, canonicalizes, and validates writer metadata without copying
/// payloads.
NormalizedWriterInput normalizeWriterInput(CanonicalAssetInputV01 input, [FormatOptions? options]) {
  try {
    final budgets = resolveFormatBudgets(options);
    final root = <String, Object?>{
      'manifest': _manifestInputToMap(input.manifest),
      'accessUnits': input.accessUnits.map(_accessUnitInputToMap).toList(),
    };
    exactKeys(root, ['manifest', 'accessUnits'], 'writer input');
    final sourceManifest = record(root['manifest'], 'manifest input');
    exactKeys(sourceManifest, _manifestInputKeys, 'manifest input');
    final sourceUnits =
        _boundedInputObjectArray(sourceManifest['units'], 'manifest.units', budgets.maxUnits, 1);
    final sourceRenditions = _boundedInputObjectArray(
        sourceManifest['renditions'], 'manifest.renditions', budgets.maxRenditions, 1);
    final sourceStates =
        _boundedInputObjectArray(sourceManifest['states'], 'manifest.states', budgets.maxStates, 1);
    final sourceEdges =
        _boundedInputObjectArray(sourceManifest['edges'], 'manifest.edges', budgets.maxEdges);
    final sourceBindings =
        _boundedInputObjectArray(sourceManifest['bindings'], 'manifest.bindings', budgets.maxBindings);
    final blobCount = sourceUnits.length * sourceRenditions.length;
    if (blobCount > budgets.maxBlobRanges) {
      _budget('blob range count');
    }

    final accessInputs =
        _boundedInputObjectArray(root['accessUnits'], 'accessUnits', budgets.maxSampleRecords, 1);
    final renditions = _sortById(sourceRenditions, 'renditions');
    final normalizedRenditions = _normalizeRenditions(renditions);

    final unitInputs = _sortById(sourceUnits, 'units');
    final samplePlan = createCanonicalSamplePlan(
      [
        for (var index = 0; index < normalizedRenditions.length; index += 1)
          PlanRendition(
            id: identifier(normalizedRenditions[index]['id'], 'renditions[$index].id'),
            profile: oneOf(
              normalizedRenditions[index]['profile'],
              _renditionProfiles,
              'renditions[$index].profile',
            ),
          ),
      ],
      [
        for (var index = 0; index < unitInputs.length; index += 1)
          PlanUnit(
            id: identifier(unitInputs[index]['id'], 'units[$index].id'),
            frameCount: positiveInteger(unitInputs[index]['frameCount'], 'units[$index].frameCount'),
          ),
      ],
      budgets.maxSampleRecords,
      budgets.maxTotalUnitFrames,
    );

    final units = <Map<String, Object?>>[
      for (var unitIndex = 0; unitIndex < unitInputs.length; unitIndex += 1)
        _normalizeUnit(
          unitInputs[unitIndex],
          unitIndex,
          unitIndex < samplePlan.unitSpans.length ? samplePlan.unitSpans[unitIndex] : const [],
          unitIndex < samplePlan.unitSpans.length && samplePlan.unitSpans[unitIndex].isNotEmpty
              ? samplePlan.unitSpans[unitIndex][0].sampleCount
              : 0,
          budgets,
        ),
    ];

    final manifestCandidate = <String, Object?>{
      ...sourceManifest,
      'renditions': normalizedRenditions,
      'units': units,
      'states': _sortById(sourceStates, 'states'),
      'edges': _sortById(sourceEdges, 'edges'),
      'bindings': _normalizeBindings(sourceBindings),
      'readiness': _normalizeReadiness(sourceManifest['readiness'], budgets),
    };
    final manifest = validateCompiledManifestV01(manifestCandidate, options);
    adaptManifestToMotionGraph(manifest);
    final accessUnits = _normalizeAccessUnits(accessInputs, samplePlan, budgets.maxSampleBytes);
    return NormalizedWriterInput(manifest: manifest, accessUnits: accessUnits);
  } on FormatError catch (error) {
    if (error.code == FormatErrorCode.budgetExceeded || error.code == FormatErrorCode.integerUnsafe) {
      rethrow;
    }
    throw FormatError(
      FormatErrorCode.writerInvalid,
      error.message,
      FormatErrorDetails(path: error.path, offset: error.offset),
    );
  } catch (_) {
    throw FormatError(FormatErrorCode.writerInvalid, 'writer input could not be normalized');
  }
}

// --- Typed CompiledManifestInputV01 -> untyped Map serialization ----------
// Mirrors the exact field names the TS runtime validators expect, so the
// same untyped canonicalization pipeline below can run unmodified.

Map<String, Object?> _manifestInputToMap(CompiledManifestInputV01 manifest) => {
      'formatVersion': manifest.formatVersion,
      'generator': manifest.generator,
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

Map<String, Object?> _canvasToMap(CanvasV01 canvas) => {
      'width': canvas.width,
      'height': canvas.height,
      'fit': canvas.fit,
      'pixelAspect': canvas.pixelAspect,
      'colorSpace': canvas.colorSpace,
    };

Map<String, Object?> _rationalToMap(RationalV01 rational) => {
      'numerator': rational.numerator,
      'denominator': rational.denominator,
    };

Map<String, Object?> _renditionToMap(RenditionV01 rendition) {
  final base = <String, Object?>{
    'id': rendition.id,
    'profile': rendition.profile,
    'codec': rendition.codec,
    'codedWidth': rendition.codedWidth,
    'codedHeight': rendition.codedHeight,
    'capabilities': rendition.capabilities,
  };
  if (rendition is ReferenceRgbaRenditionV01) {
    return {...base, 'alphaLayout': {'type': 'straight-rgba-v0'}};
  }
  if (rendition is AvcOpaqueRenditionV01) {
    return {
      ...base,
      'alphaLayout': {'type': 'opaque-v0', 'colorRect': rendition.colorRect.toList()},
      'bitrate': {'average': rendition.bitrate.average, 'peak': rendition.bitrate.peak},
    };
  }
  final packed = rendition as AvcPackedAlphaRenditionV01;
  return {
    ...base,
    'alphaLayout': {
      'type': 'stacked-v0',
      'colorRect': packed.colorRect.toList(),
      'alphaRect': packed.alphaRect.toList(),
    },
    'bitrate': {'average': packed.bitrate.average, 'peak': packed.bitrate.peak},
  };
}

Map<String, Object?> _sampleDigestToMap(SampleDigestInputV01 sample) =>
    {'rendition': sample.rendition, 'sha256': sample.sha256};

Map<String, Object?> _portToMap(PortV01 port) =>
    {'id': port.id, 'entryFrame': port.entryFrame, 'portalFrames': port.portalFrames};

Map<String, Object?> _residencyEndpointToMap(ResidencyEndpointV01 endpoint) =>
    {'state': endpoint.state, 'port': endpoint.port, 'frames': endpoint.frames};

Map<String, Object?> _unitInputToMap(UnitInputV01 unit) {
  final base = <String, Object?>{
    'id': unit.id,
    'kind': unit.kind,
    'frameCount': unit.frameCount,
    'samples': unit.samples.map(_sampleDigestToMap).toList(),
  };
  if (unit is BodyUnitInputV01) {
    return {
      ...base,
      'playback': unit.playback,
      'ports': unit.ports.map(_portToMap).toList(),
    };
  }
  if (unit is ReversibleUnitInputV01) {
    return {
      ...base,
      'residency': {
        'endpoints': unit.residency.endpoints.map(_residencyEndpointToMap).toList(),
      },
    };
  }
  return base;
}

Map<String, Object?> _stateToMap(StateV01 state) {
  final base = <String, Object?>{'id': state.id, 'bodyUnit': state.bodyUnit};
  return state.initialUnit == null ? base : {...base, 'initialUnit': state.initialUnit};
}

Map<String, Object?> _startToMap(StartV01 start) {
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

Map<String, Object?> _triggerToMap(TriggerV01 trigger) {
  if (trigger is EventTriggerV01) {
    return {'type': 'event', 'name': trigger.name};
  }
  return {'type': 'completion'};
}

Map<String, Object?> _transitionToMap(TransitionV01 transition) {
  if (transition is LockedTransitionV01) {
    return {'kind': 'locked', 'unit': transition.unit};
  }
  final reversible = transition as ReversibleTransitionV01;
  final base = <String, Object?>{
    'kind': 'reversible',
    'unit': reversible.unit,
    'direction': reversible.direction,
  };
  return reversible.reverseOf == null ? base : {...base, 'reverseOf': reversible.reverseOf};
}

Map<String, Object?> _edgeToMap(EdgeV01 edge) {
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
  if (edge is CutEdgeV01) {
    base['targetRunwayFrames'] = edge.targetRunwayFrames;
  } else if (edge is NonCutEdgeV01 && edge.transition != null) {
    base['transition'] = _transitionToMap(edge.transition!);
  }
  return base;
}

Map<String, Object?> _bindingToMap(BindingV01 binding) =>
    {'source': binding.source, 'event': binding.event};

Map<String, Object?> _readinessToMap(ReadinessV01 readiness) => {
      'policy': readiness.policy,
      'bootstrapUnits': readiness.bootstrapUnits,
      'immediateEdges': readiness.immediateEdges,
    };

Map<String, Object?> _limitsToMap(DeclaredLimitsV01 limits) => {
      'maxCompiledBytes': limits.maxCompiledBytes,
      'maxRuntimeBytes': limits.maxRuntimeBytes,
      'decodedPixelBytes': limits.decodedPixelBytes,
      'persistentCacheBytes': limits.persistentCacheBytes,
      'runtimeWorkingSetBytes': limits.runtimeWorkingSetBytes,
    };

Map<String, Object?> _accessUnitInputToMap(AccessUnitInputV01 accessUnit) => {
      'rendition': accessUnit.rendition,
      'unit': accessUnit.unit,
      'frameIndex': accessUnit.frameIndex,
      'key': accessUnit.key,
      'bytes': accessUnit.bytes,
    };

// --- Untyped canonicalization pipeline (mirrors writer-normalize.ts) ------

Map<String, Object?> _normalizeUnit(
  Map<String, Object?> value,
  int unitIndex,
  List<CanonicalSampleSpan> expectedSpans,
  int frameCount,
  FormatBudgets budgets,
) {
  final path = 'units[$unitIndex]';
  final kind = oneOf(value['kind'], _unitKinds, '$path.kind');
  if (kind == 'body') {
    exactKeys(value, ['id', 'kind', 'playback', 'frameCount', 'ports', 'samples'], path);
  } else if (kind == 'reversible') {
    exactKeys(value, ['id', 'kind', 'frameCount', 'residency', 'samples'], path);
  } else {
    exactKeys(value, ['id', 'kind', 'frameCount', 'samples'], path);
  }
  final sampleInputs = _exactInputArray(value['samples'], '$path.samples', expectedSpans.length);
  final samplesByRendition = <String, Map<String, Object?>>{};
  for (var index = 0; index < sampleInputs.length; index += 1) {
    final sample = record(sampleInputs[index], '$path.samples[$index]');
    exactKeys(sample, ['rendition', 'sha256'], '$path.samples[$index]');
    final rendition = identifier(sample['rendition'], '$path.samples[$index].rendition');
    if (samplesByRendition.containsKey(rendition)) {
      _invalid('$path.samples duplicates rendition $rendition');
    }
    samplesByRendition[rendition] = sample;
  }
  final samples = expectedSpans.map((expected) {
    final rendition = expected.renditionId;
    final sample = samplesByRendition[rendition];
    if (sample == null) _invalid('$path.samples is missing rendition $rendition');
    return <String, Object?>{
      ...sample,
      'sampleStart': expected.sampleStart,
      'sampleCount': expected.sampleCount,
    };
  }).toList();
  if (samplesByRendition.length != expectedSpans.length) {
    _invalid('$path.samples references an unknown rendition');
  }

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
    return {...value, 'kind': kind, 'ports': ports, 'samples': samples};
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
    return {
      ...value,
      'kind': kind,
      'residency': {...residency, 'endpoints': normalizedEndpoints},
      'samples': samples,
    };
  }
  return {...value, 'kind': kind, 'samples': samples};
}

List<Map<String, Object?>> _normalizeRenditions(List<Map<String, Object?>> renditions) {
  return renditions.map((rendition) {
    final profile = oneOf(
      rendition['profile'],
      _renditionProfiles,
      'rendition ${rendition['id']} profile',
    );
    exactKeys(
      rendition,
      profile == 'reference-rgba-v0'
          ? ['id', 'profile', 'codec', 'codedWidth', 'codedHeight', 'alphaLayout', 'capabilities']
          : ['id', 'profile', 'codec', 'codedWidth', 'codedHeight', 'alphaLayout', 'bitrate', 'capabilities'],
      'rendition ${rendition['id']}',
    );
    final capabilities = _boundedInputArray(
      rendition['capabilities'],
      'rendition ${rendition['id']} capabilities',
      2,
    ).map((value) => oneOf(value, const ['webcodecs', 'webgl2'], 'rendition ${rendition['id']} capability')).toList()
      ..sort(compareAscii);
    return {...rendition, 'profile': profile, 'capabilities': capabilities};
  }).toList();
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

List<AccessUnitInputV01> _normalizeAccessUnits(
  List<Map<String, Object?>> values,
  CanonicalSamplePlan plan,
  int maxBytes,
) {
  final supplied = <String, AccessUnitInputV01>{};
  for (var index = 0; index < values.length; index += 1) {
    final payloadRecord = values[index];
    exactKeys(payloadRecord, ['rendition', 'unit', 'frameIndex', 'key', 'bytes'], 'accessUnits[$index]');
    final rendition = identifier(payloadRecord['rendition'], 'access unit rendition');
    final unit = identifier(payloadRecord['unit'], 'access unit unit');
    final frameIndex = nonNegativeInteger(payloadRecord['frameIndex'], 'access unit frameIndex');
    if (payloadRecord['key'] is! bool) {
      _invalid('access unit key must be boolean');
    }
    final bytes = _byteArray(payloadRecord['bytes'], maxBytes, 'access unit payload');
    final key = _accessKey(rendition, unit, frameIndex);
    if (supplied.containsKey(key)) _invalid('duplicate access unit $key');
    supplied[key] = AccessUnitInputV01(
      rendition: rendition,
      unit: unit,
      frameIndex: frameIndex,
      key: payloadRecord['key'] as bool,
      bytes: bytes,
    );
  }

  final ordered = <AccessUnitInputV01>[];
  for (final slot in plan.records()) {
    final key = _accessKey(slot.renditionId, slot.unitId, slot.frameIndex);
    final payload = supplied[key];
    if (payload == null) _invalid('missing access unit $key');
    if (slot.keyRequired && !payload.key) {
      _invalid(slot.frameIndex == 0 ? '$key frame zero must be key' : '$key reference frame must be key');
    }
    ordered.add(payload);
  }
  if (ordered.length != supplied.length) _invalid('accessUnits contains an unknown payload');
  return ordered;
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
  return [for (var index = 0; index < value.length; index += 1) identifier(value[index], '$path[$index]')];
}

Uint8List _byteArray(Object? value, int maximum, String label) {
  if (value is! Uint8List) _invalid('$label must be a Uint8Array');
  if (value.isEmpty) _invalid('$label must not be empty');
  if (value.length > maximum) {
    throw FormatError(FormatErrorCode.budgetExceeded, '$label exceeds its byte budget');
  }
  return value;
}

/// Returns the raw array elements unchanged (mirrors the TS `requireArray`,
/// which does NOT assume every element is an object — callers whose array
/// holds numbers/strings, like `portalFrames` or `capabilities`, need the
/// raw values, not `Map`s).
List<Object?> _requireArray(Object? value, String path) {
  if (value is! List) _invalid('$path must be an array');
  return value;
}

List<Object?> _boundedInputArray(
  Object? value,
  String path,
  int maximum, [
  int minimum = 0,
]) {
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

/// Same bounds-checking as [_boundedInputArray], but for arrays whose
/// elements are themselves objects (units, renditions, states, edges,
/// bindings, access-unit payload descriptors, ports) — converts each
/// element through [record] explicitly, the way each individual TS call
/// site does inline.
List<Map<String, Object?>> _boundedInputObjectArray(
  Object? value,
  String path,
  int maximum, [
  int minimum = 0,
]) {
  return _boundedInputArray(value, path, maximum, minimum)
      .map((entry) => record(entry, path))
      .toList();
}

/// Mirrors the TS join character `" "` used to build a collision-free
/// composite dedup key.
String _accessKey(String rendition, String unit, int frameIndex) => '$rendition $unit $frameIndex';

Never _budget(String label) {
  throw FormatError(FormatErrorCode.budgetExceeded, '$label exceeds the active budget');
}

Never _invalid(String message) {
  throw FormatError(FormatErrorCode.writerInvalid, message);
}

/// Serializes the typed [CompiledManifestV01] tree (and its nested types)
/// into the plain `Map<String, Object?>`/`List<Object?>` shape that
/// `canonical_json.dart`'s writer understands.
///
/// This has no TS equivalent as a standalone module: in TypeScript, a
/// `CompiledManifestV01` value already *is* a plain JS object literal, so
/// `serializeCanonicalJson` can walk it directly via `Reflect.ownKeys`.
/// Here, `model.dart` uses real Dart classes (matching the porting brief's
/// "interfaces -> immutable classes" rule) rather than duck-typed maps, so
/// this file is the one bridge between the typed model and the untyped
/// canonical-JSON writer. It is used by both `writer.dart` (encoding the
/// final manifest) and `parser.dart` (re-serializing two manifests for a
/// byte-for-byte comparison), keeping the wire-key names identical to the
/// TS source's object-literal field names.
library;

import 'model.dart';

Map<String, Object?> compiledManifestToJson(CompiledManifestV01 manifest) => {
      'formatVersion': manifest.formatVersion,
      'generator': manifest.generator,
      'canvas': _canvasToJson(manifest.canvas),
      'frameRate': _rationalToJson(manifest.frameRate),
      'renditions': manifest.renditions.map(_renditionToJson).toList(),
      'units': manifest.units.map(_unitToJson).toList(),
      'initialState': manifest.initialState,
      'states': manifest.states.map(_stateToJson).toList(),
      'edges': manifest.edges.map(_edgeToJson).toList(),
      'bindings': manifest.bindings.map(_bindingToJson).toList(),
      'readiness': _readinessToJson(manifest.readiness),
      'limits': _limitsToJson(manifest.limits),
    };

Map<String, Object?> _canvasToJson(CanvasV01 canvas) => {
      'width': canvas.width,
      'height': canvas.height,
      'fit': canvas.fit,
      'pixelAspect': canvas.pixelAspect,
      'colorSpace': canvas.colorSpace,
    };

Map<String, Object?> _rationalToJson(RationalV01 rational) =>
    {'numerator': rational.numerator, 'denominator': rational.denominator};

Map<String, Object?> _renditionToJson(RenditionV01 rendition) {
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

Map<String, Object?> _sampleSpanToJson(SampleSpanV01 sample) => {
      'rendition': sample.rendition,
      'sampleStart': sample.sampleStart,
      'sampleCount': sample.sampleCount,
      'sha256': sample.sha256,
    };

Map<String, Object?> _portToJson(PortV01 port) =>
    {'id': port.id, 'entryFrame': port.entryFrame, 'portalFrames': port.portalFrames};

Map<String, Object?> _residencyEndpointToJson(ResidencyEndpointV01 endpoint) =>
    {'state': endpoint.state, 'port': endpoint.port, 'frames': endpoint.frames};

Map<String, Object?> _unitToJson(UnitV01 unit) {
  final base = <String, Object?>{
    'id': unit.id,
    'kind': unit.kind,
    'frameCount': unit.frameCount,
    'samples': unit.samples.map(_sampleSpanToJson).toList(),
  };
  if (unit is BodyUnitV01) {
    return {
      ...base,
      'playback': unit.playback,
      'ports': unit.ports.map(_portToJson).toList(),
    };
  }
  if (unit is ReversibleUnitV01) {
    return {
      ...base,
      'residency': {
        'endpoints': unit.residency.endpoints.map(_residencyEndpointToJson).toList(),
      },
    };
  }
  return base;
}

Map<String, Object?> _stateToJson(StateV01 state) {
  final base = <String, Object?>{'id': state.id, 'bodyUnit': state.bodyUnit};
  return state.initialUnit == null ? base : {...base, 'initialUnit': state.initialUnit};
}

Map<String, Object?> _startToJson(StartV01 start) {
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

Map<String, Object?> _triggerToJson(TriggerV01 trigger) {
  if (trigger is EventTriggerV01) {
    return {'type': 'event', 'name': trigger.name};
  }
  return {'type': 'completion'};
}

Map<String, Object?> _transitionToJson(TransitionV01 transition) {
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

Map<String, Object?> _edgeToJson(EdgeV01 edge) {
  final base = <String, Object?>{
    'id': edge.id,
    'from': edge.from,
    'to': edge.to,
    'start': _startToJson(edge.start),
    'continuity': edge.continuity,
  };
  if (edge.trigger != null) {
    base['trigger'] = _triggerToJson(edge.trigger!);
  }
  if (edge is CutEdgeV01) {
    base['targetRunwayFrames'] = edge.targetRunwayFrames;
  } else if (edge is NonCutEdgeV01 && edge.transition != null) {
    base['transition'] = _transitionToJson(edge.transition!);
  }
  return base;
}

Map<String, Object?> _bindingToJson(BindingV01 binding) =>
    {'source': binding.source, 'event': binding.event};

Map<String, Object?> _readinessToJson(ReadinessV01 readiness) => {
      'policy': readiness.policy,
      'bootstrapUnits': readiness.bootstrapUnits,
      'immediateEdges': readiness.immediateEdges,
    };

Map<String, Object?> _limitsToJson(DeclaredLimitsV01 limits) => {
      'maxCompiledBytes': limits.maxCompiledBytes,
      'maxRuntimeBytes': limits.maxRuntimeBytes,
      'decodedPixelBytes': limits.decodedPixelBytes,
      'persistentCacheBytes': limits.persistentCacheBytes,
      'runtimeWorkingSetBytes': limits.runtimeWorkingSetBytes,
    };

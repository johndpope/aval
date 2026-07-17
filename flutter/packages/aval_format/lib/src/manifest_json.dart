/// Serializes the typed [CompiledManifest] tree (and its nested types) into the
/// plain `Map<String, Object?>`/`List<Object?>` shape that
/// `canonical_json.dart`'s writer understands.
///
/// This has no standalone TS equivalent: in TypeScript a `CompiledManifest`
/// value already *is* a plain JS object literal, so `serializeCanonicalJson`
/// walks it directly. Here `model.dart` uses real Dart classes, so this file is
/// the bridge between the typed model and the untyped canonical-JSON writer.
/// The wire keys emitted here are IDENTICAL to those read by the
/// `manifest_*schema.dart` validators, so `parse(serialize(x))` round-trips.
library;

import 'model.dart';

Map<String, Object?> compiledManifestToJson(CompiledManifest manifest) => {
      'formatVersion': manifest.formatVersion,
      'generator': manifest.generator,
      'codec': manifest.codec,
      'bitstream': manifest.bitstream,
      'layout': manifest.layout,
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

Map<String, Object?> _canvasToJson(Canvas canvas) => {
      'width': canvas.width,
      'height': canvas.height,
      'fit': canvas.fit,
      'pixelAspect': canvas.pixelAspect,
      'colorSpace': canvas.colorSpace,
    };

Map<String, Object?> _rationalToJson(Rational rational) =>
    {'numerator': rational.numerator, 'denominator': rational.denominator};

Map<String, Object?> _alphaLayoutToJson(AlphaLayout alphaLayout) {
  if (alphaLayout is StackedAlphaLayout) {
    return {
      'type': 'stacked',
      'colorRect': alphaLayout.colorRect.toList(),
      'alphaRect': alphaLayout.alphaRect.toList(),
    };
  }
  return {'type': 'opaque', 'colorRect': alphaLayout.colorRect.toList()};
}

Map<String, Object?> _bitrateToJson(Bitrate bitrate) =>
    {'average': bitrate.average, 'peak': bitrate.peak};

Map<String, Object?> _renditionToJson(ProductionRendition rendition) => {
      'id': rendition.id,
      'codec': rendition.codec,
      'bitDepth': rendition.bitDepth,
      'codedWidth': rendition.codedWidth,
      'codedHeight': rendition.codedHeight,
      'alphaLayout': _alphaLayoutToJson(rendition.alphaLayout),
      'bitrate': _bitrateToJson(rendition.bitrate),
    };

Map<String, Object?> _chunkSpanToJson(UnitChunkSpan chunk) => {
      'rendition': chunk.rendition,
      'chunkStart': chunk.chunkStart,
      'chunkCount': chunk.chunkCount,
      'frameCount': chunk.frameCount,
      'sha256': chunk.sha256,
    };

Map<String, Object?> _portToJson(Port port) =>
    {'id': port.id, 'entryFrame': port.entryFrame, 'portalFrames': port.portalFrames};

Map<String, Object?> _residencyEndpointToJson(ResidencyEndpoint endpoint) =>
    {'state': endpoint.state, 'port': endpoint.port, 'frames': endpoint.frames};

Map<String, Object?> _unitToJson(Unit unit) {
  final base = <String, Object?>{
    'id': unit.id,
    'kind': unit.kind,
    'frameCount': unit.frameCount,
    'chunks': unit.chunks.map(_chunkSpanToJson).toList(),
  };
  if (unit is BodyUnit) {
    return {
      ...base,
      'playback': unit.playback,
      'ports': unit.ports.map(_portToJson).toList(),
    };
  }
  if (unit is ReversibleUnit) {
    return {
      ...base,
      'residency': {
        'endpoints': unit.residency.endpoints.map(_residencyEndpointToJson).toList(),
      },
    };
  }
  return base;
}

Map<String, Object?> _stateToJson(State state) {
  final base = <String, Object?>{'id': state.id, 'bodyUnit': state.bodyUnit};
  return state.initialUnit == null ? base : {...base, 'initialUnit': state.initialUnit};
}

Map<String, Object?> _startToJson(Start start) {
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

Map<String, Object?> _triggerToJson(Trigger trigger) {
  if (trigger is EventTrigger) {
    return {'type': 'event', 'name': trigger.name};
  }
  return {'type': 'completion'};
}

Map<String, Object?> _transitionToJson(Transition transition) {
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

Map<String, Object?> _edgeToJson(Edge edge) {
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
  if (edge is CutEdge) {
    base['targetRunwayFrames'] = edge.targetRunwayFrames;
  } else if (edge is NonCutEdge && edge.transition != null) {
    base['transition'] = _transitionToJson(edge.transition!);
  }
  return base;
}

Map<String, Object?> _bindingToJson(Binding binding) =>
    {'source': binding.source, 'event': binding.event};

Map<String, Object?> _readinessToJson(Readiness readiness) => {
      'policy': readiness.policy,
      'bootstrapUnits': readiness.bootstrapUnits,
      'immediateEdges': readiness.immediateEdges,
    };

Map<String, Object?> _limitsToJson(DeclaredLimits limits) => {
      'maxCompiledBytes': limits.maxCompiledBytes,
      'maxRuntimeBytes': limits.maxRuntimeBytes,
      'decodedPixelBytes': limits.decodedPixelBytes,
      'persistentCacheBytes': limits.persistentCacheBytes,
      'runtimeWorkingSetBytes': limits.runtimeWorkingSetBytes,
    };

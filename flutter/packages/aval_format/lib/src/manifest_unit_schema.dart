/// Unit (body/bridge/reversible/one-shot) schema validation.
///
/// Dart port of `packages/format/src/manifest-unit-schema.ts` (1.0). Per-unit
/// chunk spans are shape-validated here; their canonical decode-order ordinals
/// are enforced by `createCanonicalChunkPlan` (chunk_plan.dart).
library;

import 'chunk_plan.dart' show createCanonicalChunkPlan;
import 'errors.dart';
import 'manifest_constraints.dart';
import 'manifest_validation.dart';
import 'model.dart';

List<Unit> cloneUnits(
  Object? value,
  List<ProductionRendition> renditions,
  FormatBudgets budgets,
  String path,
) {
  final inputs = boundedArray(value, path, 1, budgets.maxUnits);
  final units = <Unit>[
    for (var index = 0; index < inputs.length; index += 1)
      _cloneUnit(inputs[index], renditions, budgets, '$path[$index]'),
  ];
  requireIdOrder<Unit>(units, (u) => u.id, path);
  try {
    createCanonicalChunkPlan(
      renditions,
      units,
      budgets.maxChunkRecords,
      budgets.maxTotalUnitFrames,
    );
  } on FormatError catch (error) {
    if (error.code == FormatErrorCode.budgetExceeded ||
        error.code == FormatErrorCode.integerUnsafe) {
      rethrow;
    }
    invalid(error.path ?? path, error.message);
  } catch (_) {
    invalid(path, 'canonical chunk plan could not be derived');
  }
  return units;
}

Unit _cloneUnit(
  Object? value,
  List<ProductionRendition> renditions,
  FormatBudgets budgets,
  String path,
) {
  final input = record(value, path);
  final kind = input['kind'];
  if (kind == 'body') {
    exactKeys(input, ['id', 'kind', 'playback', 'frameCount', 'ports', 'chunks'], path);
    final id = identifier(input['id'], '$path.id');
    final playback = oneOf(input['playback'], ['loop', 'finite'], '$path.playback');
    final frameCount = positiveInteger(input['frameCount'], '$path.frameCount');
    if (playback == 'loop' && frameCount < 2) {
      invalid('$path.frameCount', 'looping bodies require at least two frames');
    }
    final ports = _clonePorts(input['ports'], frameCount, budgets.maxPortsPerBody, '$path.ports');
    final chunks = _cloneChunkSpans(input['chunks'], renditions, frameCount, '$path.chunks');
    return BodyUnit(
      id: id,
      playback: playback,
      frameCount: frameCount,
      ports: ports,
      chunks: chunks,
    );
  }

  if (kind == 'bridge' || kind == 'one-shot') {
    exactKeys(input, ['id', 'kind', 'frameCount', 'chunks'], path);
    final id = identifier(input['id'], '$path.id');
    final frameCount = positiveInteger(input['frameCount'], '$path.frameCount');
    final chunks = _cloneChunkSpans(input['chunks'], renditions, frameCount, '$path.chunks');
    return kind == 'bridge'
        ? BridgeUnit(id: id, frameCount: frameCount, chunks: chunks)
        : OneShotUnit(id: id, frameCount: frameCount, chunks: chunks);
  }

  if (kind == 'reversible') {
    exactKeys(input, ['id', 'kind', 'frameCount', 'residency', 'chunks'], path);
    final id = identifier(input['id'], '$path.id');
    final frameCount =
        positiveInteger(input['frameCount'], '$path.frameCount', budgets.maxReversibleFrames);
    final residencyInput = record(input['residency'], '$path.residency');
    exactKeys(residencyInput, ['endpoints'], '$path.residency');
    final endpointsInput = tuple(residencyInput['endpoints'], 2, '$path.residency.endpoints');
    final first = _cloneResidencyEndpoint(endpointsInput[0], '$path.residency.endpoints[0]');
    final second = _cloneResidencyEndpoint(endpointsInput[1], '$path.residency.endpoints[1]');
    if (compareEndpoint(first, second) >= 0) {
      invalid('$path.residency.endpoints', 'must be distinct and sorted by state then port');
    }
    final residency = ReversibleResidency([first, second]);
    final chunks = _cloneChunkSpans(input['chunks'], renditions, frameCount, '$path.chunks');
    return ReversibleUnit(id: id, frameCount: frameCount, residency: residency, chunks: chunks);
  }

  invalid('$path.kind', 'must be body, bridge, reversible, or one-shot');
}

List<UnitChunkSpan> _cloneChunkSpans(
  Object? value,
  List<ProductionRendition> renditions,
  int unitFrameCount,
  String path,
) {
  final inputs = tuple(value, renditions.length, path);
  final spans = <UnitChunkSpan>[];
  for (var renditionIndex = 0; renditionIndex < inputs.length; renditionIndex += 1) {
    final spanPath = '$path[$renditionIndex]';
    final input = record(inputs[renditionIndex], spanPath);
    exactKeys(input, ['rendition', 'chunkStart', 'chunkCount', 'frameCount', 'sha256'], spanPath);
    final rendition = identifier(input['rendition'], '$spanPath.rendition');
    final expected = renditionIndex < renditions.length ? renditions[renditionIndex].id : null;
    if (rendition != expected) {
      invalid('$spanPath.rendition', 'must be ${quote(expected ?? "")}');
    }
    final chunkStart = nonNegativeInteger(input['chunkStart'], '$spanPath.chunkStart');
    final chunkCount = positiveInteger(input['chunkCount'], '$spanPath.chunkCount');
    final frameCount = positiveInteger(input['frameCount'], '$spanPath.frameCount');
    if (frameCount != unitFrameCount) {
      invalid('$spanPath.frameCount', 'must equal the unit frameCount');
    }
    spans.add(UnitChunkSpan(
      rendition: rendition,
      chunkStart: chunkStart,
      chunkCount: chunkCount,
      frameCount: frameCount,
      sha256: digest(input['sha256'], '$spanPath.sha256'),
    ));
  }
  return spans;
}

List<Port> _clonePorts(Object? value, int frameCount, int maximum, String path) {
  final inputs = boundedArray(value, path, 0, maximum);
  final ports = <Port>[
    for (var index = 0; index < inputs.length; index += 1)
      _clonePort(inputs[index], '$path[$index]', frameCount),
  ];
  requireIdOrder<Port>(ports, (p) => p.id, path);
  return ports;
}

Port _clonePort(Object? entry, String portPath, int frameCount) {
  final input = record(entry, portPath);
  exactKeys(input, ['id', 'entryFrame', 'portalFrames'], portPath);
  final id = identifier(input['id'], '$portPath.id');
  literal(input['entryFrame'], 0, '$portPath.entryFrame');
  final frameInputs = boundedArray(input['portalFrames'], '$portPath.portalFrames', 1, frameCount);
  final portalFrames = <int>[
    for (var frameIndex = 0; frameIndex < frameInputs.length; frameIndex += 1)
      integerInRange(
        frameInputs[frameIndex],
        '$portPath.portalFrames[$frameIndex]',
        0,
        frameCount - 1,
      ),
  ];
  requireNumberOrder(portalFrames, '$portPath.portalFrames');
  return Port(id: id, portalFrames: portalFrames);
}

ResidencyEndpoint _cloneResidencyEndpoint(Object? value, String path) {
  final input = record(value, path);
  exactKeys(input, ['state', 'port', 'frames'], path);
  return ResidencyEndpoint(
    state: identifier(input['state'], '$path.state'),
    port: identifier(input['port'], '$path.port'),
    frames: integerInRange(input['frames'], '$path.frames', minRunwayFrames, maxRunwayFrames),
  );
}

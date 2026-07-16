/// Unit (body/bridge/reversible/one-shot) schema validation.
///
/// Dart port of `packages/format/src/manifest-unit-schema.ts`.
library;

import 'errors.dart';
import 'manifest_constraints.dart';
import 'manifest_validation.dart';
import 'model.dart';
import 'sample_plan.dart';

List<UnitV01> cloneUnits(
  Object? value,
  List<RenditionV01> renditions,
  FormatBudgets budgets,
  String path,
) {
  final inputs = boundedArray(value, path, 1, budgets.maxUnits);
  final planUnits = <PlanUnit>[];
  for (var index = 0; index < inputs.length; index += 1) {
    final unitInput = record(inputs[index], '$path[$index]');
    final frameCount = positiveInteger(unitInput['frameCount'], '$path[$index].frameCount');
    planUnits.add(
      PlanUnit(id: identifier(unitInput['id'], '$path[$index].id'), frameCount: frameCount),
    );
  }
  CanonicalSamplePlan samplePlan;
  try {
    samplePlan = createCanonicalSamplePlan(
      renditions
          .map((r) => PlanRendition(id: r.id, profile: r.profile))
          .toList(),
      planUnits,
      budgets.maxSampleRecords,
      budgets.maxTotalUnitFrames,
    );
  } on FormatError catch (error) {
    invalid(path, error.message);
  } catch (_) {
    invalid(path, 'canonical sample plan could not be derived');
  }

  final units = <UnitV01>[
    for (var index = 0; index < inputs.length; index += 1)
      _cloneUnit(
        inputs[index],
        budgets,
        index < samplePlan.unitSpans.length ? samplePlan.unitSpans[index] : const [],
        '$path[$index]',
      ),
  ];
  requireIdOrder<UnitV01>(units, (u) => u.id, path);
  return units;
}

UnitV01 _cloneUnit(
  Object? value,
  FormatBudgets budgets,
  List<CanonicalSampleSpan> expectedSpans,
  String path,
) {
  final input = record(value, path);
  final kind = input['kind'];
  if (kind == 'body') {
    exactKeys(input, ['id', 'kind', 'playback', 'frameCount', 'ports', 'samples'], path);
    final id = identifier(input['id'], '$path.id');
    final playback = oneOf(input['playback'], ['loop', 'finite'], '$path.playback');
    final frameCount = positiveInteger(input['frameCount'], '$path.frameCount');
    if (playback == 'loop' && frameCount < 2) {
      invalid('$path.frameCount', 'looping bodies require at least two frames');
    }
    final ports = _clonePorts(input['ports'], frameCount, budgets.maxPortsPerBody, '$path.ports');
    final samples = _cloneSampleSpans(input['samples'], expectedSpans, frameCount, '$path.samples');
    return BodyUnitV01(id: id, frameCount: frameCount, samples: samples, playback: playback, ports: ports);
  }

  if (kind == 'bridge' || kind == 'one-shot') {
    exactKeys(input, ['id', 'kind', 'frameCount', 'samples'], path);
    final id = identifier(input['id'], '$path.id');
    final frameCount = positiveInteger(input['frameCount'], '$path.frameCount');
    final samples = _cloneSampleSpans(input['samples'], expectedSpans, frameCount, '$path.samples');
    return kind == 'bridge'
        ? BridgeUnitV01(id: id, frameCount: frameCount, samples: samples)
        : OneShotUnitV01(id: id, frameCount: frameCount, samples: samples);
  }

  if (kind == 'reversible') {
    exactKeys(input, ['id', 'kind', 'frameCount', 'residency', 'samples'], path);
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
    final residency = ReversibleResidencyV01([first, second]);
    final samples = _cloneSampleSpans(input['samples'], expectedSpans, frameCount, '$path.samples');
    return ReversibleUnitV01(id: id, frameCount: frameCount, samples: samples, residency: residency);
  }

  invalid('$path.kind', 'must be body, bridge, reversible, or one-shot');
}

List<PortV01> _clonePorts(Object? value, int frameCount, int maximum, String path) {
  final inputs = boundedArray(value, path, 0, maximum);
  final ports = <PortV01>[
    for (var index = 0; index < inputs.length; index += 1)
      _clonePort(inputs[index], '$path[$index]', frameCount),
  ];
  requireIdOrder<PortV01>(ports, (p) => p.id, path);
  return ports;
}

PortV01 _clonePort(Object? entry, String portPath, int frameCount) {
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
  return PortV01(id: id, portalFrames: portalFrames);
}

ResidencyEndpointV01 _cloneResidencyEndpoint(Object? value, String path) {
  final input = record(value, path);
  exactKeys(input, ['state', 'port', 'frames'], path);
  return ResidencyEndpointV01(
    state: identifier(input['state'], '$path.state'),
    port: identifier(input['port'], '$path.port'),
    frames: integerInRange(input['frames'], '$path.frames', minRunwayFrames, maxRunwayFrames),
  );
}

List<SampleSpanV01> _cloneSampleSpans(
  Object? value,
  List<CanonicalSampleSpan> expectedSpans,
  int frameCount,
  String path,
) {
  final inputs = tuple(value, expectedSpans.length, path);
  return <SampleSpanV01>[
    for (var renditionIndex = 0; renditionIndex < inputs.length; renditionIndex += 1)
      _cloneSampleSpan(inputs, renditionIndex, expectedSpans, frameCount, path),
  ];
}

SampleSpanV01 _cloneSampleSpan(
  List<Object?> inputs,
  int renditionIndex,
  List<CanonicalSampleSpan> expectedSpans,
  int frameCount,
  String path,
) {
  final spanPath = '$path[$renditionIndex]';
  final input = record(inputs[renditionIndex], spanPath);
  exactKeys(input, ['rendition', 'sampleStart', 'sampleCount', 'sha256'], spanPath);
  final rendition = identifier(input['rendition'], '$spanPath.rendition');
  final expected = renditionIndex < expectedSpans.length ? expectedSpans[renditionIndex] : null;
  final expectedRendition = expected?.renditionId;
  if (rendition != expectedRendition) {
    invalid('$spanPath.rendition', 'must be ${quote(expectedRendition ?? "")}');
  }
  final sampleStart = nonNegativeInteger(input['sampleStart'], '$spanPath.sampleStart');
  final sampleCount = positiveInteger(input['sampleCount'], '$spanPath.sampleCount');
  if (sampleCount != frameCount) {
    invalid('$spanPath.sampleCount', 'must equal the unit frameCount');
  }
  if (expected == null || sampleStart != expected.sampleStart) {
    invalid('$spanPath.sampleStart', 'must be ${expected?.sampleStart ?? 0}');
  }
  return SampleSpanV01(
    rendition: rendition,
    sampleStart: sampleStart,
    sampleCount: sampleCount,
    sha256: digest(input['sha256'], '$spanPath.sha256'),
  );
}

// Dart port of packages/format/test/writer-fixture.ts.
import 'dart:typed_data';

import 'package:aval_format/src/manifest_schema.dart' show validateCompiledManifestV01;
import 'package:aval_format/src/model.dart';
import 'package:aval_format/src/reference_frame.dart';

import 'manifest_fixture.dart';

/// Converts a validated compiled manifest back into writer-input shape
/// (`CompiledManifestInputV01`, whose units carry `SampleDigestInputV01`
/// instead of the fully-derived `SampleSpanV01`).
CompiledManifestInputV01 manifestInputFromCompiled(CompiledManifestV01 manifest) {
  return CompiledManifestInputV01(
    generator: manifest.generator,
    canvas: manifest.canvas,
    frameRate: manifest.frameRate,
    renditions: manifest.renditions,
    units: manifest.units.map(_unitInputFrom).toList(),
    initialState: manifest.initialState,
    states: manifest.states,
    edges: manifest.edges,
    bindings: manifest.bindings,
    readiness: manifest.readiness,
    limits: manifest.limits,
  );
}

UnitInputV01 _unitInputFrom(UnitV01 unit) {
  final samples = unit.samples
      .map((s) => SampleDigestInputV01(rendition: s.rendition, sha256: s.sha256))
      .toList();
  if (unit is BodyUnitV01) {
    return BodyUnitInputV01(
      id: unit.id,
      frameCount: unit.frameCount,
      samples: samples,
      playback: unit.playback,
      ports: unit.ports,
    );
  }
  if (unit is BridgeUnitV01) {
    return BridgeUnitInputV01(id: unit.id, frameCount: unit.frameCount, samples: samples);
  }
  if (unit is ReversibleUnitV01) {
    return ReversibleUnitInputV01(
      id: unit.id,
      frameCount: unit.frameCount,
      samples: samples,
      residency: unit.residency,
    );
  }
  final oneShot = unit as OneShotUnitV01;
  return OneShotUnitInputV01(id: oneShot.id, frameCount: oneShot.frameCount, samples: samples);
}

/// Reconstructs the typed [CompiledManifestV01] the untyped
/// `manifest_fixture.dart` builds, by round-tripping it through the real
/// schema validator (the fixture is authored as an untyped Map tree exactly
/// like the TS source's object literal, and this is the one place both
/// typed and untyped worlds need to meet for the writer fixture).
CompiledManifestV01 _validCompiledManifest() {
  return validateCompiledManifestV01(validManifest());
}

/// A fresh valid writer input with real AVRF samples.
CanonicalAssetInputV01 validWriterInput({String generatorSuffix = ''}) {
  final compiled = _validCompiledManifest();
  final baseManifest = manifestInputFromCompiled(compiled);
  final manifest = CompiledManifestInputV01(
    generator: baseManifest.generator + generatorSuffix,
    canvas: baseManifest.canvas,
    frameRate: baseManifest.frameRate,
    renditions: baseManifest.renditions,
    units: baseManifest.units,
    initialState: baseManifest.initialState,
    states: baseManifest.states,
    edges: baseManifest.edges,
    bindings: baseManifest.bindings,
    readiness: baseManifest.readiness,
    limits: baseManifest.limits,
  );

  var ordinal = 0;
  final accessUnits = <AccessUnitInputV01>[];
  for (final rendition in compiled.renditions) {
    for (final unit in compiled.units) {
      for (var frameIndex = 0; frameIndex < unit.frameCount; frameIndex += 1) {
        final fillValue = ordinal & 0xff;
        ordinal += 1;
        final bytes = encodeReferenceFrame(ReferenceFrameInput(
          width: rendition.codedWidth,
          height: rendition.codedHeight,
          frameIndex: frameIndex,
          rgba: Uint8List(rendition.codedWidth * rendition.codedHeight * 4)
            ..fillRange(0, rendition.codedWidth * rendition.codedHeight * 4, fillValue),
        ));
        accessUnits.add(AccessUnitInputV01(
          rendition: rendition.id,
          unit: unit.id,
          frameIndex: frameIndex,
          key: true,
          bytes: bytes,
        ));
      }
    }
  }
  return CanonicalAssetInputV01(manifest: manifest, accessUnits: accessUnits);
}

/// Extends the compact fixture to exercise rendition-major canonicalization.
CanonicalAssetInputV01 twoRenditionWriterInput() {
  final input = validWriterInput();
  final original = input.manifest.renditions[0] as ReferenceRgbaRenditionV01;
  final alternate = ReferenceRgbaRenditionV01(
    id: 'alternate',
    codedWidth: original.codedWidth,
    codedHeight: original.codedHeight,
  );
  final units = input.manifest.units.map((unit) {
    final firstDigest = unit.samples[0].sha256;
    final samples = [
      SampleDigestInputV01(rendition: alternate.id, sha256: firstDigest),
      ...unit.samples,
    ];
    return _withSamples(unit, samples);
  }).toList();

  final manifest = CompiledManifestInputV01(
    generator: input.manifest.generator,
    canvas: input.manifest.canvas,
    frameRate: input.manifest.frameRate,
    renditions: [alternate, original],
    units: units,
    initialState: input.manifest.initialState,
    states: input.manifest.states,
    edges: input.manifest.edges,
    bindings: input.manifest.bindings,
    readiness: input.manifest.readiness,
    limits: input.manifest.limits,
  );

  final accessUnits = <AccessUnitInputV01>[
    for (final sample in input.accessUnits)
      AccessUnitInputV01(
        rendition: alternate.id,
        unit: sample.unit,
        frameIndex: sample.frameIndex,
        key: sample.key,
        bytes: Uint8List.fromList(sample.bytes),
      ),
    ...input.accessUnits,
  ];
  return CanonicalAssetInputV01(manifest: manifest, accessUnits: accessUnits);
}

UnitInputV01 _withSamples(UnitInputV01 unit, List<SampleDigestInputV01> samples) {
  if (unit is BodyUnitInputV01) {
    return BodyUnitInputV01(
      id: unit.id,
      frameCount: unit.frameCount,
      samples: samples,
      playback: unit.playback,
      ports: unit.ports,
    );
  }
  if (unit is BridgeUnitInputV01) {
    return BridgeUnitInputV01(id: unit.id, frameCount: unit.frameCount, samples: samples);
  }
  if (unit is ReversibleUnitInputV01) {
    return ReversibleUnitInputV01(
      id: unit.id,
      frameCount: unit.frameCount,
      samples: samples,
      residency: unit.residency,
    );
  }
  final oneShot = unit as OneShotUnitInputV01;
  return OneShotUnitInputV01(id: oneShot.id, frameCount: oneShot.frameCount, samples: samples);
}

/// Rebuilds writer metadata from parsed values while reusing caller payloads.
CanonicalAssetInputV01 writerInputFromParsed(
  ParsedFrontIndex front,
  List<AccessUnitInputV01> accessUnits,
) {
  return CanonicalAssetInputV01(
    manifest: manifestInputFromCompiled(front.manifest),
    accessUnits: accessUnits,
  );
}

/// Reverses all semantically unordered input arrays without changing meaning.
CanonicalAssetInputV01 shuffledWriterInput(CanonicalAssetInputV01 input) {
  final manifest = input.manifest;
  final units = manifest.units.reversed.map((unit) {
    if (unit is BodyUnitInputV01) {
      return BodyUnitInputV01(
        id: unit.id,
        frameCount: unit.frameCount,
        samples: unit.samples.reversed.toList(),
        playback: unit.playback,
        ports: unit.ports.reversed
            .map((port) => PortV01(id: port.id, portalFrames: port.portalFrames.reversed.toList()))
            .toList(),
      );
    }
    if (unit is ReversibleUnitInputV01) {
      return ReversibleUnitInputV01(
        id: unit.id,
        frameCount: unit.frameCount,
        samples: unit.samples.reversed.toList(),
        residency: ReversibleResidencyV01(unit.residency.endpoints.reversed.toList()),
      );
    }
    return _withSamples(unit, unit.samples.reversed.toList());
  }).toList();

  final reversedManifest = CompiledManifestInputV01(
    generator: manifest.generator,
    canvas: manifest.canvas,
    frameRate: manifest.frameRate,
    renditions: manifest.renditions.reversed.toList(),
    units: units,
    initialState: manifest.initialState,
    states: manifest.states.reversed.toList(),
    edges: manifest.edges.reversed.toList(),
    bindings: manifest.bindings.reversed.toList(),
    readiness: ReadinessV01(
      bootstrapUnits: manifest.readiness.bootstrapUnits.reversed.toList(),
      immediateEdges: manifest.readiness.immediateEdges.reversed.toList(),
    ),
    limits: manifest.limits,
  );

  return CanonicalAssetInputV01(
    manifest: reversedManifest,
    accessUnits: input.accessUnits.reversed.toList(),
  );
}

bool byteIdentity(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

// Dart port of packages/format/test/writer-fixture.ts.
import 'dart:typed_data';

import 'package:aval_format/src/manifest_schema.dart' show validateCompiledManifest;
import 'package:aval_format/src/model.dart';

import 'manifest_fixture.dart';

/// Converts a validated compiled manifest back into writer-input shape
/// (`CompiledManifestInput`, whose units carry `ChunkDigestInput`
/// instead of the fully-derived `UnitChunkSpan`).
CompiledManifestInput manifestInputFromCompiled(CompiledManifest manifest) {
  return CompiledManifestInput(
    generator: manifest.generator,
    codec: manifest.codec,
    bitstream: manifest.bitstream,
    layout: manifest.layout,
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

UnitInput _unitInputFrom(Unit unit) {
  final chunks = unit.chunks
      .map((chunk) => ChunkDigestInput(rendition: chunk.rendition, sha256: chunk.sha256))
      .toList();
  if (unit is BodyUnit) {
    return BodyUnitInput(
      id: unit.id,
      frameCount: unit.frameCount,
      chunks: chunks,
      playback: unit.playback,
      ports: unit.ports,
    );
  }
  if (unit is BridgeUnit) {
    return BridgeUnitInput(id: unit.id, frameCount: unit.frameCount, chunks: chunks);
  }
  if (unit is ReversibleUnit) {
    return ReversibleUnitInput(
      id: unit.id,
      frameCount: unit.frameCount,
      chunks: chunks,
      residency: unit.residency,
    );
  }
  final oneShot = unit as OneShotUnit;
  return OneShotUnitInput(id: oneShot.id, frameCount: oneShot.frameCount, chunks: chunks);
}

/// Reconstructs the typed [CompiledManifest] the untyped
/// `manifest_fixture.dart` builds, by round-tripping it through the real
/// schema validator (the fixture is authored as an untyped Map tree exactly
/// like the TS source's object literal, and this is the one place both
/// typed and untyped worlds need to meet for the writer fixture).
CompiledManifest _validCompiledManifest() {
  return validateCompiledManifest(validManifest());
}

/// A fresh valid writer input with one encoded chunk per displayed frame.
CanonicalAssetInput validWriterInput({String generatorSuffix = ''}) {
  final compiled = _validCompiledManifest();
  final baseManifest = manifestInputFromCompiled(compiled);
  final manifest = CompiledManifestInput(
    generator: baseManifest.generator + generatorSuffix,
    codec: baseManifest.codec,
    bitstream: baseManifest.bitstream,
    layout: baseManifest.layout,
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
  final chunks = <EncodedChunkInput>[];
  for (final rendition in compiled.renditions) {
    for (final unit in compiled.units) {
      for (var decodeIndex = 0; decodeIndex < unit.frameCount; decodeIndex += 1) {
        chunks.add(EncodedChunkInput(
          rendition: rendition.id,
          unit: unit.id,
          decodeIndex: decodeIndex,
          presentationTimestamp: decodeIndex,
          duration: 1,
          randomAccess: decodeIndex == 0,
          displayedFrameCount: 1,
          bytes: Uint8List.fromList([0, 0, 1, ordinal++ & 0xff]),
        ));
      }
    }
  }
  return CanonicalAssetInput(manifest: manifest, chunks: chunks);
}

/// Extends the compact fixture to exercise authored rendition order.
CanonicalAssetInput twoRenditionWriterInput() {
  final input = validWriterInput();
  final original = input.manifest.renditions[0];
  final alternate = ProductionRendition(
    id: 'alternate',
    codec: original.codec,
    bitDepth: original.bitDepth,
    codedWidth: original.codedWidth,
    codedHeight: original.codedHeight,
    alphaLayout: original.alphaLayout,
    bitrate: const Bitrate(average: 500, peak: 1000),
  );
  final units = input.manifest.units.map((unit) {
    final firstDigest = unit.chunks[0].sha256;
    final chunks = [
      ChunkDigestInput(rendition: alternate.id, sha256: firstDigest),
      ...unit.chunks,
    ];
    return _withChunks(unit, chunks);
  }).toList();

  final manifest = CompiledManifestInput(
    generator: input.manifest.generator,
    codec: input.manifest.codec,
    bitstream: input.manifest.bitstream,
    layout: input.manifest.layout,
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

  final chunks = <EncodedChunkInput>[
    for (final chunk in input.chunks)
      EncodedChunkInput(
        rendition: alternate.id,
        unit: chunk.unit,
        decodeIndex: chunk.decodeIndex,
        presentationTimestamp: chunk.presentationTimestamp,
        duration: chunk.duration,
        randomAccess: chunk.randomAccess,
        displayedFrameCount: chunk.displayedFrameCount,
        bytes: Uint8List.fromList(chunk.bytes),
      ),
    ...input.chunks,
  ];
  return CanonicalAssetInput(manifest: manifest, chunks: chunks);
}

/// Adds bytes to the first chunk for large-offset boundary tests.
CanonicalAssetInput largeChunkWriterInput(int extraPayloadBytes) {
  if (extraPayloadBytes < 0) {
    throw ArgumentError('extra payload bytes must be nonnegative');
  }
  final input = validWriterInput();
  final maxCompiled = input.manifest.limits.maxCompiledBytes;
  final bumped = extraPayloadBytes + 1024 * 1024;
  final newMax = maxCompiled >= 32 * 1024 * 1024 && bumped <= maxCompiled
      ? maxCompiled
      : (bumped > 32 * 1024 * 1024 ? bumped : 32 * 1024 * 1024);
  return CanonicalAssetInput(
    manifest: CompiledManifestInput(
      generator: input.manifest.generator,
      codec: input.manifest.codec,
      bitstream: input.manifest.bitstream,
      layout: input.manifest.layout,
      canvas: input.manifest.canvas,
      frameRate: input.manifest.frameRate,
      renditions: input.manifest.renditions,
      units: input.manifest.units,
      initialState: input.manifest.initialState,
      states: input.manifest.states,
      edges: input.manifest.edges,
      bindings: input.manifest.bindings,
      readiness: input.manifest.readiness,
      limits: DeclaredLimits(
        maxCompiledBytes: newMax,
        maxRuntimeBytes: input.manifest.limits.maxRuntimeBytes,
        decodedPixelBytes: input.manifest.limits.decodedPixelBytes,
        persistentCacheBytes: input.manifest.limits.persistentCacheBytes,
        runtimeWorkingSetBytes: input.manifest.limits.runtimeWorkingSetBytes,
      ),
    ),
    chunks: [
      for (var ordinal = 0; ordinal < input.chunks.length; ordinal += 1)
        ordinal == 0
            ? EncodedChunkInput(
                rendition: input.chunks[ordinal].rendition,
                unit: input.chunks[ordinal].unit,
                decodeIndex: input.chunks[ordinal].decodeIndex,
                presentationTimestamp: input.chunks[ordinal].presentationTimestamp,
                duration: input.chunks[ordinal].duration,
                randomAccess: input.chunks[ordinal].randomAccess,
                displayedFrameCount: input.chunks[ordinal].displayedFrameCount,
                bytes: Uint8List(1 + extraPayloadBytes)
                  ..fillRange(0, 1 + extraPayloadBytes, ordinal & 0xff),
              )
            : input.chunks[ordinal],
    ],
  );
}

/// Rebuilds writer metadata from parsed values while reusing caller payloads.
CanonicalAssetInput writerInputFromParsed(
  ParsedFrontIndex front,
  List<EncodedChunkInput> chunks,
) {
  return CanonicalAssetInput(
    manifest: manifestInputFromCompiled(front.manifest),
    chunks: chunks,
  );
}

UnitInput _withChunks(UnitInput unit, List<ChunkDigestInput> chunks) {
  if (unit is BodyUnitInput) {
    return BodyUnitInput(
      id: unit.id,
      frameCount: unit.frameCount,
      chunks: chunks,
      playback: unit.playback,
      ports: unit.ports,
    );
  }
  if (unit is BridgeUnitInput) {
    return BridgeUnitInput(id: unit.id, frameCount: unit.frameCount, chunks: chunks);
  }
  if (unit is ReversibleUnitInput) {
    return ReversibleUnitInput(
      id: unit.id,
      frameCount: unit.frameCount,
      chunks: chunks,
      residency: unit.residency,
    );
  }
  final oneShot = unit as OneShotUnitInput;
  return OneShotUnitInput(id: oneShot.id, frameCount: oneShot.frameCount, chunks: chunks);
}

/// Reverses all semantically unordered input arrays without changing meaning.
CanonicalAssetInput shuffledWriterInput(CanonicalAssetInput input) {
  final manifest = input.manifest;
  final units = manifest.units.reversed.map((unit) {
    if (unit is BodyUnitInput) {
      return BodyUnitInput(
        id: unit.id,
        frameCount: unit.frameCount,
        chunks: unit.chunks.reversed.toList(),
        playback: unit.playback,
        ports: unit.ports.reversed
            .map((port) => Port(id: port.id, portalFrames: port.portalFrames.reversed.toList()))
            .toList(),
      );
    }
    if (unit is ReversibleUnitInput) {
      return ReversibleUnitInput(
        id: unit.id,
        frameCount: unit.frameCount,
        chunks: unit.chunks.reversed.toList(),
        residency: ReversibleResidency(unit.residency.endpoints.reversed.toList()),
      );
    }
    return _withChunks(unit, unit.chunks.reversed.toList());
  }).toList();

  final reversedManifest = CompiledManifestInput(
    generator: manifest.generator,
    codec: manifest.codec,
    bitstream: manifest.bitstream,
    layout: manifest.layout,
    canvas: manifest.canvas,
    frameRate: manifest.frameRate,
    renditions: manifest.renditions.reversed.toList(),
    units: units,
    initialState: manifest.initialState,
    states: manifest.states.reversed.toList(),
    edges: manifest.edges.reversed.toList(),
    bindings: manifest.bindings.reversed.toList(),
    readiness: Readiness(
      bootstrapUnits: manifest.readiness.bootstrapUnits.reversed.toList(),
      immediateEdges: manifest.readiness.immediateEdges.reversed.toList(),
    ),
    limits: manifest.limits,
  );

  return CanonicalAssetInput(
    manifest: reversedManifest,
    chunks: input.chunks.reversed.toList(),
  );
}

bool byteIdentity(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

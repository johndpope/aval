/// Test-only synthetic `.avl` builders.
///
/// Port of the subset of `packages/player-web/src/runtime/asset-test-fixture.ts`
/// used by the ported `worker_samples_test.dart` / `asset_catalog_test.dart`
/// suites: [createOpaqueTestAsset] plus [opaqueTestRendition] and helpers. The
/// `avc-annexb-opaque` synthetic access-unit byte constants are copied verbatim
/// from the TS fixture. The integrated / reference-only / path variants are not
/// needed by these two suites and are omitted.
library;

import 'dart:typed_data';

import 'package:aval_format/aval_format.dart';

const String _digest =
    '0000000000000000000000000000000000000000000000000000000000000000';

const List<int> _keyAccessUnit = [
  0, 0, 0, 1, 9, 16, 0, 0, 0, 1, 103, 66, 224, 32, 218, 16, 154, //
  106, 2, 2, 2, 128, 0, 0, 3, 0, 128, 0, 0, 30, 70, 208, 68, 35, 80,
  0, 0, 1, 104, 206, 50, 200, 0, 0, 1, 101, 184, 79, 192
];

const List<int> _deltaAccessUnit = [
  0, 0, 0, 1, 9, 48, 0, 0, 1, 97, 226, 63
];

/// Options for [createOpaqueTestAsset].
class OpaqueTestAssetOptions {
  const OpaqueTestAssetOptions({
    this.corruptIntroDelta = false,
    this.pixelAspect,
    this.profile,
  });

  final bool corruptIntroDelta;
  final List<int>? pixelAspect;

  /// `"avc-annexb-opaque-v0"` (default) or `"avc-annexb-opaque-v1"`.
  final String? profile;
}

AvcOpaqueRenditionV01 opaqueTestRendition({
  String id = 'opaque',
  int codedWidth = 64,
  int codedHeight = 64,
  int peakBitrate = 2000000,
  int averageBitrate = 1000000,
  String profile = 'avc-annexb-opaque-v0',
}) {
  return AvcOpaqueRenditionV01(
    id: id,
    profile: profile,
    codec: 'avc1.42E020',
    codedWidth: codedWidth,
    codedHeight: codedHeight,
    colorRect: Rect(0, 0, codedWidth, codedHeight),
    bitrate: BitrateV01(average: averageBitrate, peak: peakBitrate),
  );
}

Uint8List createOpaqueTestAsset([
  OpaqueTestAssetOptions options = const OpaqueTestAssetOptions(),
]) {
  final profile = options.profile ?? 'avc-annexb-opaque-v0';
  final rendition = opaqueTestRendition(profile: profile);
  final samples = [
    const SampleDigestInputV01(rendition: 'opaque', sha256: _digest),
  ];
  final input = CanonicalAssetInputV01(
    manifest: CompiledManifestInputV01(
      generator: 'player-web-m55-tests',
      canvas: CanvasV01(
        width: 64,
        height: 64,
        fit: 'contain',
        pixelAspect: options.pixelAspect ?? const [1, 1],
      ),
      frameRate: const RationalV01(numerator: 30, denominator: 1),
      renditions: [rendition],
      units: [
        BodyUnitInputV01(
          id: 'body',
          frameCount: 2,
          samples: samples,
          playback: 'loop',
          ports: [
            const PortV01(id: 'default', portalFrames: [0, 1]),
          ],
        ),
        OneShotUnitInputV01(id: 'intro', frameCount: 2, samples: samples),
      ],
      initialState: 'idle',
      states: const [
        StateV01(id: 'idle', bodyUnit: 'body', initialUnit: 'intro'),
      ],
      edges: const [],
      bindings: const [],
      readiness: const ReadinessV01(
        bootstrapUnits: ['body', 'intro'],
        immediateEdges: [],
      ),
      limits: const DeclaredLimitsV01(
        maxCompiledBytes: 64 * 1024,
        maxRuntimeBytes: 1024 * 1024,
        decodedPixelBytes: 64 * 64 * 4,
        persistentCacheBytes: 0,
        runtimeWorkingSetBytes: 64 * 64 * 4,
      ),
    ),
    accessUnits: [
      _accessUnit('body', 0, true, _keyAccessUnit),
      _accessUnit('body', 1, false, _deltaAccessUnit),
      _accessUnit('intro', 0, true, _keyAccessUnit),
      _accessUnit(
        'intro',
        1,
        false,
        options.corruptIntroDelta
            ? const [0, 0, 0, 1, 9, 48, 0, 0, 1, 97]
            : _deltaAccessUnit,
      ),
    ],
  );

  return writeCanonicalAsset(input);
}

AccessUnitInputV01 _accessUnit(
  String unit,
  int frameIndex,
  bool key,
  List<int> values,
) {
  return AccessUnitInputV01(
    rendition: 'opaque',
    unit: unit,
    frameIndex: frameIndex,
    key: key,
    bytes: Uint8List.fromList(values),
  );
}

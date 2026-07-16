/// Port of `packages/player-web/src/runtime/asset-catalog.test.ts` (1:1).
///
/// JS-only assertions with no Dart analog are noted inline: the TS
/// `"staticFrames" in catalog.manifest` structural check
/// (asset-catalog.test.ts:19) is dropped because [CompiledManifestV01] has no
/// such field in the statically-typed Dart port, and `toEqual`/`toMatchObject`
/// on plain objects become explicit field comparisons.
library;

import 'dart:typed_data';

import 'package:aval_player/aval_player.dart';
import 'package:test/test.dart';

import 'asset_test_fixture.dart';

void main() {
  group('runtime asset catalog', () {
    test('indexes and copies only animation unit payloads', () {
      final catalog = RuntimeAssetCatalog(createOpaqueTestAsset());

      expect(catalog.manifest.initialState, 'idle');
      final idle = catalog.states.require('idle');
      expect(idle.id, 'idle');
      expect(idle.bodyUnit, 'body');
      expect(idle.initialUnit, 'intro');

      final descriptors =
          createRuntimeCatalogBlobDescriptors(catalog.layout.frontIndex);
      expect(descriptors, hasLength(2));
      expect(descriptors.every((descriptor) => descriptor.kind == 'unit'), true);
      expect(
        Uint8List.view(catalog.copySample('opaque', 'body', 0)).length,
        greaterThan(0),
      );
      final residency = catalog.residencySnapshot().unitBlobs;
      expect(residency.total, 2);
      expect(residency.verified, 2);

      catalog.dispose();
      expect(catalog.ownedByteLength, 0);
    });

    test('retains an allowlisted AVC-v1 rendition profile', () {
      final catalog = RuntimeAssetCatalog(createOpaqueTestAsset(
        const OpaqueTestAssetOptions(profile: 'avc-annexb-opaque-v1'),
      ));

      expect(catalog.manifest.renditions[0].profile, 'avc-annexb-opaque-v1');
      catalog.dispose();
    });
  });
}

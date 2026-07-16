/// Byte-free AVC rendition inspection over borrowed catalog views.
///
/// Direct port of `packages/player-web/src/runtime/borrowed-avc-inspection.ts`.
/// The TS `RUNTIME_CATALOG_AVC_INSPECTION` `unique symbol` (a hidden method key
/// on `RuntimeAssetCatalog`) has no Dart analog; the internal inspection entry
/// point is instead the ordinary method
/// `RuntimeAssetCatalog.inspectAvcRenditionInternal` (asset_catalog.dart), and
/// [inspectRuntimeCatalogAvcRendition] calls it directly
/// (borrowed-avc-inspection.ts:37-43).
library;

import 'dart:typed_data';

import 'package:aval_format/aval_format.dart'
    show
        AvcAccessUnitInput,
        AvcConstrainedBaselineProfile,
        AvcRenditionInspection,
        AvcRenditionInspectionInput,
        AvcUnitInput,
        inspectAvcAnnexBRendition;

import 'asset_catalog.dart' show RuntimeAssetCatalog;

/// One access unit's borrow plan.
class BorrowedAvcAccessUnitPlan {
  const BorrowedAvcAccessUnitPlan({
    required this.blobKey,
    required this.relativeOffset,
    required this.byteLength,
    required this.key,
  });

  final String blobKey;
  final int relativeOffset;
  final int byteLength;
  final bool key;
}

/// One unit's ordered access-unit borrow plan.
class BorrowedAvcUnitPlan {
  const BorrowedAvcUnitPlan({required this.id, required this.accessUnits});

  final String id;
  final List<BorrowedAvcAccessUnitPlan> accessUnits;
}

/// A rendition's complete borrow plan plus its constrained-baseline profile.
class BorrowedAvcRenditionPlan {
  const BorrowedAvcRenditionPlan({required this.profile, required this.units});

  final AvcConstrainedBaselineProfile profile;
  final List<BorrowedAvcUnitPlan> units;
}

/// Synchronously borrows exactly [byteLength] bytes at [relativeOffset] within
/// the blob keyed [key]. The returned view never escapes the inspection call.
typedef BorrowVerifiedRange = Uint8List Function(
  String key,
  int relativeOffset,
  int byteLength,
);

/// Returns only a byte-free immutable inspection result.
AvcRenditionInspection inspectRuntimeCatalogAvcRendition(
  RuntimeAssetCatalog catalog,
  String rendition,
  AvcConstrainedBaselineProfile profile,
) {
  return catalog.inspectAvcRenditionInternal(rendition, profile);
}

/// The trusted format inspector consumes borrowed views synchronously and
/// returns a byte-free scalar summary. The borrow function never escapes.
AvcRenditionInspection inspectBorrowedAvcRendition(
  BorrowedAvcRenditionPlan plan,
  BorrowVerifiedRange borrow,
) {
  final units = plan.units.map((unit) {
    return AvcUnitInput(
      id: unit.id,
      accessUnits: unit.accessUnits.map((accessUnit) {
        final bytes = borrow(
          accessUnit.blobKey,
          accessUnit.relativeOffset,
          accessUnit.byteLength,
        );
        if (bytes.length != accessUnit.byteLength) {
          throw ArgumentError('borrowed AVC access unit is malformed');
        }
        return AvcAccessUnitInput(bytes: bytes, key: accessUnit.key);
      }).toList(),
    );
  }).toList();
  return inspectAvcAnnexBRendition(
    AvcRenditionInspectionInput(profile: plan.profile, units: units),
  );
}

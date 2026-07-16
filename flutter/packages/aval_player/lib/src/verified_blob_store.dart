/// Frozen contract for the sparse digest-verified blob store.
///
/// **Partial port** of `packages/player-web/src/runtime/verified-blob-store.ts`.
/// The full store (967 LOC) is fetch/SHA-256-bound (§1.2 bucket B) and belongs
/// to a later networking phase. Only the surface `asset-catalog.ts` binds
/// against — [VerifiedBlobStore]'s `state`/`copyRange`/`inspectAvcRendition`/
/// `snapshot`/`dispose` methods and the [VerifiedBlobStoreSnapshot] /
/// [VerifiedBlobDescriptor] shapes — is ported here as a frozen interface,
/// mirroring the same deferral pattern used by `worker_samples.dart`'s original
/// scaffold. The complete-owned-bytes catalog path
/// (`installRuntimeAssetCatalog`) never touches this store; only the sparse
/// `createMetadataRuntimeAssetCatalog` path does.
library;

import 'dart:typed_data';

import 'package:aval_format/aval_format.dart' show AvcRenditionInspection;

import 'borrowed_avc_inspection.dart' show BorrowedAvcRenditionPlan;
import 'model.dart'
    show RuntimeBlobResidencySnapshot, RuntimeBlobResidencyState;

/// One declared blob the store must be able to verify and copy.
class VerifiedBlobDescriptor {
  const VerifiedBlobDescriptor({
    required this.key,
    required this.kind,
    required this.byteLength,
  });

  final String key;

  /// Always `"unit"` for catalog-derived descriptors.
  final String kind;
  final int byteLength;
}

/// Immutable snapshot of the store's residency accounting.
class VerifiedBlobStoreSnapshot {
  const VerifiedBlobStoreSnapshot({
    required this.generation,
    required this.verifiedBytes,
    required this.persistentBytes,
    required this.disposed,
    required this.unitBlobs,
  });

  final int generation;
  final int verifiedBytes;
  final int persistentBytes;
  final bool disposed;
  final RuntimeBlobResidencySnapshot unitBlobs;
}

/// A sparse, digest-verified byte store keyed by unit-blob key.
abstract interface class VerifiedBlobStore {
  RuntimeBlobResidencyState state(String key);

  Uint8List copyRange(String key, int relativeOffset, int byteLength);

  AvcRenditionInspection inspectAvcRendition(BorrowedAvcRenditionPlan plan);

  VerifiedBlobStoreSnapshot snapshot();

  Future<void> dispose();
}

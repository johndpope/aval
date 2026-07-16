/// One immutable metadata catalog over owned or digest-verified bytes.
///
/// Direct port of `packages/player-web/src/runtime/asset-catalog.ts`.
///
/// Judgment calls (with TS anchors):
/// - The two `unique symbol` methods `RUNTIME_CATALOG_COMPLETE_SOURCE`
///   (asset-catalog.ts:90,190) and `RUNTIME_CATALOG_AVC_INSPECTION`
///   (asset-catalog.ts:220) have no Dart analog; they become the ordinary
///   library-visible methods [RuntimeAssetCatalog.adoptCompleteSourceInternal]
///   and [RuntimeAssetCatalog.inspectAvcRenditionInternal].
/// - TS constructor overloading (`Uint8Array | CatalogInstallation`,
///   asset-catalog.ts:128-131) becomes the public generative constructor
///   [RuntimeAssetCatalog] (owned bytes) plus the private
///   `RuntimeAssetCatalog._` (installation), which
///   [createMetadataRuntimeAssetCatalog] uses. `isCatalogInstallation` and the
///   symbol brand are therefore unnecessary and omitted; the installation and
///   payload-authority helper types are library-private (`_CatalogInstallation`,
///   `_CatalogPayloadAuthority`) since TS never exports them.
/// - `CatalogPayloadAuthority` (a frozen closure object, asset-catalog.ts:75)
///   becomes an abstract class with two concrete implementations.
/// - `copySample` returns a Dart `ByteBuffer` (the shape [DecoderWorkerSample]
///   consumes) in place of the TS `ArrayBuffer`.
library;

import 'dart:typed_data';

import 'package:aval_format/aval_format.dart'
    show
        AvcConstrainedBaselineProfile,
        AvcRenditionInspection,
        ByteRange,
        CompiledManifestV01,
        EdgeV01,
        FormatError,
        ParsedFrontIndex,
        RenditionV01,
        StateV01,
        UnitV01,
        ValidatedAssetLayout,
        formatDefaultBudgets,
        validateCompleteAsset;
import 'package:aval_graph/aval_graph.dart' show ValidatedMotionGraph;

import 'asset_catalog_index.dart'
    show
        CatalogMapBuildInput,
        CatalogMaps,
        RuntimeCatalogIdIndex,
        RuntimeCatalogPortIndex,
        RuntimeCatalogRecordIndex,
        buildCatalogMaps,
        checkedCatalogRangeEnd,
        createCatalogIdIndex,
        createCatalogPortIndex,
        createCatalogRecordIndex,
        runtimeUnitBlobKey;
import 'borrowed_avc_inspection.dart'
    show
        BorrowedAvcAccessUnitPlan,
        BorrowedAvcRenditionPlan,
        BorrowedAvcUnitPlan,
        inspectBorrowedAvcRendition;
import 'errors.dart'
    show
        RuntimeFailureCode,
        RuntimeFailureContext,
        RuntimePlaybackError,
        normalizeRuntimeFailure;
import 'model.dart'
    show
        RuntimeAssetResidencySnapshot,
        RuntimeBlobResidencySnapshot,
        RuntimeBlobResidencyState,
        RuntimeTransportMode;
import 'verified_blob_store.dart'
    show VerifiedBlobDescriptor, VerifiedBlobStore, VerifiedBlobStoreSnapshot;
import 'worker_samples.dart' show WorkerSampleCatalog;

/// Payload ownership of a catalog installation.
enum _PayloadOwnership { none, verified, persistent }

/// Input to [createMetadataRuntimeAssetCatalog].
class MetadataRuntimeAssetCatalogInput {
  const MetadataRuntimeAssetCatalogInput({
    required this.frontIndex,
    required this.declaredFileLength,
    required this.mode,
    required this.blobStore,
  });

  final ParsedFrontIndex frontIndex;
  final int declaredFileLength;
  final RuntimeTransportMode mode;
  final VerifiedBlobStore blobStore;
}

/// Byte-free residency accounting shared by both payload authorities.
class _CatalogPayloadSnapshot {
  const _CatalogPayloadSnapshot({
    required this.generation,
    required this.verifiedBytes,
    required this.persistentBytes,
    required this.unitBlobs,
  });

  final int generation;
  final int verifiedBytes;
  final int persistentBytes;
  final RuntimeBlobResidencySnapshot unitBlobs;
}

/// Backing-byte authority abstraction (owned vs. verified).
abstract class _CatalogPayloadAuthority {
  RuntimeBlobResidencyState state(String key);
  Uint8List copyRange(String key, int relativeOffset, int byteLength);
  AvcRenditionInspection inspectAvcRendition(BorrowedAvcRenditionPlan plan);
  _CatalogPayloadSnapshot snapshot();
  void dispose();
}

class _CatalogInstallation {
  const _CatalogInstallation({
    required this.frontIndex,
    required this.declaredFileLength,
    required this.mode,
    required this.metadataBytes,
    required this.baseOwnedBytes,
    required this.payloadOwnership,
    required this.payloads,
    required this.completeLayout,
  });

  final ParsedFrontIndex frontIndex;
  final int declaredFileLength;
  final RuntimeTransportMode mode;
  final int metadataBytes;
  final int baseOwnedBytes;
  final _PayloadOwnership payloadOwnership;
  final _CatalogPayloadAuthority payloads;
  final ValidatedAssetLayout? completeLayout;
}

/// One immutable metadata catalog over either completely owned bytes or sparse
/// digest-verified blob residency. Both installation paths share every lookup
/// and downstream copy method.
class RuntimeAssetCatalog implements WorkerSampleCatalog {
  RuntimeAssetCatalog(Uint8List callerBytes)
      : this._(_installOwnedBytes(callerBytes));

  RuntimeAssetCatalog._(_CatalogInstallation installed)
      : _frontIndex = installed.frontIndex,
        _layout = installed.completeLayout,
        _declaredFileLength = installed.declaredFileLength,
        _mode = installed.mode,
        _metadataBytes = installed.metadataBytes,
        _baseOwnedBytes = installed.baseOwnedBytes,
        _payloadOwnership = installed.payloadOwnership,
        _payloads = installed.payloads {
    _maps = buildCatalogMaps(CatalogMapBuildInput(
      frontIndex: installed.frontIndex,
      declaredFileLength: installed.declaredFileLength,
    ));

    renditions = createCatalogIdIndex<RenditionV01>(
      'rendition',
      () => _requireMaps().renditions,
      (rendition) => RuntimeFailureContext(rendition: rendition),
    );
    units = createCatalogIdIndex<UnitV01>(
      'unit',
      () => _requireMaps().units,
      (unit) => RuntimeFailureContext(unit: unit),
    );
    states = createCatalogIdIndex<StateV01>(
      'state',
      () => _requireMaps().states,
      (state) => RuntimeFailureContext(state: state),
    );
    edges = createCatalogIdIndex<EdgeV01>(
      'edge',
      () => _requireMaps().edges,
      (edge) => RuntimeFailureContext(edge: edge),
    );
    ports = createCatalogPortIndex(() => _requireMaps().ports);
    records = createCatalogRecordIndex(() => _requireMaps().records);
  }

  @override
  late final RuntimeCatalogIdIndex<RenditionV01> renditions;
  @override
  late final RuntimeCatalogIdIndex<UnitV01> units;
  late final RuntimeCatalogIdIndex<StateV01> states;
  late final RuntimeCatalogIdIndex<EdgeV01> edges;
  late final RuntimeCatalogPortIndex ports;
  @override
  late final RuntimeCatalogRecordIndex records;

  final int _declaredFileLength;
  RuntimeTransportMode _mode;
  final int _metadataBytes;
  int _baseOwnedBytes;
  _PayloadOwnership _payloadOwnership;
  final _CatalogPayloadAuthority _payloads;
  bool _disposed = false;
  ParsedFrontIndex? _frontIndex;
  ValidatedAssetLayout? _layout;
  CatalogMaps? _maps;

  bool get disposed => _disposed;

  /// Current retained source ownership plus verified payload copies.
  int get ownedByteLength {
    if (_disposed) return 0;
    if (_payloadOwnership == _PayloadOwnership.none) return _baseOwnedBytes;
    final payloads = _payloads.snapshot();
    return _checkedOwnedByteSum(
      _baseOwnedBytes,
      _payloadOwnership == _PayloadOwnership.verified
          ? payloads.verifiedBytes
          : payloads.persistentBytes,
    );
  }

  /// Switch sparse accounting after an entity-safe full replacement
  /// (`RUNTIME_CATALOG_COMPLETE_SOURCE`, asset-catalog.ts:190).
  void adoptCompleteSourceInternal() {
    _throwIfDisposed();
    _mode = RuntimeTransportMode.full;
    _baseOwnedBytes = _declaredFileLength;
    _payloadOwnership = _PayloadOwnership.persistent;
  }

  ValidatedAssetLayout get layout {
    _throwIfDisposed();
    final existing = _layout;
    if (existing != null) return existing;
    final frontIndex = _requireFrontIndex();
    final built = ValidatedAssetLayout(
      frontIndex: frontIndex,
      fileRange: ByteRange(offset: 0, length: _declaredFileLength),
    );
    _layout = built;
    return built;
  }

  CompiledManifestV01 get manifest => _requireFrontIndex().manifest;

  ValidatedMotionGraph get graph => _requireFrontIndex().graph;

  /// Byte-free synchronous inspection over private payload backing
  /// (`RUNTIME_CATALOG_AVC_INSPECTION`, asset-catalog.ts:220).
  AvcRenditionInspection inspectAvcRenditionInternal(
    String rendition,
    AvcConstrainedBaselineProfile profile,
  ) {
    return _inspectAvcRendition(rendition, profile);
  }

  /// A fresh exact-length buffer that the caller charges and transfers.
  @override
  ByteBuffer copySample(String rendition, String unit, int localFrame) {
    final entry = records.require(rendition, unit, localFrame);
    final blobKey = _requireCatalogBlobKey(entry.blobKey);
    final relativeRange = _requireCatalogRelativeRange(entry.relativeRange);
    _requireVerifiedBlob(
      blobKey,
      RuntimeFailureContext(
        rendition: rendition,
        unit: unit,
        localFrame: localFrame,
      ),
    );
    return _payloads
        .copyRange(blobKey, relativeRange.offset, relativeRange.length)
        .buffer;
  }

  RuntimeAssetResidencySnapshot residencySnapshot() {
    final payloads = _payloads.snapshot();
    return RuntimeAssetResidencySnapshot(
      generation: payloads.generation,
      mode: _mode,
      declaredFileBytes: _declaredFileLength,
      metadataBytes: _disposed ? 0 : _metadataBytes,
      verifiedPayloadBytes: _disposed ? 0 : payloads.verifiedBytes,
      unitBlobs: payloads.unitBlobs,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _payloads.dispose();
    _frontIndex = null;
    _layout = null;
    final maps = _maps;
    _maps = null;
    if (maps != null) {
      maps.renditions.clear();
      maps.units.clear();
      maps.states.clear();
      maps.edges.clear();
      maps.ports.clear();
      maps.records.clear();
    }
  }

  AvcRenditionInspection _inspectAvcRendition(
    String rendition,
    AvcConstrainedBaselineProfile profile,
  ) {
    _throwIfDisposed();
    final unitPlans = manifest.units.map((unit) {
      return BorrowedAvcUnitPlan(
        id: unit.id,
        accessUnits: List<BorrowedAvcAccessUnitPlan>.generate(
          unit.frameCount,
          (localFrame) {
            final entry = records.require(rendition, unit.id, localFrame);
            final blobKey = _requireCatalogBlobKey(entry.blobKey);
            final relativeRange =
                _requireCatalogRelativeRange(entry.relativeRange);
            _requireVerifiedBlob(
              blobKey,
              RuntimeFailureContext(
                rendition: rendition,
                unit: unit.id,
                localFrame: localFrame,
              ),
            );
            return BorrowedAvcAccessUnitPlan(
              blobKey: blobKey,
              relativeOffset: relativeRange.offset,
              byteLength: relativeRange.length,
              key: entry.record.key,
            );
          },
        ),
      );
    }).toList();
    return _payloads.inspectAvcRendition(
      BorrowedAvcRenditionPlan(profile: profile, units: unitPlans),
    );
  }

  void _requireVerifiedBlob(String key, RuntimeFailureContext context) {
    final state = _payloadState(key);
    if (state != RuntimeBlobResidencyState.verified) {
      throw _catalogError(
        RuntimeFailureCode.loadFailure,
        'asset catalog blob is not verified',
        RuntimeFailureContext(
          rendition: context.rendition,
          unit: context.unit,
          localFrame: context.localFrame,
          policyPhase: state.wireValue,
        ),
      );
    }
  }

  RuntimeBlobResidencyState _payloadState(String key) {
    _throwIfDisposed();
    try {
      return _payloads.state(key);
    } on RuntimePlaybackError {
      rethrow;
    } catch (_) {
      throw _catalogError(
        RuntimeFailureCode.invalidAsset,
        'asset catalog blob key is invalid',
      );
    }
  }

  ParsedFrontIndex _requireFrontIndex() {
    final frontIndex = _frontIndex;
    if (frontIndex == null) throw _disposedCatalogError();
    return frontIndex;
  }

  CatalogMaps _requireMaps() {
    final maps = _maps;
    if (maps == null) throw _disposedCatalogError();
    return maps;
  }

  void _throwIfDisposed() {
    if (_disposed) throw _disposedCatalogError();
  }
}

RuntimeAssetCatalog installRuntimeAssetCatalog(Uint8List bytes) {
  return RuntimeAssetCatalog(bytes);
}

RuntimeAssetCatalog createMetadataRuntimeAssetCatalog(
  MetadataRuntimeAssetCatalogInput input,
) {
  return RuntimeAssetCatalog._(_installMetadata(input));
}

/// Account a retained complete source exactly once.
void adoptRuntimeCatalogCompleteSource(RuntimeAssetCatalog catalog) {
  catalog.adoptCompleteSourceInternal();
}

List<VerifiedBlobDescriptor> createRuntimeCatalogBlobDescriptors(
  ParsedFrontIndex frontIndex,
) {
  final descriptors = <VerifiedBlobDescriptor>[];
  for (final blob in frontIndex.unitBlobs) {
    checkedCatalogRangeEnd(
      blob.offset,
      blob.length,
      frontIndex.header.declaredFileLength,
    );
    descriptors.add(VerifiedBlobDescriptor(
      key: runtimeUnitBlobKey(blob.rendition, blob.unit),
      kind: 'unit',
      byteLength: blob.length,
    ));
  }
  return descriptors;
}

_CatalogInstallation _installOwnedBytes(Uint8List callerBytes) {
  if (callerBytes.lengthInBytes > formatDefaultBudgets.maxFileBytes) {
    throw _catalogError(
      RuntimeFailureCode.invalidAsset,
      'asset catalog input exceeds the complete-file limit',
    );
  }

  Uint8List bytes;
  try {
    bytes = Uint8List(callerBytes.lengthInBytes);
    bytes.setAll(0, callerBytes);
  } catch (_) {
    throw _catalogError(
      RuntimeFailureCode.resourceRejection,
      'asset catalog owned-byte allocation failed',
    );
  }

  ValidatedAssetLayout layout;
  try {
    layout = validateCompleteAsset(bytes: bytes);
  } catch (error) {
    throw _normalizeInstallError(error);
  }
  return _CatalogInstallation(
    frontIndex: layout.frontIndex,
    declaredFileLength: bytes.lengthInBytes,
    mode: RuntimeTransportMode.full,
    metadataBytes: layout.frontIndex.frontIndexRange.length,
    baseOwnedBytes: bytes.lengthInBytes,
    payloadOwnership: _PayloadOwnership.none,
    payloads: _createOwnedPayloadAuthority(bytes, layout.frontIndex),
    completeLayout: layout,
  );
}

_CatalogInstallation _installMetadata(MetadataRuntimeAssetCatalogInput input) {
  final frontIndex = input.frontIndex;
  final declared = input.declaredFileLength;
  if (declared < 1 ||
      declared > formatDefaultBudgets.maxFileBytes ||
      frontIndex.header.declaredFileLength != declared ||
      frontIndex.frontIndexRange.offset != 0 ||
      frontIndex.frontIndexRange.length < 1 ||
      frontIndex.frontIndexRange.length > declared) {
    throw _catalogError(
      RuntimeFailureCode.invalidAsset,
      'metadata catalog declared geometry is invalid',
    );
  }
  final descriptors = createRuntimeCatalogBlobDescriptors(frontIndex);
  final snapshot = input.blobStore.snapshot();
  if (snapshot.disposed ||
      snapshot.unitBlobs.total != frontIndex.unitBlobs.length) {
    throw _catalogError(
      RuntimeFailureCode.invalidAsset,
      'verified blob store descriptors do not match metadata',
    );
  }
  try {
    for (final descriptor in descriptors) {
      input.blobStore.state(descriptor.key);
    }
  } catch (_) {
    throw _catalogError(
      RuntimeFailureCode.invalidAsset,
      'verified blob store key mapping does not match metadata',
    );
  }
  return _CatalogInstallation(
    frontIndex: frontIndex,
    declaredFileLength: declared,
    mode: input.mode,
    metadataBytes: frontIndex.frontIndexRange.length,
    baseOwnedBytes: input.mode == RuntimeTransportMode.full
        ? declared
        : frontIndex.frontIndexRange.length,
    payloadOwnership: input.mode == RuntimeTransportMode.range
        ? _PayloadOwnership.verified
        : _PayloadOwnership.persistent,
    payloads: _VerifiedPayloadAuthority(input.blobStore),
    completeLayout: null,
  );
}

_CatalogPayloadAuthority _createOwnedPayloadAuthority(
  Uint8List initialBytes,
  ParsedFrontIndex frontIndex,
) {
  final ranges = <String, ByteRange>{};
  for (final blob in frontIndex.unitBlobs) {
    ranges[runtimeUnitBlobKey(blob.rendition, blob.unit)] =
        ByteRange(offset: blob.offset, length: blob.length);
  }
  return _OwnedPayloadAuthority(
    initialBytes,
    ranges,
    frontIndex.unitBlobs.map((blob) => blob.length).toList(),
  );
}

class _OwnedPayloadAuthority extends _CatalogPayloadAuthority {
  _OwnedPayloadAuthority(this._bytes, this._ranges, this._blobLengths);

  Uint8List? _bytes;
  final Map<String, ByteRange> _ranges;
  final List<int> _blobLengths;

  @override
  RuntimeBlobResidencyState state(String key) {
    if (!_ranges.containsKey(key)) {
      throw _catalogError(
        RuntimeFailureCode.invalidAsset,
        'owned blob key is unavailable',
      );
    }
    return _bytes == null
        ? RuntimeBlobResidencyState.absent
        : RuntimeBlobResidencyState.verified;
  }

  @override
  Uint8List copyRange(String key, int relativeOffset, int byteLength) {
    final range = _requireOwnedRange(_ranges, key);
    return _copyOwnedBytes(_bytes, range, relativeOffset, byteLength);
  }

  @override
  AvcRenditionInspection inspectAvcRendition(BorrowedAvcRenditionPlan plan) {
    return _inspectBorrowedOwnedAvcRendition(plan, _ranges, _bytes);
  }

  @override
  _CatalogPayloadSnapshot snapshot() {
    final disposed = _bytes == null;
    final unitBlobs = _summarizeOwnedBlobs(_blobLengths, disposed);
    return _CatalogPayloadSnapshot(
      generation: 0,
      verifiedBytes: disposed ? 0 : unitBlobs.verifiedBytes,
      persistentBytes: 0,
      unitBlobs: unitBlobs,
    );
  }

  @override
  void dispose() {
    _bytes = null;
    _ranges.clear();
  }
}

class _VerifiedPayloadAuthority extends _CatalogPayloadAuthority {
  _VerifiedPayloadAuthority(this._store);

  final VerifiedBlobStore _store;

  @override
  RuntimeBlobResidencyState state(String key) => _store.state(key);

  @override
  Uint8List copyRange(String key, int relativeOffset, int byteLength) =>
      _store.copyRange(key, relativeOffset, byteLength);

  @override
  AvcRenditionInspection inspectAvcRendition(BorrowedAvcRenditionPlan plan) =>
      _store.inspectAvcRendition(plan);

  @override
  _CatalogPayloadSnapshot snapshot() {
    final VerifiedBlobStoreSnapshot value = _store.snapshot();
    return _CatalogPayloadSnapshot(
      generation: value.generation,
      verifiedBytes: value.verifiedBytes,
      persistentBytes: value.persistentBytes,
      unitBlobs: value.unitBlobs,
    );
  }

  @override
  void dispose() {
    // Fire-and-forget the store's async disposal (asset-catalog.ts:519-521).
    _store.dispose();
  }
}

AvcRenditionInspection _inspectBorrowedOwnedAvcRendition(
  BorrowedAvcRenditionPlan plan,
  Map<String, ByteRange> ranges,
  Uint8List? bytes,
) {
  if (bytes == null) throw _disposedCatalogError();
  return inspectBorrowedAvcRendition(plan, (key, relativeOffset, byteLength) {
    final range = _requireOwnedRange(ranges, key);
    if (relativeOffset < 0 ||
        byteLength < 1 ||
        relativeOffset > range.length ||
        byteLength > range.length - relativeOffset) {
      throw _catalogError(
        RuntimeFailureCode.invalidAsset,
        'owned blob borrow range is invalid',
      );
    }
    final absoluteOffset = range.offset + relativeOffset;
    final end =
        checkedCatalogRangeEnd(absoluteOffset, byteLength, bytes.lengthInBytes);
    return Uint8List.sublistView(bytes, absoluteOffset, end);
  });
}

RuntimeBlobResidencySnapshot _summarizeOwnedBlobs(
  List<int> lengths,
  bool disposed,
) {
  final verifiedBytes =
      disposed ? 0 : lengths.fold<int>(0, (total, length) => total + length);
  return RuntimeBlobResidencySnapshot(
    total: lengths.length,
    absent: disposed ? lengths.length : 0,
    loading: 0,
    verified: disposed ? 0 : lengths.length,
    verifiedBytes: verifiedBytes,
  );
}

ByteRange _requireOwnedRange(Map<String, ByteRange> ranges, String key) {
  final range = ranges[key];
  if (range == null) {
    throw _catalogError(
      RuntimeFailureCode.invalidAsset,
      'owned blob key is unavailable',
    );
  }
  return range;
}

Uint8List _copyOwnedBytes(
  Uint8List? bytes,
  ByteRange range,
  int relativeOffset,
  int byteLength,
) {
  if (bytes == null) throw _disposedCatalogError();
  if (relativeOffset < 0 ||
      byteLength < 1 ||
      relativeOffset > range.length ||
      byteLength > range.length - relativeOffset) {
    throw _catalogError(
      RuntimeFailureCode.invalidAsset,
      'owned blob copy range is invalid',
    );
  }
  final absoluteOffset = range.offset + relativeOffset;
  final end =
      checkedCatalogRangeEnd(absoluteOffset, byteLength, bytes.lengthInBytes);
  Uint8List copy;
  try {
    copy = Uint8List(byteLength);
  } catch (_) {
    throw _catalogError(
      RuntimeFailureCode.resourceRejection,
      'asset catalog byte-copy allocation failed',
    );
  }
  copy.setRange(0, byteLength, bytes, absoluteOffset);
  assert(end == absoluteOffset + byteLength);
  return copy;
}

String _requireCatalogBlobKey(String? value) {
  if (value == null || value.isEmpty) {
    throw _catalogError(
      RuntimeFailureCode.invalidAsset,
      'asset catalog blob key is missing',
    );
  }
  return value;
}

ByteRange _requireCatalogRelativeRange(ByteRange? value) {
  if (value == null) {
    throw _catalogError(
      RuntimeFailureCode.invalidAsset,
      'asset catalog sample range is missing',
    );
  }
  return value;
}

int _checkedOwnedByteSum(int metadataBytes, int payloadBytes) {
  final total = metadataBytes + payloadBytes;
  if (total > formatDefaultBudgets.maxFileBytes) {
    throw _catalogError(
      RuntimeFailureCode.resourceRejection,
      'asset catalog owned byte total is invalid',
    );
  }
  return total;
}

RuntimePlaybackError _normalizeInstallError(Object error) {
  if (error is RuntimePlaybackError) return error;
  if (error is FormatError) {
    return RuntimePlaybackError(normalizeRuntimeFailure(
      RuntimeFailureCode.invalidAsset,
      null,
      RuntimeFailureContext(
        sourceCode: error.code.name,
        sourcePath: error.path,
        offset: error.offset,
      ),
    ));
  }
  return _catalogError(
    RuntimeFailureCode.invalidAsset,
    'complete asset validation failed',
  );
}

RuntimePlaybackError _disposedCatalogError() {
  return _catalogError(RuntimeFailureCode.disposed, 'asset catalog is disposed');
}

RuntimePlaybackError _catalogError(
  RuntimeFailureCode code,
  String message, [
  RuntimeFailureContext context = const RuntimeFailureContext(),
]) {
  return RuntimePlaybackError(normalizeRuntimeFailure(code, message, context));
}

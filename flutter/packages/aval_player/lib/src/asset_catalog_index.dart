/// Immutable catalog lookup maps and indexes over a parsed front index.
///
/// Direct port of `packages/player-web/src/runtime/asset-catalog-index.ts`.
/// TS `ReadonlyMap` → Dart `Map` (returned views are copied via
/// `List.unmodifiable`); the `Pick`-narrowed index interfaces map onto full
/// abstract interfaces. `frontIndex.header?.declaredFileLength` becomes a plain
/// field read because [FormatHeader] is non-nullable in the Dart format port.
/// The generic `indexById<TValue extends {id}>` becomes an id-extractor
/// argument because Dart has no structural "has an `id`" bound.
library;

import 'package:aval_format/aval_format.dart'
    show
        AccessUnitRecord,
        BodyUnitV01,
        ByteRange,
        EdgeV01,
        ParsedFrontIndex,
        PortV01,
        RenditionV01,
        StateV01,
        UnitBlobRange,
        UnitV01;

import 'errors.dart'
    show
        RuntimeFailureCode,
        RuntimeFailureContext,
        RuntimePlaybackError,
        normalizeRuntimeFailure;

/// A require/get lookup index keyed by entity id.
abstract interface class RuntimeCatalogIdIndex<TValue> {
  int get size;
  TValue? get(String id);
  TValue require(String id);
  List<String> keys();
  List<TValue> values();
}

/// One body port plus its owning unit id.
class RuntimeCatalogPortEntry {
  const RuntimeCatalogPortEntry({required this.unit, required this.port});

  final String unit;
  final PortV01 port;
}

/// A require/get lookup index of body ports keyed by `unit/port`.
abstract interface class RuntimeCatalogPortIndex {
  int get size;
  RuntimeCatalogPortEntry? get(String unit, String port);
  RuntimeCatalogPortEntry require(String unit, String port);
  List<RuntimeCatalogPortEntry> values();
}

/// One access unit's byte geometry and identity.
class RuntimeCatalogAccessUnit {
  const RuntimeCatalogAccessUnit({
    required this.rendition,
    required this.unit,
    required this.localFrame,
    required this.ordinal,
    required this.record,
    required this.range,
    this.blobKey,
    this.blobRange,
    this.relativeRange,
  });

  final String rendition;
  final String unit;
  final int localFrame;
  final int ordinal;
  final AccessUnitRecord record;
  final String? blobKey;
  final UnitBlobRange? blobRange;
  final ByteRange? relativeRange;
  final ByteRange range;
}

/// A require/get lookup index of access units keyed by `rendition/unit/frame`.
abstract interface class RuntimeCatalogRecordIndex {
  int get size;
  RuntimeCatalogAccessUnit? get(String rendition, String unit, int localFrame);
  RuntimeCatalogAccessUnit require(
    String rendition,
    String unit,
    int localFrame,
  );
  List<RuntimeCatalogAccessUnit> values();
}

/// Input to [buildCatalogMaps].
class CatalogMapBuildInput {
  const CatalogMapBuildInput({
    required this.frontIndex,
    required this.declaredFileLength,
  });

  final ParsedFrontIndex frontIndex;
  final int declaredFileLength;
}

/// The complete set of built catalog lookup maps.
class CatalogMaps {
  const CatalogMaps({
    required this.renditions,
    required this.units,
    required this.states,
    required this.edges,
    required this.ports,
    required this.records,
  });

  final Map<String, RenditionV01> renditions;
  final Map<String, UnitV01> units;
  final Map<String, StateV01> states;
  final Map<String, EdgeV01> edges;
  final Map<String, RuntimeCatalogPortEntry> ports;
  final Map<String, RuntimeCatalogAccessUnit> records;
}

CatalogMaps buildCatalogMaps(CatalogMapBuildInput input) {
  final frontIndex = input.frontIndex;
  final byteLength = input.declaredFileLength;
  if (byteLength < 1 || frontIndex.header.declaredFileLength != byteLength) {
    throw _indexError('asset catalog front-index geometry is invalid');
  }
  final manifest = frontIndex.manifest;
  final renditions = _indexById<RenditionV01>(
    manifest.renditions,
    (value) => value.id,
    'rendition',
  );
  final units = _indexById<UnitV01>(
    manifest.units,
    (value) => value.id,
    'unit',
  );
  final states = _indexById<StateV01>(
    manifest.states,
    (value) => value.id,
    'state',
  );
  final edges = _indexById<EdgeV01>(
    manifest.edges,
    (value) => value.id,
    'edge',
  );
  final ports = <String, RuntimeCatalogPortEntry>{};
  final records = <String, RuntimeCatalogAccessUnit>{};
  final unitBlobs = _indexUnitBlobs(frontIndex, byteLength);

  for (final unit in manifest.units) {
    if (unit.kind != 'body') continue;
    for (final port in (unit as BodyUnitV01).ports) {
      _insertUnique(
        ports,
        _portIdentity(unit.id, port.id),
        RuntimeCatalogPortEntry(unit: unit.id, port: port),
        'validated asset contains a duplicate body port',
      );
    }
  }

  for (var ordinal = 0; ordinal < frontIndex.records.length; ordinal += 1) {
    final record = frontIndex.records[ordinal];
    if (record.renditionIndex < 0 ||
        record.renditionIndex >= manifest.renditions.length ||
        record.unitIndex < 0 ||
        record.unitIndex >= manifest.units.length) {
      throw _indexError('validated asset record relation is missing');
    }
    final rendition = manifest.renditions[record.renditionIndex];
    final unit = manifest.units[record.unitIndex];
    checkedCatalogRangeEnd(
      record.payloadOffset,
      record.payloadLength,
      byteLength,
    );
    final blob = unitBlobs[_unitBlobIdentity(rendition.id, unit.id)];
    if (blob == null) {
      throw _indexError('validated asset record has no containing unit blob');
    }
    final blobEnd = checkedCatalogRangeEnd(blob.offset, blob.length, byteLength);
    final recordEnd = record.payloadOffset + record.payloadLength;
    if (ordinal < blob.sampleStart ||
        ordinal >= blob.sampleStart + blob.sampleCount ||
        record.payloadOffset < blob.offset ||
        recordEnd > blobEnd) {
      throw _indexError('validated asset record exceeds its unit blob');
    }
    final range = ByteRange(
      offset: record.payloadOffset,
      length: record.payloadLength,
    );
    final relativeRange = ByteRange(
      offset: record.payloadOffset - blob.offset,
      length: record.payloadLength,
    );
    _insertUnique(
      records,
      _recordIdentity(rendition.id, unit.id, record.frameIndex),
      RuntimeCatalogAccessUnit(
        rendition: rendition.id,
        unit: unit.id,
        localFrame: record.frameIndex,
        ordinal: ordinal,
        record: record,
        blobKey: runtimeUnitBlobKey(rendition.id, unit.id),
        blobRange: blob,
        relativeRange: relativeRange,
        range: range,
      ),
      'validated asset contains a duplicate access-unit identity',
    );
  }

  return CatalogMaps(
    renditions: renditions,
    units: units,
    states: states,
    edges: edges,
    ports: ports,
    records: records,
  );
}

String runtimeUnitBlobKey(String rendition, String unit) =>
    'unit:$rendition:$unit';

Map<String, UnitBlobRange> _indexUnitBlobs(
  ParsedFrontIndex frontIndex,
  int declaredFileLength,
) {
  final result = <String, UnitBlobRange>{};
  for (final blob in frontIndex.unitBlobs) {
    checkedCatalogRangeEnd(blob.offset, blob.length, declaredFileLength);
    if (blob.sampleStart < 0 ||
        blob.sampleCount < 1 ||
        blob.sampleStart > frontIndex.records.length ||
        blob.sampleCount > frontIndex.records.length - blob.sampleStart) {
      throw _indexError('validated unit blob sample span is invalid');
    }
    _insertUnique(
      result,
      _unitBlobIdentity(blob.rendition, blob.unit),
      blob,
      'validated asset contains a duplicate unit blob',
    );
  }
  return result;
}

RuntimeCatalogIdIndex<TValue> createCatalogIdIndex<TValue>(
  String label,
  Map<String, TValue> Function() map,
  RuntimeFailureContext Function(String id) context,
) {
  return _CatalogIdIndex<TValue>(label, map, context);
}

RuntimeCatalogPortIndex createCatalogPortIndex(
  Map<String, RuntimeCatalogPortEntry> Function() map,
) {
  return _CatalogPortIndex(map);
}

RuntimeCatalogRecordIndex createCatalogRecordIndex(
  Map<String, RuntimeCatalogAccessUnit> Function() map,
) {
  return _CatalogRecordIndex(map);
}

int checkedCatalogRangeEnd(int offset, int length, int limit) {
  if (offset < 0 || length < 1 || offset > limit || length > limit - offset) {
    throw _indexError('validated asset byte range is unavailable');
  }
  return offset + length;
}

class _CatalogIdIndex<TValue> implements RuntimeCatalogIdIndex<TValue> {
  _CatalogIdIndex(this._label, this._map, this._context);

  final String _label;
  final Map<String, TValue> Function() _map;
  final RuntimeFailureContext Function(String id) _context;

  @override
  int get size => _map().length;

  @override
  TValue? get(String id) => _map()[id];

  @override
  TValue require(String id) {
    final value = _map()[id];
    if (value == null) {
      throw _indexError('asset catalog $_label lookup failed', _context(id));
    }
    return value;
  }

  @override
  List<String> keys() => List<String>.unmodifiable(_map().keys);

  @override
  List<TValue> values() => List<TValue>.unmodifiable(_map().values);
}

class _CatalogPortIndex implements RuntimeCatalogPortIndex {
  _CatalogPortIndex(this._map);

  final Map<String, RuntimeCatalogPortEntry> Function() _map;

  @override
  int get size => _map().length;

  @override
  RuntimeCatalogPortEntry? get(String unit, String port) =>
      _map()[_portIdentity(unit, port)];

  @override
  RuntimeCatalogPortEntry require(String unit, String port) {
    final value = _map()[_portIdentity(unit, port)];
    if (value == null) {
      throw _indexError(
        'asset catalog port lookup failed',
        RuntimeFailureContext(unit: unit, path: port),
      );
    }
    return value;
  }

  @override
  List<RuntimeCatalogPortEntry> values() =>
      List<RuntimeCatalogPortEntry>.unmodifiable(_map().values);
}

class _CatalogRecordIndex implements RuntimeCatalogRecordIndex {
  _CatalogRecordIndex(this._map);

  final Map<String, RuntimeCatalogAccessUnit> Function() _map;

  @override
  int get size => _map().length;

  @override
  RuntimeCatalogAccessUnit? get(String rendition, String unit, int localFrame) =>
      _map()[_recordIdentity(rendition, unit, localFrame)];

  @override
  RuntimeCatalogAccessUnit require(
    String rendition,
    String unit,
    int localFrame,
  ) {
    final value = _map()[_recordIdentity(rendition, unit, localFrame)];
    if (value == null) {
      throw _indexError(
        'asset catalog access-unit lookup failed',
        RuntimeFailureContext(
          rendition: rendition,
          unit: unit,
          localFrame: localFrame,
        ),
      );
    }
    return value;
  }

  @override
  List<RuntimeCatalogAccessUnit> values() =>
      List<RuntimeCatalogAccessUnit>.unmodifiable(_map().values);
}

Map<String, TValue> _indexById<TValue>(
  List<TValue> values,
  String Function(TValue) idOf,
  String label,
) {
  final map = <String, TValue>{};
  for (final value in values) {
    _insertUnique(
      map,
      idOf(value),
      value,
      'validated asset contains a duplicate $label',
    );
  }
  return map;
}

void _insertUnique<TValue>(
  Map<String, TValue> map,
  String key,
  TValue value,
  String message,
) {
  if (map.containsKey(key)) throw _indexError(message);
  map[key] = value;
}

String _portIdentity(String unit, String port) => '$unit/$port';

String _unitBlobIdentity(String rendition, String unit) =>
    runtimeUnitBlobKey(rendition, unit);

String _recordIdentity(String rendition, String unit, int localFrame) =>
    '$rendition/$unit/$localFrame';

RuntimePlaybackError _indexError(
  String message, [
  RuntimeFailureContext context = const RuntimeFailureContext(),
]) {
  return RuntimePlaybackError(
    normalizeRuntimeFailure(RuntimeFailureCode.invalidAsset, message, context),
  );
}

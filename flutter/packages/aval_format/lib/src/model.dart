/// Version-1.0 AVAL wire model: budgets, manifest types, and layout records.
///
/// Dart port of `packages/format/src/model.ts`. TypeScript discriminated
/// unions become sealed class hierarchies; plain interfaces become immutable
/// classes. String-literal unions whose only runtime use is equality/
/// membership testing performed elsewhere (in the `manifest_*schema.dart`
/// validators, mirroring `manifest-*.ts`) are kept as plain `String`/`typedef`
/// rather than Dart `enum`s, so the single set of legal literals lives in one
/// place exactly as it does in the TS source.
library;

import 'dart:typed_data';

import 'package:aval_graph/aval_graph.dart' show ValidatedMotionGraph;

typedef Id = String;
typedef Sha256Hex = String;

/// `"h264" | "h265" | "vp9" | "av1"`.
typedef VideoCodec = String;

/// `"annex-b" | "frame" | "low-overhead"`.
typedef VideoBitstream = String;

/// `"opaque" | "packed-alpha"`.
typedef VideoLayout = String;

/// `8 | 10`.
typedef VideoBitDepth = int;

/// `readonly [x, y, width, height]` in the TS source.
class Rect {
  const Rect(this.x, this.y, this.width, this.height);

  final int x;
  final int y;
  final int width;
  final int height;

  List<int> toList() => [x, y, width, height];

  @override
  bool operator ==(Object other) =>
      other is Rect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'Rect($x, $y, $width, $height)';
}

class FormatBudgets {
  const FormatBudgets({
    required this.maxFileBytes,
    required this.maxManifestBytes,
    required this.maxIndexBytes,
    required this.maxChunkBytes,
    required this.maxPngBytes,
    required this.maxJsonDepth,
    required this.maxJsonNodes,
    required this.maxJsonStringBytes,
    required this.maxStates,
    required this.maxEdges,
    required this.maxUnits,
    required this.maxRenditions,
    required this.maxBindings,
    required this.maxBlobRanges,
    required this.maxTotalUnitFrames,
    required this.maxChunkRecords,
    required this.maxPortsPerBody,
    required this.maxReversibleFrames,
  });

  final int maxFileBytes;
  final int maxManifestBytes;
  final int maxIndexBytes;
  final int maxChunkBytes;
  final int maxPngBytes;
  final int maxJsonDepth;
  final int maxJsonNodes;
  final int maxJsonStringBytes;
  final int maxStates;
  final int maxEdges;
  final int maxUnits;
  final int maxRenditions;
  final int maxBindings;
  final int maxBlobRanges;
  final int maxTotalUnitFrames;
  final int maxChunkRecords;
  final int maxPortsPerBody;
  final int maxReversibleFrames;

  /// Keys match the exact TS `keyof FormatBudgets` field names, used by
  /// `resolveFormatBudgets` to walk override keys generically.
  Map<String, int> toMap() => {
        'maxFileBytes': maxFileBytes,
        'maxManifestBytes': maxManifestBytes,
        'maxIndexBytes': maxIndexBytes,
        'maxChunkBytes': maxChunkBytes,
        'maxPngBytes': maxPngBytes,
        'maxJsonDepth': maxJsonDepth,
        'maxJsonNodes': maxJsonNodes,
        'maxJsonStringBytes': maxJsonStringBytes,
        'maxStates': maxStates,
        'maxEdges': maxEdges,
        'maxUnits': maxUnits,
        'maxRenditions': maxRenditions,
        'maxBindings': maxBindings,
        'maxBlobRanges': maxBlobRanges,
        'maxTotalUnitFrames': maxTotalUnitFrames,
        'maxChunkRecords': maxChunkRecords,
        'maxPortsPerBody': maxPortsPerBody,
        'maxReversibleFrames': maxReversibleFrames,
      };

  factory FormatBudgets.fromMap(Map<String, int> map) => FormatBudgets(
        maxFileBytes: map['maxFileBytes']!,
        maxManifestBytes: map['maxManifestBytes']!,
        maxIndexBytes: map['maxIndexBytes']!,
        maxChunkBytes: map['maxChunkBytes']!,
        maxPngBytes: map['maxPngBytes']!,
        maxJsonDepth: map['maxJsonDepth']!,
        maxJsonNodes: map['maxJsonNodes']!,
        maxJsonStringBytes: map['maxJsonStringBytes']!,
        maxStates: map['maxStates']!,
        maxEdges: map['maxEdges']!,
        maxUnits: map['maxUnits']!,
        maxRenditions: map['maxRenditions']!,
        maxBindings: map['maxBindings']!,
        maxBlobRanges: map['maxBlobRanges']!,
        maxTotalUnitFrames: map['maxTotalUnitFrames']!,
        maxChunkRecords: map['maxChunkRecords']!,
        maxPortsPerBody: map['maxPortsPerBody']!,
        maxReversibleFrames: map['maxReversibleFrames']!,
      );
}

/// `{ budgets?: Partial<FormatBudgets> }`. A `Partial<FormatBudgets>` is
/// represented as a sparse `Map<String, int>` keyed by the same field names as
/// [FormatBudgets.toMap], since the TS validator itself treats budgets
/// generically by key name (`Reflect.ownKeys`).
class FormatOptions {
  const FormatOptions({this.budgets});

  final Map<String, int>? budgets;
}

class Rational {
  const Rational({required this.numerator, required this.denominator});

  final int numerator;
  final int denominator;

  @override
  bool operator ==(Object other) =>
      other is Rational &&
      other.numerator == numerator &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);
}

class Canvas {
  const Canvas({
    required this.width,
    required this.height,
    required this.fit,
    required this.pixelAspect,
    this.colorSpace = 'srgb',
  });

  final int width;
  final int height;

  /// `"contain" | "cover" | "fill" | "none"`.
  final String fit;

  /// `readonly [numerator, denominator]`.
  final List<int> pixelAspect;

  /// Always `"srgb"` (the only literal in the TS union).
  final String colorSpace;
}

class Bitrate {
  const Bitrate({required this.average, required this.peak});

  final int average;
  final int peak;

  @override
  bool operator ==(Object other) =>
      other is Bitrate && other.average == average && other.peak == peak;

  @override
  int get hashCode => Object.hash(average, peak);
}

/// TS discriminated union `AlphaLayout`. [type] is the discriminant
/// (`"opaque" | "stacked"`).
sealed class AlphaLayout {
  const AlphaLayout({required this.type, required this.colorRect});

  final String type;
  final Rect colorRect;
}

class OpaqueAlphaLayout extends AlphaLayout {
  const OpaqueAlphaLayout({required super.colorRect}) : super(type: 'opaque');
}

class StackedAlphaLayout extends AlphaLayout {
  const StackedAlphaLayout({required super.colorRect, required this.alphaRect})
      : super(type: 'stacked');

  final Rect alphaRect;
}

/// One quality rung in a single-codec asset. Array order is author preference.
class ProductionRendition {
  const ProductionRendition({
    required this.id,
    required this.codec,
    required this.bitDepth,
    required this.codedWidth,
    required this.codedHeight,
    required this.alphaLayout,
    required this.bitrate,
  });

  final Id id;
  final String codec;
  final VideoBitDepth bitDepth;
  final int codedWidth;
  final int codedHeight;
  final AlphaLayout alphaLayout;
  final Bitrate bitrate;
}

/// One unit/rendition blob in the global decode-order chunk array.
class UnitChunkSpan {
  const UnitChunkSpan({
    required this.rendition,
    required this.chunkStart,
    required this.chunkCount,
    required this.frameCount,
    required this.sha256,
  });

  final Id rendition;
  final int chunkStart;
  final int chunkCount;
  final int frameCount;
  final Sha256Hex sha256;

  @override
  bool operator ==(Object other) =>
      other is UnitChunkSpan &&
      other.rendition == rendition &&
      other.chunkStart == chunkStart &&
      other.chunkCount == chunkCount &&
      other.frameCount == frameCount &&
      other.sha256 == sha256;

  @override
  int get hashCode =>
      Object.hash(rendition, chunkStart, chunkCount, frameCount, sha256);
}

class Port {
  const Port({required this.id, required this.portalFrames});

  final Id id;

  /// Always `0` (TS `entryFrame: 0` literal type).
  int get entryFrame => 0;
  final List<int> portalFrames;
}

class ResidencyEndpoint {
  const ResidencyEndpoint({
    required this.state,
    required this.port,
    required this.frames,
  });

  final Id state;
  final Id port;
  final int frames;
}

class ReversibleResidency {
  const ReversibleResidency(this.endpoints);

  /// Exactly two entries, matching the TS tuple
  /// `readonly [ResidencyEndpoint, ResidencyEndpoint]`.
  final List<ResidencyEndpoint> endpoints;
}

/// TS discriminated union `Unit`. [kind] is the discriminant.
sealed class Unit {
  const Unit({
    required this.id,
    required this.kind,
    required this.frameCount,
    required this.chunks,
  });

  final Id id;

  /// `"body" | "bridge" | "reversible" | "one-shot"`.
  final String kind;
  final int frameCount;
  final List<UnitChunkSpan> chunks;
}

class BodyUnit extends Unit {
  const BodyUnit({
    required super.id,
    required super.frameCount,
    required super.chunks,
    required this.playback,
    required this.ports,
  }) : super(kind: 'body');

  /// `"loop" | "finite"`.
  final String playback;
  final List<Port> ports;
}

class BridgeUnit extends Unit {
  const BridgeUnit({
    required super.id,
    required super.frameCount,
    required super.chunks,
  }) : super(kind: 'bridge');
}

class ReversibleUnit extends Unit {
  const ReversibleUnit({
    required super.id,
    required super.frameCount,
    required super.chunks,
    required this.residency,
  }) : super(kind: 'reversible');

  final ReversibleResidency residency;
}

class OneShotUnit extends Unit {
  const OneShotUnit({
    required super.id,
    required super.frameCount,
    required super.chunks,
  }) : super(kind: 'one-shot');
}

class State {
  const State({required this.id, required this.bodyUnit, this.initialUnit});

  final Id id;
  final Id bodyUnit;
  final Id? initialUnit;
}

/// TS discriminated union `Trigger`. [type] is the discriminant.
sealed class Trigger {
  const Trigger(this.type);

  /// `"event" | "completion"`.
  final String type;
}

class EventTrigger extends Trigger {
  const EventTrigger(this.name) : super('event');

  final Id name;
}

class CompletionTrigger extends Trigger {
  const CompletionTrigger() : super('completion');
}

/// TS discriminated union `Start`. [type] is the discriminant.
sealed class Start {
  const Start({
    required this.type,
    required this.targetPort,
    required this.maxWaitFrames,
  });

  /// `"portal" | "finish" | "cut"`.
  final String type;
  final Id targetPort;
  final int maxWaitFrames;
}

class PortalStart extends Start {
  const PortalStart({
    required this.sourcePort,
    required super.targetPort,
    required super.maxWaitFrames,
  }) : super(type: 'portal');

  final Id sourcePort;
}

class FinishStart extends Start {
  const FinishStart({
    required super.targetPort,
    required super.maxWaitFrames,
  }) : super(type: 'finish');
}

class CutStart extends Start {
  const CutStart({required super.targetPort})
      : super(type: 'cut', maxWaitFrames: 1);
}

/// TS discriminated union `Transition`. [kind] is the discriminant.
sealed class Transition {
  const Transition({required this.kind, required this.unit});

  /// `"locked" | "reversible"`.
  final String kind;
  final Id unit;
}

class LockedTransition extends Transition {
  const LockedTransition({required super.unit}) : super(kind: 'locked');
}

class ReversibleTransition extends Transition {
  const ReversibleTransition({
    required super.unit,
    required this.direction,
    this.reverseOf,
  }) : super(kind: 'reversible');

  /// `"forward" | "reverse"`.
  final String direction;
  final Id? reverseOf;
}

/// TS discriminated union `Edge` (`NonCutEdge | CutEdge`).
/// [continuity] `== 'cut'` iff this is a [CutEdge].
sealed class Edge {
  const Edge({
    required this.id,
    required this.from,
    required this.to,
    this.trigger,
    required this.start,
    required this.continuity,
  });

  final Id id;
  final Id from;
  final Id to;
  final Trigger? trigger;
  final Start start;

  /// `"exact-authored" | "exact-reverse" | "cut"`.
  final String continuity;
}

class NonCutEdge extends Edge {
  const NonCutEdge({
    required super.id,
    required super.from,
    required super.to,
    super.trigger,
    required super.start,
    required super.continuity,
    this.transition,
  });

  final Transition? transition;
}

class CutEdge extends Edge {
  const CutEdge({
    required super.id,
    required super.from,
    required super.to,
    super.trigger,
    required CutStart start,
    required this.targetRunwayFrames,
  }) : super(start: start, continuity: 'cut');

  final int targetRunwayFrames;
}

/// `"activate" | "engagement.off" | "engagement.on" | "focus.in" |
/// "focus.out" | "hidden" | "pointer.enter" | "pointer.leave" | "visible"`.
typedef BindingSource = String;

class Binding {
  const Binding({required this.source, required this.event});

  final BindingSource source;
  final Id event;
}

class Readiness {
  const Readiness({
    required this.bootstrapUnits,
    required this.immediateEdges,
  });

  /// Always `"all-routes"`.
  String get policy => 'all-routes';
  final List<Id> bootstrapUnits;
  final List<Id> immediateEdges;
}

class DeclaredLimits {
  const DeclaredLimits({
    required this.maxCompiledBytes,
    required this.maxRuntimeBytes,
    required this.decodedPixelBytes,
    required this.persistentCacheBytes,
    required this.runtimeWorkingSetBytes,
  });

  final int maxCompiledBytes;
  final int maxRuntimeBytes;
  final int decodedPixelBytes;
  final int persistentCacheBytes;
  final int runtimeWorkingSetBytes;
}

class CompiledManifest {
  const CompiledManifest({
    required this.generator,
    required this.codec,
    required this.bitstream,
    required this.layout,
    required this.canvas,
    required this.frameRate,
    required this.renditions,
    required this.units,
    required this.initialState,
    required this.states,
    required this.edges,
    required this.bindings,
    required this.readiness,
    required this.limits,
  });

  /// Always `"1.0"`.
  String get formatVersion => '1.0';
  final String generator;
  final VideoCodec codec;
  final VideoBitstream bitstream;
  final VideoLayout layout;
  final Canvas canvas;
  final Rational frameRate;
  final List<ProductionRendition> renditions;
  final List<Unit> units;
  final Id initialState;
  final List<State> states;
  final List<Edge> edges;
  final List<Binding> bindings;
  final Readiness readiness;
  final DeclaredLimits limits;
}

class FormatHeader {
  const FormatHeader({
    required this.declaredFileLength,
    required this.manifestLength,
    required this.indexOffset,
    required this.indexLength,
  });

  /// Always `1`.
  int get major => 1;

  /// Always `0`.
  int get minor => 0;

  /// Always `64`.
  int get headerLength => 64;

  /// Always `0`.
  int get requiredFeatureFlags => 0;
  final int declaredFileLength;

  /// Always `64`.
  int get manifestOffset => 64;
  final int manifestLength;
  final int indexOffset;
  final int indexLength;
}

/// Fixed-width decode-order metadata for one elementary encoded chunk.
class EncodedChunkRecord {
  const EncodedChunkRecord({
    required this.byteOffset,
    required this.byteLength,
    required this.presentationTimestamp,
    required this.duration,
    required this.randomAccess,
    required this.displayedFrameCount,
  });

  final int byteOffset;
  final int byteLength;
  final int presentationTimestamp;
  final int duration;
  final bool randomAccess;
  final int displayedFrameCount;

  @override
  bool operator ==(Object other) =>
      other is EncodedChunkRecord &&
      other.byteOffset == byteOffset &&
      other.byteLength == byteLength &&
      other.presentationTimestamp == presentationTimestamp &&
      other.duration == duration &&
      other.randomAccess == randomAccess &&
      other.displayedFrameCount == displayedFrameCount;

  @override
  int get hashCode => Object.hash(byteOffset, byteLength, presentationTimestamp,
      duration, randomAccess, displayedFrameCount);
}

class ByteRange {
  const ByteRange({required this.offset, required this.length});

  final int offset;
  final int length;

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.offset == offset && other.length == length;

  @override
  int get hashCode => Object.hash(offset, length);
}

class UnitBlobRange extends ByteRange {
  const UnitBlobRange({
    required super.offset,
    required super.length,
    required this.rendition,
    required this.unit,
    required this.chunkStart,
    required this.chunkCount,
    required this.frameCount,
    required this.sha256,
  });

  final Id rendition;
  final Id unit;
  final int chunkStart;
  final int chunkCount;
  final int frameCount;
  final Sha256Hex sha256;
}

class ParsedFrontIndex {
  const ParsedFrontIndex({
    required this.header,
    required this.manifest,
    required this.graph,
    required this.records,
    required this.frontIndexRange,
    required this.unitBlobs,
  });

  final FormatHeader header;
  final CompiledManifest manifest;
  final ValidatedMotionGraph graph;
  final List<EncodedChunkRecord> records;
  final ByteRange frontIndexRange;
  final List<UnitBlobRange> unitBlobs;
}

class ValidatedAssetLayout {
  const ValidatedAssetLayout({
    required this.frontIndex,
    required this.fileRange,
  });

  final ParsedFrontIndex frontIndex;
  final ByteRange fileRange;
}

class ChunkDigestInput {
  const ChunkDigestInput({required this.rendition, required this.sha256});

  final Id rendition;
  final Sha256Hex sha256;
}

/// TS `UnitInputOf<TKind>`: the writer-facing counterpart of [Unit] with
/// `chunks: readonly ChunkDigestInput[]` instead of `UnitChunkSpan[]`.
sealed class UnitInput {
  const UnitInput({
    required this.id,
    required this.kind,
    required this.frameCount,
    required this.chunks,
  });

  final Id id;
  final String kind;
  final int frameCount;
  final List<ChunkDigestInput> chunks;
}

class BodyUnitInput extends UnitInput {
  const BodyUnitInput({
    required super.id,
    required super.frameCount,
    required super.chunks,
    required this.playback,
    required this.ports,
  }) : super(kind: 'body');

  final String playback;
  final List<Port> ports;
}

class BridgeUnitInput extends UnitInput {
  const BridgeUnitInput({
    required super.id,
    required super.frameCount,
    required super.chunks,
  }) : super(kind: 'bridge');
}

class ReversibleUnitInput extends UnitInput {
  const ReversibleUnitInput({
    required super.id,
    required super.frameCount,
    required super.chunks,
    required this.residency,
  }) : super(kind: 'reversible');

  final ReversibleResidency residency;
}

class OneShotUnitInput extends UnitInput {
  const OneShotUnitInput({
    required super.id,
    required super.frameCount,
    required super.chunks,
  }) : super(kind: 'one-shot');
}

class CompiledManifestInput {
  const CompiledManifestInput({
    required this.generator,
    required this.codec,
    required this.bitstream,
    required this.layout,
    required this.canvas,
    required this.frameRate,
    required this.renditions,
    required this.units,
    required this.initialState,
    required this.states,
    required this.edges,
    required this.bindings,
    required this.readiness,
    required this.limits,
  });

  String get formatVersion => '1.0';
  final String generator;
  final VideoCodec codec;
  final VideoBitstream bitstream;
  final VideoLayout layout;
  final Canvas canvas;
  final Rational frameRate;
  final List<ProductionRendition> renditions;
  final List<UnitInput> units;
  final Id initialState;
  final List<State> states;
  final List<Edge> edges;
  final List<Binding> bindings;
  final Readiness readiness;
  final DeclaredLimits limits;
}

/// Caller-owned payload plus timeline metadata, identified within one unit.
class EncodedChunkInput {
  const EncodedChunkInput({
    required this.rendition,
    required this.unit,
    required this.decodeIndex,
    required this.presentationTimestamp,
    required this.duration,
    required this.randomAccess,
    required this.displayedFrameCount,
    required this.bytes,
  });

  final Id rendition;
  final Id unit;
  final int decodeIndex;
  final int presentationTimestamp;
  final int duration;
  final bool randomAccess;
  final int displayedFrameCount;
  final Uint8List bytes;
}

class CanonicalAssetInput {
  const CanonicalAssetInput({
    required this.manifest,
    required this.chunks,
  });

  final CompiledManifestInput manifest;
  final List<EncodedChunkInput> chunks;
}

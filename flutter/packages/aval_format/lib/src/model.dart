/// Version-0.1 AVAL wire model: budgets, manifest types, and layout records.
///
/// Dart port of `packages/format/src/model.ts`. TypeScript discriminated
/// unions become sealed class hierarchies; plain interfaces become
/// immutable classes. String-literal unions whose only runtime use is
/// equality/membership testing performed elsewhere (in the
/// `manifest_*schema.dart` validators, mirroring `manifest-*.ts`) are kept
/// as plain `String`/`typedef` rather than Dart `enum`s, so the single set
/// of legal literals lives in one place exactly as it does in the TS
/// source.
library;

// ignore_for_file: constant_identifier_names

import 'package:aval_graph/aval_graph.dart' show ValidatedMotionGraph;

import 'avc/codec.dart' show AvcCodecV01;

typedef Id = String;
typedef Sha256Hex = String;

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
    required this.maxSampleBytes,
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
    required this.maxSampleRecords,
    required this.maxPortsPerBody,
    required this.maxReversibleFrames,
  });

  final int maxFileBytes;
  final int maxManifestBytes;
  final int maxIndexBytes;
  final int maxSampleBytes;
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
  final int maxSampleRecords;
  final int maxPortsPerBody;
  final int maxReversibleFrames;

  /// Keys match the exact TS `keyof FormatBudgets` field names, used by
  /// `resolveFormatBudgets` to walk override keys generically.
  Map<String, int> toMap() => {
        'maxFileBytes': maxFileBytes,
        'maxManifestBytes': maxManifestBytes,
        'maxIndexBytes': maxIndexBytes,
        'maxSampleBytes': maxSampleBytes,
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
        'maxSampleRecords': maxSampleRecords,
        'maxPortsPerBody': maxPortsPerBody,
        'maxReversibleFrames': maxReversibleFrames,
      };

  factory FormatBudgets.fromMap(Map<String, int> map) => FormatBudgets(
        maxFileBytes: map['maxFileBytes']!,
        maxManifestBytes: map['maxManifestBytes']!,
        maxIndexBytes: map['maxIndexBytes']!,
        maxSampleBytes: map['maxSampleBytes']!,
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
        maxSampleRecords: map['maxSampleRecords']!,
        maxPortsPerBody: map['maxPortsPerBody']!,
        maxReversibleFrames: map['maxReversibleFrames']!,
      );
}

/// `{ budgets?: Partial<FormatBudgets> }`. A `Partial<FormatBudgets>` is
/// represented as a sparse `Map<String, int>` keyed by the same field names
/// as [FormatBudgets.toMap], since the TS validator itself treats budgets
/// generically by key name (`Reflect.ownKeys`).
class FormatOptions {
  const FormatOptions({this.budgets});

  final Map<String, int>? budgets;
}

class RationalV01 {
  const RationalV01({required this.numerator, required this.denominator});

  final int numerator;
  final int denominator;
}

class CanvasV01 {
  const CanvasV01({
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
  final List<int> pixelAspect;

  /// Always `"srgb"` (the only literal in the TS union).
  final String colorSpace;
}

class BitrateV01 {
  const BitrateV01({required this.average, required this.peak});

  final int average;
  final int peak;
}

/// `"avc-annexb-opaque-v0" | "avc-annexb-packed-alpha-v0" |
/// "avc-annexb-opaque-v1" | "avc-annexb-packed-alpha-v1"`.
typedef AvcProductionRenditionProfileV01 = String;

/// TS discriminated union `RenditionV01`. [profile] is the discriminant;
/// use `is` checks (`rendition is AvcOpaqueRenditionV01`, etc.) the same
/// way TS narrows on `rendition.profile`.
sealed class RenditionV01 {
  const RenditionV01({
    required this.id,
    required this.profile,
    required this.codec,
    required this.codedWidth,
    required this.codedHeight,
    required this.capabilities,
  });

  final Id id;
  final String profile;
  final String codec;
  final int codedWidth;
  final int codedHeight;
  final List<String> capabilities;
}

class ReferenceRgbaRenditionV01 extends RenditionV01 {
  const ReferenceRgbaRenditionV01({
    required super.id,
    required super.codedWidth,
    required super.codedHeight,
  }) : super(
          profile: 'reference-rgba-v0',
          codec: 'aval.reference-rgba',
          capabilities: const [],
        );
}

/// Covers both `"avc-annexb-opaque-v0"` and `"avc-annexb-opaque-v1"`
/// (identical shape in the TS union; [profile] carries the exact literal).
class AvcOpaqueRenditionV01 extends RenditionV01 {
  const AvcOpaqueRenditionV01({
    required super.id,
    required String profile,
    required AvcCodecV01 codec,
    required super.codedWidth,
    required super.codedHeight,
    required this.colorRect,
    required this.bitrate,
  }) : super(
          profile: profile,
          codec: codec,
          capabilities: const ['webcodecs', 'webgl2'],
        );

  final Rect colorRect;
  final BitrateV01 bitrate;
}

/// Covers both `"avc-annexb-packed-alpha-v0"` and
/// `"avc-annexb-packed-alpha-v1"`.
class AvcPackedAlphaRenditionV01 extends RenditionV01 {
  const AvcPackedAlphaRenditionV01({
    required super.id,
    required String profile,
    required AvcCodecV01 codec,
    required super.codedWidth,
    required super.codedHeight,
    required this.colorRect,
    required this.alphaRect,
    required this.bitrate,
  }) : super(
          profile: profile,
          codec: codec,
          capabilities: const ['webcodecs', 'webgl2'],
        );

  final Rect colorRect;
  final Rect alphaRect;
  final BitrateV01 bitrate;
}

class SampleSpanV01 {
  const SampleSpanV01({
    required this.rendition,
    required this.sampleStart,
    required this.sampleCount,
    required this.sha256,
  });

  final Id rendition;
  final int sampleStart;
  final int sampleCount;
  final Sha256Hex sha256;
}

class PortV01 {
  const PortV01({required this.id, required this.portalFrames});

  final Id id;

  /// Always `0` (TS `entryFrame: 0` literal type).
  int get entryFrame => 0;
  final List<int> portalFrames;
}

class ResidencyEndpointV01 {
  const ResidencyEndpointV01({
    required this.state,
    required this.port,
    required this.frames,
  });

  final Id state;
  final Id port;
  final int frames;
}

class ReversibleResidencyV01 {
  const ReversibleResidencyV01(this.endpoints);

  /// Exactly two entries, matching the TS tuple
  /// `readonly [ResidencyEndpointV01, ResidencyEndpointV01]`.
  final List<ResidencyEndpointV01> endpoints;
}

/// TS discriminated union `UnitV01`. [kind] is the discriminant.
sealed class UnitV01 {
  const UnitV01({
    required this.id,
    required this.kind,
    required this.frameCount,
    required this.samples,
  });

  final Id id;

  /// `"body" | "bridge" | "reversible" | "one-shot"`.
  final String kind;
  final int frameCount;
  final List<SampleSpanV01> samples;
}

class BodyUnitV01 extends UnitV01 {
  const BodyUnitV01({
    required super.id,
    required super.frameCount,
    required super.samples,
    required this.playback,
    required this.ports,
  }) : super(kind: 'body');

  /// `"loop" | "finite"`.
  final String playback;
  final List<PortV01> ports;
}

class BridgeUnitV01 extends UnitV01 {
  const BridgeUnitV01({
    required super.id,
    required super.frameCount,
    required super.samples,
  }) : super(kind: 'bridge');
}

class ReversibleUnitV01 extends UnitV01 {
  const ReversibleUnitV01({
    required super.id,
    required super.frameCount,
    required super.samples,
    required this.residency,
  }) : super(kind: 'reversible');

  final ReversibleResidencyV01 residency;
}

class OneShotUnitV01 extends UnitV01 {
  const OneShotUnitV01({
    required super.id,
    required super.frameCount,
    required super.samples,
  }) : super(kind: 'one-shot');
}

class StateV01 {
  const StateV01({required this.id, required this.bodyUnit, this.initialUnit});

  final Id id;
  final Id bodyUnit;
  final Id? initialUnit;
}

/// TS discriminated union `TriggerV01`. [type] is the discriminant.
sealed class TriggerV01 {
  const TriggerV01(this.type);

  /// `"event" | "completion"`.
  final String type;
}

class EventTriggerV01 extends TriggerV01 {
  const EventTriggerV01(this.name) : super('event');

  final Id name;
}

class CompletionTriggerV01 extends TriggerV01 {
  const CompletionTriggerV01() : super('completion');
}

/// TS discriminated union `StartV01`. [type] is the discriminant.
sealed class StartV01 {
  const StartV01({
    required this.type,
    required this.targetPort,
    required this.maxWaitFrames,
  });

  /// `"portal" | "finish" | "cut"`.
  final String type;
  final Id targetPort;
  final int maxWaitFrames;
}

class PortalStartV01 extends StartV01 {
  const PortalStartV01({
    required this.sourcePort,
    required super.targetPort,
    required super.maxWaitFrames,
  }) : super(type: 'portal');

  final Id sourcePort;
}

class FinishStartV01 extends StartV01 {
  const FinishStartV01({
    required super.targetPort,
    required super.maxWaitFrames,
  }) : super(type: 'finish');
}

class CutStartV01 extends StartV01 {
  const CutStartV01({required super.targetPort})
      : super(type: 'cut', maxWaitFrames: 1);
}

/// TS discriminated union `TransitionV01`. [kind] is the discriminant.
sealed class TransitionV01 {
  const TransitionV01({required this.kind, required this.unit});

  /// `"locked" | "reversible"`.
  final String kind;
  final Id unit;
}

class LockedTransitionV01 extends TransitionV01 {
  const LockedTransitionV01({required super.unit}) : super(kind: 'locked');
}

class ReversibleTransitionV01 extends TransitionV01 {
  const ReversibleTransitionV01({
    required super.unit,
    required this.direction,
    this.reverseOf,
  }) : super(kind: 'reversible');

  /// `"forward" | "reverse"`.
  final String direction;
  final Id? reverseOf;
}

/// TS discriminated union `EdgeV01` (`NonCutEdgeV01 | CutEdgeV01`).
/// [continuity] `== 'cut'` iff this is a [CutEdgeV01].
sealed class EdgeV01 {
  const EdgeV01({
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
  final TriggerV01? trigger;
  final StartV01 start;

  /// `"exact-authored" | "exact-reverse" | "cut"`.
  final String continuity;
}

class NonCutEdgeV01 extends EdgeV01 {
  const NonCutEdgeV01({
    required super.id,
    required super.from,
    required super.to,
    super.trigger,
    required super.start,
    required super.continuity,
    this.transition,
  });

  final TransitionV01? transition;
}

class CutEdgeV01 extends EdgeV01 {
  const CutEdgeV01({
    required super.id,
    required super.from,
    required super.to,
    super.trigger,
    required CutStartV01 start,
    required this.targetRunwayFrames,
  }) : super(start: start, continuity: 'cut');

  final int targetRunwayFrames;
}

/// `"activate" | "engagement.off" | "engagement.on" | "focus.in" |
/// "focus.out" | "hidden" | "pointer.enter" | "pointer.leave" | "visible"`.
typedef BindingSourceV01 = String;

class BindingV01 {
  const BindingV01({required this.source, required this.event});

  final BindingSourceV01 source;
  final Id event;
}

class ReadinessV01 {
  const ReadinessV01({
    required this.bootstrapUnits,
    required this.immediateEdges,
  });

  /// Always `"all-routes"`.
  String get policy => 'all-routes';
  final List<Id> bootstrapUnits;
  final List<Id> immediateEdges;
}

class DeclaredLimitsV01 {
  const DeclaredLimitsV01({
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

class CompiledManifestV01 {
  const CompiledManifestV01({
    required this.generator,
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

  /// Always `"0.1"`.
  String get formatVersion => '0.1';
  final String generator;
  final CanvasV01 canvas;
  final RationalV01 frameRate;
  final List<RenditionV01> renditions;
  final List<UnitV01> units;
  final Id initialState;
  final List<StateV01> states;
  final List<EdgeV01> edges;
  final List<BindingV01> bindings;
  final ReadinessV01 readiness;
  final DeclaredLimitsV01 limits;
}

class FormatHeader {
  const FormatHeader({
    required this.declaredFileLength,
    required this.manifestLength,
    required this.indexOffset,
    required this.indexLength,
  });

  /// Always `0`.
  int get major => 0;

  /// Always `1`.
  int get minor => 1;

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

class AccessUnitRecord {
  const AccessUnitRecord({
    required this.payloadOffset,
    required this.payloadLength,
    required this.unitIndex,
    required this.renditionIndex,
    required this.key,
    required this.frameIndex,
  });

  final int payloadOffset;
  final int payloadLength;
  final int unitIndex;
  final int renditionIndex;
  final bool key;
  final int frameIndex;
}

class ByteRange {
  const ByteRange({required this.offset, required this.length});

  final int offset;
  final int length;
}

class UnitBlobRange extends ByteRange {
  const UnitBlobRange({
    required super.offset,
    required super.length,
    required this.rendition,
    required this.unit,
    required this.sampleStart,
    required this.sampleCount,
    required this.sha256,
  });

  final Id rendition;
  final Id unit;
  final int sampleStart;
  final int sampleCount;
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
  final CompiledManifestV01 manifest;
  final ValidatedMotionGraph graph;
  final List<AccessUnitRecord> records;
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

class ReferenceFrameHeader {
  const ReferenceFrameHeader({
    required this.width,
    required this.height,
    required this.frameIndex,
    required this.rgbaLength,
  });

  final int width;
  final int height;
  final int frameIndex;
  final int rgbaLength;
}

class ReferenceFrameDescriptor extends ReferenceFrameHeader {
  const ReferenceFrameDescriptor({
    required super.width,
    required super.height,
    required super.frameIndex,
    required super.rgbaLength,
    required this.rgbaRange,
  });

  final ByteRange rgbaRange;
}

class SampleDigestInputV01 {
  const SampleDigestInputV01({required this.rendition, required this.sha256});

  final Id rendition;
  final Sha256Hex sha256;
}

/// TS `UnitInputOf<TKind>`: the writer-facing counterpart of [UnitV01] with
/// `samples: readonly SampleDigestInputV01[]` instead of `SampleSpanV01[]`.
sealed class UnitInputV01 {
  const UnitInputV01({
    required this.id,
    required this.kind,
    required this.frameCount,
    required this.samples,
  });

  final Id id;
  final String kind;
  final int frameCount;
  final List<SampleDigestInputV01> samples;
}

class BodyUnitInputV01 extends UnitInputV01 {
  const BodyUnitInputV01({
    required super.id,
    required super.frameCount,
    required super.samples,
    required this.playback,
    required this.ports,
  }) : super(kind: 'body');

  final String playback;
  final List<PortV01> ports;
}

class BridgeUnitInputV01 extends UnitInputV01 {
  const BridgeUnitInputV01({
    required super.id,
    required super.frameCount,
    required super.samples,
  }) : super(kind: 'bridge');
}

class ReversibleUnitInputV01 extends UnitInputV01 {
  const ReversibleUnitInputV01({
    required super.id,
    required super.frameCount,
    required super.samples,
    required this.residency,
  }) : super(kind: 'reversible');

  final ReversibleResidencyV01 residency;
}

class OneShotUnitInputV01 extends UnitInputV01 {
  const OneShotUnitInputV01({
    required super.id,
    required super.frameCount,
    required super.samples,
  }) : super(kind: 'one-shot');
}

class CompiledManifestInputV01 {
  const CompiledManifestInputV01({
    required this.generator,
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

  String get formatVersion => '0.1';
  final String generator;
  final CanvasV01 canvas;
  final RationalV01 frameRate;
  final List<RenditionV01> renditions;
  final List<UnitInputV01> units;
  final Id initialState;
  final List<StateV01> states;
  final List<EdgeV01> edges;
  final List<BindingV01> bindings;
  final ReadinessV01 readiness;
  final DeclaredLimitsV01 limits;
}

class AccessUnitInputV01 {
  const AccessUnitInputV01({
    required this.rendition,
    required this.unit,
    required this.frameIndex,
    required this.key,
    required this.bytes,
  });

  final Id rendition;
  final Id unit;
  final int frameIndex;
  final bool key;
  final List<int> bytes;
}

class CanonicalAssetInputV01 {
  const CanonicalAssetInputV01({
    required this.manifest,
    required this.accessUnits,
  });

  final CompiledManifestInputV01 manifest;
  final List<AccessUnitInputV01> accessUnits;
}

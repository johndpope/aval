/// Loads grass-rabbit.avl, decodes every unit via the Rust FFI decoder, and
/// drives the aval_graph MotionGraphEngine so the displayed unit follows the
/// graph state.
///
/// Pipeline (proves the Phase 3 exit criterion — the Dart<->Rust FFI
/// round-trip): asset bytes -> aval_format.parseFrontIndex (header + manifest +
/// access-unit index) -> per unit, extract each access unit's Annex-B bytes ->
/// aval_decode (FFI) -> RGBA -> ui.Image. The parsed graph is installed into a
/// MotionGraphEngine; [currentUnitId] maps the graph's visual state onto the
/// unit whose frames should be on screen (an approximation of Phase 7-8
/// scheduling — see README).
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:aval_format/aval_format.dart';
import 'package:aval_graph/aval_graph.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'aval_ffi.dart';

/// Resolved path to the aval_decode shared library. Set by
/// `--dart-define=AVAL_DECODE_LIB=<abs path>` (see scripts/run.sh); otherwise
/// falls back to the default cargo release artifact relative to the example dir.
const String _libDefine = String.fromEnvironment('AVAL_DECODE_LIB');
const String _libFallback =
    '../../rust/aval_decode/target/release/libaval_decode.dylib';

String get avalDecodeLibPath => _libDefine.isNotEmpty ? _libDefine : _libFallback;

class RabbitController extends ChangeNotifier {
  /// Decoded frames per unit id (e.g. `idle-loop`, `hover-in`, ...).
  final Map<String, List<ui.Image>> unitFrames = <String, List<ui.Image>>{};

  final MotionGraphEngine engine = MotionGraphEngine();
  ValidatedMotionGraph? _graph;

  bool loaded = false;
  Object? error;

  int canvasWidth = 1280;
  int canvasHeight = 720;
  int frameRateNumerator = 24;
  int frameRateDenominator = 1;

  BigInt _contentOrdinal = BigInt.zero;

  /// Maps a graph *state* to the *unit* whose frames represent it.
  static const Map<String, String> unitForState = <String, String>{
    'idle': 'idle-loop',
    'hi': 'hi',
    'great': 'great',
  };

  /// Units that loop (others play once and hold their last frame).
  static const Set<String> loopUnitIds = <String>{'idle-loop'};

  /// The graph state names, in manifest order.
  List<String> get stateNames =>
      _graph?.definition.states.map((s) => s.id).toList() ?? const <String>[];

  /// The state currently being presented (updates when a transition commits).
  String get visualState {
    final snap = engine.snapshot();
    if (snap.presentation is GraphPresentationIntro) return 'intro';
    return snap.visualState ?? _graph?.definition.initialState ?? '';
  }

  /// The state the graph is heading toward (updates immediately on a hover
  /// event, before the transition commits).
  String get requestedState {
    final snap = engine.snapshot();
    return snap.requestedState ?? visualState;
  }

  bool get isTransitioning => engine.snapshot().isTransitioning;

  int get totalFrames =>
      unitFrames.values.fold(0, (sum, list) => sum + list.length);

  /// The unit the graph says should be on screen right now: `intro` while the
  /// idle state's one-shot plays, then the body unit for the current state.
  String currentUnitId() {
    final snap = engine.snapshot();
    if (snap.presentation is GraphPresentationIntro) return 'intro';
    final vs = snap.visualState ?? _graph?.definition.initialState ?? 'idle';
    return unitForState[vs] ?? vs;
  }

  bool isLoopUnit(String unitId) => loopUnitIds.contains(unitId);

  /// Resolves a unit-local frame counter to a real frame index: loop units wrap;
  /// finite units clamp to (and hold) the last frame.
  int frameIndexInUnit(String unitId, int localFrame) {
    final frames = unitFrames[unitId];
    if (frames == null || frames.isEmpty) return 0;
    if (isLoopUnit(unitId)) return localFrame % frames.length;
    return localFrame >= frames.length ? frames.length - 1 : localFrame;
  }

  ui.Image? imageFor(String unitId, int localFrame) {
    final frames = unitFrames[unitId];
    if (frames == null || frames.isEmpty) return null;
    return frames[frameIndexInUnit(unitId, localFrame)];
  }

  Future<void> load() async {
    try {
      final data = await rootBundle.load('assets/mansion-woman.avl/h264.avl');
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

      final parsed = parseFrontIndex(bytes);
      final manifest = parsed.manifest;
      canvasWidth = manifest.canvas.width;
      canvasHeight = manifest.canvas.height;
      frameRateNumerator = manifest.frameRate.numerator;
      frameRateDenominator = manifest.frameRate.denominator;

      // openh264 yields the SPS-cropped visible picture (colorRect), not the
      // macroblock-aligned coded surface (e.g. 640x360 vs 640x368). Configure
      // against the visible size so geometry validation matches decoder output.
      final rendition = manifest.renditions.first;
      final visible = rendition.alphaLayout.colorRect;
      await _decodeAllUnits(
          bytes, manifest, parsed.records, visible.width, visible.height);

      _graph = parsed.graph;
      engine.install(parsed.graph);
      engine.beginAnimated();

      loaded = true;
      notifyListeners();
    } catch (e, st) {
      error = e;
      debugPrint('[rabbit] load failed: $e\n$st');
      notifyListeners();
    }
  }

  Future<void> _decodeAllUnits(
    Uint8List bytes,
    CompiledManifest manifest,
    List<EncodedChunkRecord> records,
    int codedWidth,
    int codedHeight,
  ) async {
    debugPrint('[rabbit] opening dylib: $avalDecodeLibPath');
    final bindings = AvalDecodeBindings.open(avalDecodeLibPath);

    // Format 1.0: each unit embeds its own chunk spans (rendition id + chunk
    // start/count) referencing the flat global decode-order `records` list.
    // Each unit is a closed GOP whose first chunk is a self-contained IDR.
    for (final unit in manifest.units) {
      if (unit.chunks.isEmpty) continue;
      // Use the first rendition span (single-rendition assets for now).
      final span = unit.chunks.first;
      final unitRecords = <EncodedChunkRecord>[];
      for (var c = 0; c < span.chunkCount; c++) {
        final idx = span.chunkStart + c;
        if (idx < 0 || idx >= records.length) break;
        unitRecords.add(records[idx]);
      }
      if (unitRecords.isEmpty) continue;
      if (!unitRecords.first.randomAccess) {
        throw StateError('unit ${unit.id} first chunk is not a key frame');
      }

      final frames = unitFrames.putIfAbsent(unit.id, () => <ui.Image>[]);
      final session = AvalDecoderSession.create(bindings);
      try {
        session.configure(codedWidth: codedWidth, codedHeight: codedHeight);
        session.activateGeneration(1);
        for (var i = 0; i < unitRecords.length; i++) {
          final record = unitRecords[i];
          final annexB = Uint8List.sublistView(
            bytes,
            record.byteOffset,
            record.byteOffset + record.byteLength,
          );
          // presentationTimestamp is the unit-local display index (B-frame reorder).
          final presentationIndex = record.presentationTimestamp;
          final frameId = session.submit(
            decodeIndex: i,
            unitChunkCount: unitRecords.length,
            unitFrameCount: unit.frameCount,
            presentationTimestamp: presentationIndex,
            duration: record.duration == 0 ? 1 : record.duration,
            randomAccess: record.randomAccess,
            data: annexB,
            unitId: unit.id,
            presentationIndices: <int>[presentationIndex],
            presentationOrdinalBase: 0,
            displayedFrameCount: record.displayedFrameCount == 0
                ? 1
                : record.displayedFrameCount,
          );
          if (frameId == null) continue; // decoder priming (not expected here)
          final image = session.takeFrame<Future<ui.Image>>(
            (view) => _rgbaToImage(
              Uint8List.fromList(view.rgba),
              view.width,
              view.height,
            ),
          );
          if (image == null) continue;
          frames.add(await image);
        }
      } finally {
        session.disposeSession();
      }
      debugPrint('[rabbit] decoded unit "${unit.id}": '
          '${frames.length}/${unitRecords.length} frames');
    }

    if (totalFrames == 0) throw StateError('no frames decoded');
    debugPrint('[rabbit] total frames: $totalFrames across '
        '${unitFrames.length} units');
  }

  static Future<ui.Image> _rgbaToImage(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  /// Advances the graph by exactly one authored frame. Called at the manifest
  /// frame rate.
  void tickGraph() {
    if (!loaded) return;
    engine.tick(MotionGraphTickOptions(contentOrdinal: _contentOrdinal));
    _contentOrdinal += BigInt.one;
  }

  /// engagement.on → "hi" event (mansion-woman binding).
  void onEngagementOn() {
    if (loaded) engine.send('hi');
  }

  /// engagement.off — no binding in mansion-woman; hi completes back to idle.
  void onEngagementOff() {
    // The hi→idle edge is completion-triggered, so nothing to send here.
  }

  /// activate → "great" event (mansion-woman binding).
  void onActivate() {
    if (loaded) engine.send('great');
  }

  @override
  void dispose() {
    for (final list in unitFrames.values) {
      for (final img in list) {
        img.dispose();
      }
    }
    unitFrames.clear();
    super.dispose();
  }
}

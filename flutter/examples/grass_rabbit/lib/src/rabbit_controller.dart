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
    'entering': 'hover-in',
    'hover': 'hover-loop',
    'exiting': 'hover-out',
  };

  /// Units that loop (others play once and hold their last frame).
  static const Set<String> loopUnitIds = <String>{'idle-loop', 'hover-loop'};

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
    return unitForState[vs] ?? 'idle-loop';
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
      final data = await rootBundle.load('assets/grass-rabbit.avl');
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

      final parsed = parseFrontIndex(bytes);
      final manifest = parsed.manifest;
      canvasWidth = manifest.canvas.width;
      canvasHeight = manifest.canvas.height;
      frameRateNumerator = manifest.frameRate.numerator;
      frameRateDenominator = manifest.frameRate.denominator;

      // Coded surface dims come from the rendition (this asset is opaque AVC,
      // 1280x720 — no packed-alpha pane to unpack; see README).
      final rendition = manifest.renditions.first;
      await _decodeAllUnits(
          bytes, manifest, parsed.records, rendition.codedWidth, rendition.codedHeight);

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
    CompiledManifestV01 manifest,
    List<AccessUnitRecord> records,
    int codedWidth,
    int codedHeight,
  ) async {
    debugPrint('[rabbit] opening dylib: $avalDecodeLibPath');
    final bindings = AvalDecodeBindings.open(avalDecodeLibPath);

    // Each unit is a closed GOP whose first access unit is a self-contained
    // IDR (verified: record.key on every unit's frame 0). Decode each unit in
    // its own session for a clean decoder reset between units.
    for (var u = 0; u < manifest.units.length; u++) {
      final unit = manifest.units[u];
      final unitRecords = records
          .where((r) => r.unitIndex == u && r.renditionIndex == 0)
          .toList()
        ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));
      if (unitRecords.isEmpty) continue;
      if (!unitRecords.first.key) {
        throw StateError('unit ${unit.id} first access unit is not a key frame');
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
            record.payloadOffset,
            record.payloadOffset + record.payloadLength,
          );
          final frameId = session.submit(
            ordinal: i,
            timestamp: i, // strictly increasing; units are arbitrary here
            duration: 1,
            unitFrame: i,
            unitFrameCount: unit.frameCount,
            isKey: record.key,
            data: annexB,
            unitId: unit.id,
          );
          if (frameId == null) continue; // decoder priming (not expected here)
          final copy = session.takeFrame<Uint8List>(
            (view) => Uint8List.fromList(view.rgba),
          );
          if (copy == null) continue;
          frames.add(await _rgbaToImage(copy, codedWidth, codedHeight));
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

  void onHoverEnter() {
    if (loaded) engine.send('hover.enter');
  }

  void onHoverLeave() {
    if (loaded) engine.send('hover.leave');
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

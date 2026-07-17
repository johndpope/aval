/// Loads mansion-woman.avl, lazily decodes units via the Rust FFI decoder, and
/// drives the aval_graph MotionGraphEngine so the displayed unit follows the
/// graph state.
///
/// High-res (1280×720) RGBA is ~3.7 MiB/frame — keeping all units decoded at
/// once OOMs on desktop. Only the active unit is retained; others are decoded
/// on demand and previous units are evicted.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:aval_format/aval_format.dart';
import 'package:aval_graph/aval_graph.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'aval_ffi.dart';

/// Resolved path to the aval_decode shared library. Set by
/// `--dart-define=AVAL_DECODE_LIB=<abs path>` (see scripts/run.sh); otherwise
/// falls back to the default cargo release artifact relative to the example dir.
///
/// On iOS the crate is statically linked into the Runner binary (see
/// `ios/Flutter/*AvalDecode.xcconfig`); [avalDecodeUseProcess] is true and the
/// path is unused.
const String _libDefine = String.fromEnvironment('AVAL_DECODE_LIB');
const bool avalDecodeUseProcess =
    bool.fromEnvironment('AVAL_DECODE_USE_PROCESS', defaultValue: false);
const String _libFallback =
    '../../rust/aval_decode/target/release/libaval_decode.dylib';

String get avalDecodeLibPath => _libDefine.isNotEmpty ? _libDefine : _libFallback;

/// Opens the native decoder: process lookup on iOS (static link), else dylib path.
AvalDecodeBindings openAvalDecodeBindings() {
  if (avalDecodeUseProcess || Platform.isIOS) {
    debugPrint('[rabbit] opening aval_decode via DynamicLibrary.process()');
    return AvalDecodeBindings.openProcess();
  }
  debugPrint('[rabbit] opening dylib: $avalDecodeLibPath');
  return AvalDecodeBindings.open(avalDecodeLibPath);
}

class RabbitController extends ChangeNotifier {
  /// Decoded frames per unit id currently held in RAM.
  final Map<String, List<ui.Image>> unitFrames = <String, List<ui.Image>>{};

  final MotionGraphEngine engine = MotionGraphEngine();
  ValidatedMotionGraph? _graph;

  bool loaded = false;
  Object? error;

  int canvasWidth = 1280;
  int canvasHeight = 720;
  int frameRateNumerator = 24;
  int frameRateDenominator = 1;

  int codedWidth = 1280;
  int codedHeight = 720;

  BigInt _contentOrdinal = BigInt.zero;

  Uint8List? _assetBytes;
  CompiledManifest? _manifest;
  List<EncodedChunkRecord>? _records;
  AvalDecodeBindings? _bindings;
  final Map<String, Future<void>> _decodeInFlight = <String, Future<void>>{};

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

  /// Authoring frame count for a unit (from the manifest), even if not decoded.
  int authoredFrameCount(String unitId) {
    final unit = _manifest?.units.where((u) => u.id == unitId).firstOrNull;
    return unit?.frameCount ?? 0;
  }

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

  /// Whether [unitId] currently has decoded frames ready to paint.
  bool isUnitReady(String unitId) {
    final id = unitId == 'intro' ? (unitForState['idle'] ?? 'idle-loop') : unitId;
    return unitFrames[id]?.isNotEmpty == true;
  }

  /// Ensures [unitId] is decoded. Other units stay in memory until this unit is
  /// ready, then they are evicted — avoids a black gap during the ~1s decode.
  Future<void> ensureUnitDecoded(String unitId) {
    if (unitId.isEmpty || unitId == 'intro') {
      // Map intro → idle-loop body if that is what we display.
      return ensureUnitDecoded(unitForState['idle'] ?? 'idle-loop');
    }
    if (unitFrames[unitId]?.isNotEmpty == true) {
      // Already cached — free anything else so we do not hold 2 full units.
      _evictUnitsExcept(unitId);
      return Future<void>.value();
    }
    return _decodeInFlight.putIfAbsent(unitId, () async {
      try {
        // Decode first with the previous unit still resident so the UI can hold
        // its last frame; only then evict.
        await _decodeUnit(unitId, evictOthers: false);
        _evictUnitsExcept(unitId);
      } finally {
        _decodeInFlight.remove(unitId);
      }
    });
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

      // Visible surface (matches openh264 output after SPS crop when present).
      final rendition = manifest.renditions.first;
      final visible = rendition.alphaLayout.colorRect;
      codedWidth = visible.width;
      codedHeight = visible.height;

      _assetBytes = bytes;
      _manifest = manifest;
      _records = parsed.records;
      _bindings = openAvalDecodeBindings();

      _graph = parsed.graph;
      engine.install(parsed.graph);
      engine.beginAnimated();

      // Decode only the initial unit so startup stays under RAM budget.
      final initial = currentUnitId();
      await ensureUnitDecoded(initial);

      loaded = true;
      notifyListeners();
      debugPrint(
        '[rabbit] ready: canvas ${canvasWidth}x$canvasHeight, '
        'coded ${codedWidth}x$codedHeight, unit "$initial" '
        '${unitFrames[initial]?.length ?? 0} frames',
      );
    } catch (e, st) {
      error = e;
      debugPrint('[rabbit] load failed: $e\n$st');
      notifyListeners();
    }
  }

  Future<void> _decodeUnit(String unitId, {required bool evictOthers}) async {
    final bytes = _assetBytes;
    final manifest = _manifest;
    final records = _records;
    final bindings = _bindings;
    if (bytes == null ||
        manifest == null ||
        records == null ||
        bindings == null) {
      throw StateError('decode before load completed');
    }

    final unit = manifest.units.where((u) => u.id == unitId).firstOrNull;
    if (unit == null || unit.chunks.isEmpty) {
      debugPrint('[rabbit] unknown/empty unit "$unitId"');
      return;
    }

    if (evictOthers) {
      _evictUnitsExcept(unitId);
    }

    final span = unit.chunks.first;
    final unitRecords = <EncodedChunkRecord>[];
    for (var c = 0; c < span.chunkCount; c++) {
      final idx = span.chunkStart + c;
      if (idx < 0 || idx >= records.length) break;
      unitRecords.add(records[idx]);
    }
    if (unitRecords.isEmpty) return;
    if (!unitRecords.first.randomAccess) {
      throw StateError('unit $unitId first chunk is not a key frame');
    }

    // Slot frames by presentation index so B-frame decode order still paints
    // in display order.
    final byPresentation = <int, ui.Image>{};
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
        if (frameId == null) continue;
        final image = session.takeFrame<Future<ui.Image>>(
          (view) => _rgbaToImage(
            Uint8List.fromList(view.rgba),
            view.width,
            view.height,
          ),
        );
        if (image == null) continue;
        final img = await image;
        // Prefer the decoder's unit_frame when available; fall back to PTS.
        byPresentation[presentationIndex] = img;
      }
      // Drain any frames still queued after the last submit (B-frame tail).
      while (true) {
        final image = session.takeFrame<Future<ui.Image>>(
          (view) => _rgbaToImage(
            Uint8List.fromList(view.rgba),
            view.width,
            view.height,
          ),
        );
        if (image == null) break;
        final img = await image;
        // Without a presentation index on take, append at next free slot.
        var slot = byPresentation.length;
        while (byPresentation.containsKey(slot)) {
          slot++;
        }
        byPresentation[slot] = img;
      }
    } finally {
      session.disposeSession();
    }

    final ordered = <ui.Image>[];
    final keys = byPresentation.keys.toList()..sort();
    for (final k in keys) {
      ordered.add(byPresentation[k]!);
    }
    unitFrames[unitId] = ordered;
    debugPrint(
      '[rabbit] decoded unit "$unitId": ${ordered.length}/${unitRecords.length} '
      'frames @ ${codedWidth}x$codedHeight',
    );
    notifyListeners();
  }

  void _evictUnitsExcept(String keep) {
    final toRemove =
        unitFrames.keys.where((id) => id != keep).toList(growable: false);
    for (final id in toRemove) {
      final list = unitFrames.remove(id);
      if (list == null) continue;
      for (final img in list) {
        img.dispose();
      }
      debugPrint('[rabbit] evicted unit "$id"');
    }
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

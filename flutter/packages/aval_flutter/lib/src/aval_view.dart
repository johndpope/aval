/// The drop-in AVAL widget — Flutter's equivalent of the web player's
/// `<aval-video>` custom element.
///
/// ```dart
/// AvalView(asset: 'assets/mansion-woman.avl/h264.avl')
/// ```
///
/// Owns the presentation clock (a [Ticker] gated to the manifest frame rate),
/// paints decoded frames through the GPU fragment-shader compositor (CPU
/// fallback while the program loads), and translates Flutter gestures into
/// the manifest's input-binding sources the same way the DOM element
/// translates pointer/focus events:
///
/// - tap → `activate`
/// - mouse enter/leave → `pointer.enter`/`pointer.leave` +
///   `engagement.on`/`engagement.off`
/// - long-press → `engagement.on` (touch stand-in for hover)
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'aval_player_controller.dart';
import 'frame_painter.dart';

class AvalView extends StatefulWidget {
  const AvalView({
    super.key,
    this.asset,
    this.controller,
    this.fit = BoxFit.contain,
    this.interactive = true,
    this.onUnitChanged,
    this.onDoubleTap,
    this.loadingBuilder,
    this.errorBuilder,
  }) : assert(asset != null || controller != null,
            'AvalView needs an asset key or a pre-loaded controller');

  /// Root-bundle key of the `.avl` to load (when [controller] is null or
  /// not yet loaded).
  final String? asset;

  /// External controller, for apps that want to read graph state or send
  /// events. When null, the view creates and owns one internally.
  final AvalPlayerController? controller;

  final BoxFit fit;

  /// Wire gestures to the manifest's input bindings. Disable to drive the
  /// graph purely via [controller].
  final bool interactive;

  /// Fires when the displayed unit switches (including the first unit),
  /// e.g. to run side-band audio in lockstep.
  final void Function(String unitId, bool looping)? onUnitChanged;

  /// Optional double-tap passthrough (e.g. reset a surrounding zoom). Kept
  /// separate from `activate` so double-tap does not fire the graph event.
  final VoidCallback? onDoubleTap;

  final WidgetBuilder? loadingBuilder;
  final Widget Function(BuildContext, Object error)? errorBuilder;

  @override
  State<AvalView> createState() => _AvalViewState();
}

class _AvalViewState extends State<AvalView>
    with SingleTickerProviderStateMixin {
  late final AvalPlayerController _controller;
  late final bool _ownsController;
  late final Ticker _ticker;

  final ValueNotifier<ui.Image?> _displayImage = ValueNotifier(null);
  ui.FragmentProgram? _frameProgram;

  String _currentUnit = '';
  int _unitLocalFrame = 0;
  Duration? _lastTick;
  double _accumulatedMicros = 0;

  /// After a unit switch, hold the previous paint until the new unit is
  /// ready, then show its first frame once before advancing.
  bool _awaitingFirstFrame = false;
  bool _hovering = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? AvalPlayerController();
    _ownsController = widget.controller == null;
    _ticker = createTicker(_onTick);
    _controller.addListener(_onControllerChanged);
    loadFramePaintProgram().then((program) {
      if (!mounted) return;
      setState(() => _frameProgram = program);
    }).catchError((Object e) {
      debugPrint('[aval] fragment program load failed, CPU fallback: $e');
    });
    if (_controller.loaded) {
      _start();
    } else if (widget.asset != null) {
      _controller.loadAsset(widget.asset!).then((_) {
        if (mounted && _controller.loaded) _start();
      });
    }
  }

  void _start() {
    _currentUnit = _controller.currentUnitId();
    _displayImage.value = _controller.imageFor(_currentUnit, 0);
    _notifyUnitChanged(_currentUnit);
    if (!_ticker.isActive) _ticker.start();
    setState(() {});
  }

  /// User callbacks must not be able to kill the presentation clock.
  void _notifyUnitChanged(String unitId) {
    try {
      widget.onUnitChanged?.call(unitId, _controller.isLoopUnit(unitId));
    } catch (e, st) {
      debugPrint('[aval] onUnitChanged threw: $e\n$st');
    }
  }

  void _onControllerChanged() {
    // Load completion / decode progress / errors all arrive here.
    if (!mounted) return;
    setState(() {});
  }

  void _onTick(Duration elapsed) {
    if (!_controller.loaded || _controller.totalFrames == 0) return;
    final last = _lastTick;
    _lastTick = elapsed;
    if (last == null) return;

    // Gate the display/graph clock to the manifest frame rate rather than
    // the display refresh rate.
    final frameMicros = 1e6 *
        _controller.frameRateDenominator /
        _controller.frameRateNumerator;
    _accumulatedMicros += (elapsed - last).inMicroseconds;
    while (_accumulatedMicros >= frameMicros) {
      _accumulatedMicros -= frameMicros;
      // Graph: advance one authored frame so completion/portal boundaries
      // fire.
      _controller.tickGraph();
      // Video: follow the graph. When the graph's unit changes, restart the
      // unit-local frame counter.
      final unit = _controller.currentUnitId();
      if (unit != _currentUnit) {
        _currentUnit = unit;
        _unitLocalFrame = 0;
        _awaitingFirstFrame = true;
        _notifyUnitChanged(unit);
        // High-res units are decoded on demand; keep painting the previous
        // frame until the new unit has frames (no black flash).
        unawaited(_controller.ensureUnitDecoded(unit));
      } else if (_controller.isUnitReady(unit) && !_awaitingFirstFrame) {
        _unitLocalFrame++;
      }
      // Only advance the painted frame when the unit is ready; otherwise
      // hold whatever is currently on screen (last frame of previous unit).
      final next = _controller.imageFor(unit, _unitLocalFrame);
      if (next != null) {
        _displayImage.value = next;
        _awaitingFirstFrame = false;
      }
    }
  }

  void _setHover(bool hovering) {
    if (_hovering == hovering) return;
    _hovering = hovering;
    _controller.sendSource(hovering ? 'pointer.enter' : 'pointer.leave');
    _controller.sendSource(hovering ? 'engagement.on' : 'engagement.off');
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _ticker.dispose();
    _displayImage.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _controller.error;
    if (error != null) {
      return widget.errorBuilder?.call(context, error) ??
          Center(
            child: Text(
              'AVAL load failed: $error\n(${_controller.decoderDescription})',
              textAlign: TextAlign.center,
            ),
          );
    }
    if (!_controller.loaded) {
      return widget.loadingBuilder?.call(context) ??
          const Center(child: CircularProgressIndicator());
    }

    Widget surface = RepaintBoundary(
      child: CustomPaint(
        painter: _frameProgram != null
            ? GpuFramePainter(
                image: _displayImage,
                program: _frameProgram!,
                fit: widget.fit,
              )
            : CpuFramePainter(image: _displayImage, fit: widget.fit),
        // Video repaints every frame, so the layer must never be
        // raster-cached. Without this, an ancestor Transform (pan/zoom)
        // triggers the raster cache to reuse a frozen snapshot of the video.
        willChange: true,
        child: const SizedBox.expand(),
      ),
    );

    if (!widget.interactive && widget.onDoubleTap == null) return surface;
    return MouseRegion(
      onEnter: widget.interactive ? (_) => _setHover(true) : null,
      onExit: widget.interactive ? (_) => _setHover(false) : null,
      child: GestureDetector(
        // The paint subtree has no hit-testable render objects of its own, so
        // claim the whole surface for gestures.
        behavior: HitTestBehavior.opaque,
        onTap: widget.interactive
            ? () => _controller.sendSource('activate')
            : null,
        // Touch has no hover: long-press stands in for engagement.on.
        onLongPress: widget.interactive
            ? () => _controller.sendSource('engagement.on')
            : null,
        onDoubleTap: widget.onDoubleTap,
        child: surface,
      ),
    );
  }
}

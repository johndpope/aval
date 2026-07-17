/// Drop-in Flutter widget for AVAL interactive video.
///
/// The Flutter equivalent of the web player's `<aval-video>` custom element:
///
/// ```dart
/// AvalView(asset: 'assets/my-character.avl/h264.avl')
/// ```
library;

export 'src/aval_player_controller.dart' show AvalPlayerController;
export 'src/aval_view.dart' show AvalView;
export 'src/decode/unit_decoder.dart' show unitDecoderDescription;
export 'src/frame_painter.dart'
    show CpuFramePainter, GpuFramePainter, loadFramePaintProgram;

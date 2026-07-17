/// Hand-written `dart:ffi` bindings for the `aval_decode` Rust C ABI.
///
/// Mirrors `flutter/rust/aval_decode/src/ffi.rs` exactly. No code generation
/// and no `flutter_rust_bridge` — plain `dart:ffi` keeps this example
/// dependency-free (only `package:ffi` for `malloc`).
///
/// Frame ownership (see ffi.rs module docs): a decoded frame's RGBA bytes stay
/// owned by the Rust session between `takeFrame` and `releaseFrame`. This
/// example copies each frame into a `ui.Image` and releases it synchronously,
/// so the native buffer never outlives the copy. The `NativeFinalizer` here is
/// wired to `aval_decode_session_destroy` (a single-pointer C signature that
/// matches the `NativeFinalizerFunction` ABI exactly) as a GC-safe backstop for
/// the *session* handle; per-frame `aval_decode_release_frame` takes two
/// arguments (handle + frame_id) and so cannot itself be a `NativeFinalizer`
/// callback — it is called manually right after each copy instead.
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// AvalDecodeStatus (error.rs) — repr(C) enum, C int (4 bytes).
// ---------------------------------------------------------------------------
const int statusOk = 0;
const int statusNullPointer = 1;
const int statusInvalidArgument = 2;
const int statusDecodeFailed = 3;
const int statusNoFrameAvailable = 4;
const int statusDecodedByteBudgetExceeded = 5;
const int statusDecoderOutputInvalid = 6;
const int statusFrameReleaseInvalid = 7;
const int statusPanicked = 8;
const int statusUnsupported = 9;

String statusName(int status) => switch (status) {
      statusOk => 'ok',
      statusNullPointer => 'null pointer',
      statusInvalidArgument => 'invalid argument',
      statusDecodeFailed => 'decode failed',
      statusNoFrameAvailable => 'no frame available',
      statusDecodedByteBudgetExceeded => 'decoded byte budget exceeded',
      statusDecoderOutputInvalid => 'decoder output invalid',
      statusFrameReleaseInvalid => 'frame release invalid',
      statusPanicked => 'panicked at FFI boundary',
      statusUnsupported => 'unsupported codec configuration',
      _ => 'unknown status $status',
    };

// ---------------------------------------------------------------------------
// #[repr(C)] structs (ffi.rs). Dart inserts the same field padding as Rust
// repr(C) on a 64-bit target, so the layouts match byte-for-byte.
// ---------------------------------------------------------------------------

/// Mirrors `AvalDecodeConfig`.
final class AvalDecodeConfig extends ffi.Struct {
  /// Codec family (`0=h264, 1=h265, 2=vp9, 3=av1`). Only `0` configures.
  @ffi.Uint32()
  external int codec;
  /// Luma bit depth (must be `8` for H.264).
  @ffi.Uint32()
  external int bitDepth;
  @ffi.Uint32()
  external int codedWidth;
  @ffi.Uint32()
  external int codedHeight;
  @ffi.Uint32()
  external int maxOutstandingFrames;
  @ffi.Uint64()
  external int maxDecodedBytes;
}

/// Mirrors `AvalDecodeChunk` (format-1.0 wire `DecoderWorkerSample`).
final class AvalDecodeChunk extends ffi.Struct {
  @ffi.Uint64()
  external int unitInstance;
  @ffi.Uint64()
  external int decodeIndex;
  @ffi.Uint64()
  external int unitChunkCount;
  @ffi.Uint64()
  external int unitFrameCount;
  @ffi.Uint64()
  external int presentationOrdinalBase;
  @ffi.Uint64()
  external int presentationTimestamp;
  @ffi.Uint64()
  external int duration;
  @ffi.Uint64()
  external int displayedFrameCount;
  @ffi.Uint8()
  external int randomAccess;
  external ffi.Pointer<ffi.Uint8> data;
  @ffi.IntPtr()
  external int dataLen;
  external ffi.Pointer<ffi.Uint8> unitId;
  @ffi.IntPtr()
  external int unitIdLen;
  external ffi.Pointer<ffi.Uint64> presentationIndices;
  @ffi.IntPtr()
  external int presentationIndicesLen;
}

/// Mirrors `AvalSubmitResult`.
final class AvalSubmitResult extends ffi.Struct {
  @ffi.Uint8()
  external int producedFrame;
  @ffi.Uint64()
  external int frameId;
}

/// Mirrors `AvalDecodeFrame`.
final class AvalDecodeFrame extends ffi.Struct {
  @ffi.Uint64()
  external int frameId;
  external ffi.Pointer<ffi.Uint8> data;
  @ffi.IntPtr()
  external int len;
  @ffi.Uint32()
  external int width;
  @ffi.Uint32()
  external int height;
  @ffi.Uint64()
  external int ordinal;
  @ffi.Uint64()
  external int timestamp;
  @ffi.Uint64()
  external int duration;
  @ffi.Uint64()
  external int unitInstance;
  @ffi.Uint64()
  external int unitFrame;
  @ffi.Uint64()
  external int decodeIndex;
}

// ---------------------------------------------------------------------------
// Native function typedefs.
// ---------------------------------------------------------------------------
typedef _CreateNative = ffi.Pointer<ffi.Void> Function();
typedef _DestroyNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _DestroyDart = void Function(ffi.Pointer<ffi.Void>);
typedef _ConfigureNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<AvalDecodeConfig>);
typedef _ConfigureDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<AvalDecodeConfig>);
typedef _GenNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint64);
typedef _GenDart = int Function(ffi.Pointer<ffi.Void>, int);
typedef _SubmitNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint64,
    ffi.Pointer<AvalDecodeChunk>, ffi.Pointer<AvalSubmitResult>);
typedef _SubmitDart = int Function(ffi.Pointer<ffi.Void>, int,
    ffi.Pointer<AvalDecodeChunk>, ffi.Pointer<AvalSubmitResult>);
typedef _TakeNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<AvalDecodeFrame>);
typedef _TakeDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<AvalDecodeFrame>);
typedef _ReleaseNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint64);
typedef _ReleaseDart = int Function(ffi.Pointer<ffi.Void>, int);
typedef _DisposeNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _DisposeDart = int Function(ffi.Pointer<ffi.Void>);

/// Thrown when a native call returns a non-`Ok` status.
class AvalDecodeException implements Exception {
  AvalDecodeException(this.op, this.status);
  final String op;
  final int status;
  @override
  String toString() => 'AvalDecodeException($op -> ${statusName(status)})';
}

/// Loads and binds the `aval_decode` shared library.
class AvalDecodeBindings {
  AvalDecodeBindings._(ffi.DynamicLibrary lib)
      : sessionCreate = lib.lookupFunction<_CreateNative, _CreateNative>(
            'aval_decode_session_create'),
        sessionDestroy = lib.lookupFunction<_DestroyNative, _DestroyDart>(
            'aval_decode_session_destroy'),
        configure = lib.lookupFunction<_ConfigureNative, _ConfigureDart>(
            'aval_decode_configure'),
        activateGeneration = lib.lookupFunction<_GenNative, _GenDart>(
            'aval_decode_activate_generation'),
        submitChunk = lib.lookupFunction<_SubmitNative, _SubmitDart>(
            'aval_decode_submit_chunk'),
        takeFrame =
            lib.lookupFunction<_TakeNative, _TakeDart>('aval_decode_take_frame'),
        releaseFrame = lib.lookupFunction<_ReleaseNative, _ReleaseDart>(
            'aval_decode_release_frame'),
        dispose =
            lib.lookupFunction<_DisposeNative, _DisposeDart>('aval_decode_dispose'),
        destroyPointer = lib.lookup<ffi.NativeFunction<_DestroyNative>>(
            'aval_decode_session_destroy');

  factory AvalDecodeBindings.open(String path) =>
      AvalDecodeBindings._(ffi.DynamicLibrary.open(path));

  /// Looks up symbols in the current process (used when `aval_decode` is
  /// statically linked into the iOS Runner binary via `-force_load`).
  factory AvalDecodeBindings.openProcess() =>
      AvalDecodeBindings._(ffi.DynamicLibrary.process());

  final ffi.Pointer<ffi.Void> Function() sessionCreate;
  final void Function(ffi.Pointer<ffi.Void>) sessionDestroy;
  final int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<AvalDecodeConfig>)
      configure;
  final int Function(ffi.Pointer<ffi.Void>, int) activateGeneration;
  final int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<AvalDecodeChunk>,
      ffi.Pointer<AvalSubmitResult>) submitChunk;
  final int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<AvalDecodeFrame>)
      takeFrame;
  final int Function(ffi.Pointer<ffi.Void>, int) releaseFrame;
  final int Function(ffi.Pointer<ffi.Void>) dispose;

  /// Native function pointer for `aval_decode_session_destroy`, usable as a
  /// [ffi.NativeFinalizer] callback (single-pointer signature).
  final ffi.Pointer<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>
      destroyPointer;
}

/// High-level, safe wrapper around one decoder session.
class AvalDecoderSession implements ffi.Finalizable {
  AvalDecoderSession._(this._bindings, this._handle) {
    _finalizer.attach(this, _handle.cast(), detach: this);
  }

  factory AvalDecoderSession.create(AvalDecodeBindings bindings) {
    final handle = bindings.sessionCreate();
    if (handle == ffi.nullptr) {
      throw StateError('aval_decode_session_create returned null');
    }
    return AvalDecoderSession._(bindings, handle);
  }

  final AvalDecodeBindings _bindings;
  final ffi.Pointer<ffi.Void> _handle;
  bool _destroyed = false;

  late final ffi.NativeFinalizer _finalizer =
      ffi.NativeFinalizer(_bindings.destroyPointer.cast());

  void _check(String op, int status) {
    if (status != statusOk) throw AvalDecodeException(op, status);
  }

  void configure({
    required int codedWidth,
    required int codedHeight,
    int codec = 0, // H.264
    int bitDepth = 8,
    int maxOutstandingFrames = 4,
    int? maxDecodedBytes,
  }) {
    final cfg = calloc<AvalDecodeConfig>();
    try {
      cfg.ref
        ..codec = codec
        ..bitDepth = bitDepth
        ..codedWidth = codedWidth
        ..codedHeight = codedHeight
        ..maxOutstandingFrames = maxOutstandingFrames
        ..maxDecodedBytes =
            maxDecodedBytes ?? codedWidth * codedHeight * 4 * maxOutstandingFrames;
      _check('configure', _bindings.configure(_handle, cfg));
    } finally {
      calloc.free(cfg);
    }
  }

  void activateGeneration(int generation) => _check(
      'activateGeneration', _bindings.activateGeneration(_handle, generation));

  /// Submits one format-1.0 encoded chunk. For H.264, [displayedFrameCount] is
  /// typically 1 and [presentationIndices] is a single index.
  ///
  /// Returns the produced frame id, or null while the decoder is priming.
  int? submit({
    required int decodeIndex,
    required int unitChunkCount,
    required int unitFrameCount,
    required int presentationTimestamp,
    required int duration,
    required bool randomAccess,
    required List<int> data,
    required String unitId,
    required List<int> presentationIndices,
    int unitInstance = 0,
    int presentationOrdinalBase = 0,
    int displayedFrameCount = 1,
    int generation = 1,
  }) {
    if (presentationIndices.length != displayedFrameCount) {
      throw ArgumentError(
          'presentationIndices.length (${presentationIndices.length}) '
          'must equal displayedFrameCount ($displayedFrameCount)');
    }
    final chunk = calloc<AvalDecodeChunk>();
    final dataPtr = calloc<ffi.Uint8>(data.length);
    final unitIdBytes = unitId.codeUnits;
    final unitIdPtr = calloc<ffi.Uint8>(unitIdBytes.length);
    final indicesPtr = displayedFrameCount > 0
        ? calloc<ffi.Uint64>(displayedFrameCount)
        : ffi.nullptr;
    final result = calloc<AvalSubmitResult>();
    try {
      dataPtr.asTypedList(data.length).setAll(0, data);
      unitIdPtr.asTypedList(unitIdBytes.length).setAll(0, unitIdBytes);
      if (displayedFrameCount > 0) {
        final indices = indicesPtr.asTypedList(displayedFrameCount);
        for (var i = 0; i < displayedFrameCount; i++) {
          indices[i] = presentationIndices[i];
        }
      }
      chunk.ref
        ..unitInstance = unitInstance
        ..decodeIndex = decodeIndex
        ..unitChunkCount = unitChunkCount
        ..unitFrameCount = unitFrameCount
        ..presentationOrdinalBase = presentationOrdinalBase
        ..presentationTimestamp = presentationTimestamp
        ..duration = duration
        ..displayedFrameCount = displayedFrameCount
        ..randomAccess = randomAccess ? 1 : 0
        ..data = dataPtr
        ..dataLen = data.length
        ..unitId = unitIdPtr
        ..unitIdLen = unitIdBytes.length
        ..presentationIndices = indicesPtr
        ..presentationIndicesLen = displayedFrameCount;
      _check(
          'submit', _bindings.submitChunk(_handle, generation, chunk, result));
      return result.ref.producedFrame != 0 ? result.ref.frameId : null;
    } finally {
      calloc.free(chunk);
      calloc.free(dataPtr);
      calloc.free(unitIdPtr);
      if (indicesPtr != ffi.nullptr) calloc.free(indicesPtr);
      calloc.free(result);
    }
  }

  /// Takes the next ready frame, invokes [use] with a zero-copy view over the
  /// Rust-owned RGBA bytes, then releases the frame. Returns null if no frame
  /// is queued. The view must not be retained past [use]; copy inside it.
  R? takeFrame<R>(R Function(DecodedFrameView view) use) {
    final out = calloc<AvalDecodeFrame>();
    try {
      final status = _bindings.takeFrame(_handle, out);
      if (status == statusNoFrameAvailable) return null;
      _check('takeFrame', status);
      final f = out.ref;
      final view = DecodedFrameView(
        rgba: f.data.asTypedList(f.len),
        width: f.width,
        height: f.height,
        ordinal: f.ordinal,
        unitFrame: f.unitFrame,
        decodeIndex: f.decodeIndex,
      );
      try {
        return use(view);
      } finally {
        _check('releaseFrame', _bindings.releaseFrame(_handle, f.frameId));
      }
    } finally {
      calloc.free(out);
    }
  }

  void disposeSession() {
    if (_destroyed) return;
    _bindings.dispose(_handle);
    _finalizer.detach(this);
    _bindings.sessionDestroy(_handle);
    _destroyed = true;
  }
}

/// A borrowed view over a Rust-owned decoded frame. Valid only for the duration
/// of the [AvalDecoderSession.takeFrame] callback.
class DecodedFrameView {
  DecodedFrameView({
    required this.rgba,
    required this.width,
    required this.height,
    required this.ordinal,
    required this.unitFrame,
    required this.decodeIndex,
  });

  final List<int> rgba;
  final int width;
  final int height;
  final int ordinal;
  final int unitFrame;
  final int decodeIndex;
}

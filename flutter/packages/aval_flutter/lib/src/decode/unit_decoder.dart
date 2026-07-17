/// Platform-selecting entrypoint for the per-unit frame decoder.
///
/// Native (`dart:ffi` available): the `aval_decode` Rust core.
/// Web (dart2js and dart2wasm): browser WebCodecs `VideoDecoder`.
library;

export 'unit_decoder_types.dart';
export 'unit_decoder_io.dart'
    if (dart.library.js_interop) 'unit_decoder_web.dart'
    show createUnitDecoder, unitDecoderDescription;

//! Codec/backend-generic decode seam (`ARCHITECTURE.md` §2).
//!
//! [`DecoderSession`](crate::decoder::DecoderSession) owns the protocol —
//! frame-credit ledger, generation activation, unit/decode-order continuity,
//! the ready-frame table, metrics, and fatal-failure latching. It does *not*
//! own a codec: the actual "encoded access unit in, owned RGBA picture out"
//! step lives behind the [`DecoderAdapter`] trait so a hardware backend
//! (VideoToolbox on iOS/macOS, MediaCodec on Android — `ARCHITECTURE.md`
//! §2(c), Phase 13/14) can replace the software [`OpenH264Adapter`] without
//! touching the session, the C ABI (`ffi.rs`), or the Dart/shader layers.
//!
//! The trait is deliberately narrow: everything the session needs from a
//! backend is "decode one Annex-B access unit; give me `None` while priming
//! or an owned RGBA8888 [`DecodedRgbaFrame`] when a picture is produced."
//! Geometry validation against the configured coded surface, credit leasing,
//! ordinal/timestamp derivation, and the priming/hidden-chunk rules all stay
//! in the session, so every adapter inherits identical protocol behavior.

use crate::error::AvalDecodeError;

/// A decoded picture converted to owned, tightly-packed RGBA8888 bytes.
///
/// `rgba.len()` is exactly `width * height * 4`; the session cross-checks
/// `width`/`height` against the configured coded surface before accepting it.
pub struct DecodedRgbaFrame {
    /// Decoded picture width in pixels.
    pub width: usize,
    /// Decoded picture height in pixels.
    pub height: usize,
    /// Owned RGBA8888 bytes, row-major, no stride padding.
    pub rgba: Vec<u8>,
}

/// The decode backend behind a [`DecoderSession`](crate::decoder::DecoderSession).
///
/// One access unit in, at most one displayed picture out (AVAL H.264 is
/// Constrained Baseline: decode order equals display order, one chunk yields
/// at most one frame). `Send` so the session — and the `flutter_rust_bridge`
/// worker thread that will host it (§4) — can move a boxed adapter across
/// threads.
pub trait DecoderAdapter: Send {
    /// Decodes one encoded Annex-B access unit.
    ///
    /// Returns `Ok(Some(frame))` when a displayed picture is produced,
    /// `Ok(None)` while the decoder is still priming (no output yet), and
    /// `Err(..)` when the backend rejects the bitstream.
    ///
    /// # Errors
    ///
    /// - [`AvalDecodeError::DecodeFailed`] if the backend rejects the access
    ///   unit.
    /// - [`AvalDecodeError::DecoderOutputInvalid`] if the decoded picture's
    ///   geometry cannot be represented as a valid RGBA buffer.
    fn decode(
        &mut self,
        access_unit: &[u8],
    ) -> Result<Option<DecodedRgbaFrame>, AvalDecodeError>;
}

pub use openh264_adapter::OpenH264Adapter;

#[cfg(target_vendor = "apple")]
pub use videotoolbox_adapter::VideoToolboxAdapter;

/// The default software backend: Cisco's BSD-2-Clause OpenH264 decoder plus
/// this crate's SIMD-free I420→RGBA conversion (`ARCHITECTURE.md` §2(a)/§3.3).
mod openh264_adapter {
    use openh264::decoder::{Decoder, DecoderConfig, Flush};
    use openh264::formats::YUVSource;
    use openh264::OpenH264API;

    use super::{DecodedRgbaFrame, DecoderAdapter};
    use crate::error::AvalDecodeError;
    use crate::yuv;

    /// Wraps a single `openh264` [`Decoder`]. Created once per configured
    /// session; never reconfigured (matching the session's configure-once rule).
    pub struct OpenH264Adapter {
        decoder: Decoder,
    }

    impl OpenH264Adapter {
        /// Creates the openh264 decoder.
        ///
        /// # Errors
        ///
        /// [`AvalDecodeError::DecodeFailed`] if openh264 cannot construct a
        /// decoder (TS `DECODER_CONFIGURE_FAILED`).
        pub fn new() -> Result<Self, AvalDecodeError> {
            // Default openh264 flush-after-decode OOMs (`dsOutOfMemory`) on
            // High-profile streams with B-frames (mansion-woman, etc.): forced
            // flush corrupts the DPB. NoFlush matches DecodeFrameNoDelay usage
            // and leaves reordering to the codec.
            let decoder = Decoder::with_api_config(
                OpenH264API::from_source(),
                DecoderConfig::new().flush_after_decode(Flush::NoFlush),
            )
            .map_err(|error| {
                AvalDecodeError::DecodeFailed(format!(
                    "failed to create openh264 decoder: {error}"
                ))
            })?;
            Ok(Self { decoder })
        }
    }

    impl DecoderAdapter for OpenH264Adapter {
        fn decode(
            &mut self,
            access_unit: &[u8],
        ) -> Result<Option<DecodedRgbaFrame>, AvalDecodeError> {
            match self.decoder.decode(access_unit) {
                Ok(Some(yuv)) => {
                    let (width, height) = yuv.dimensions();
                    let (y_stride, uv_stride, _) = yuv.strides();
                    let len = yuv::rgba_len(width, height)
                        .ok_or(AvalDecodeError::DecoderOutputInvalid)?;
                    let mut rgba = vec![0u8; len];
                    yuv::i420_to_rgba(
                        yuv.y(),
                        yuv.u(),
                        yuv.v(),
                        width,
                        height,
                        y_stride,
                        uv_stride,
                        &mut rgba,
                    )?;
                    Ok(Some(DecodedRgbaFrame { width, height, rgba }))
                }
                Ok(None) => Ok(None),
                Err(error) => Err(AvalDecodeError::DecodeFailed(format!(
                    "openh264 rejected the chunk: {error}"
                ))),
            }
        }
    }
}

/// The hardware backend on Apple platforms: VideoToolbox (`ARCHITECTURE.md`
/// §2(c)). Thin Rust wrapper over the Objective-C decoder in
/// `src/vt/videotoolbox_decoder.m`, compiled into this crate by `build.rs`.
#[cfg(target_vendor = "apple")]
mod videotoolbox_adapter {
    use std::os::raw::{c_int, c_void};

    use super::{DecodedRgbaFrame, DecoderAdapter};
    use crate::error::AvalDecodeError;

    // C ABI from videotoolbox_decoder.m.
    extern "C" {
        fn aval_vt_create() -> *mut c_void;
        fn aval_vt_decode(
            dec: *mut c_void,
            data: *const u8,
            len: usize,
            out_rgba: *mut *mut u8,
            out_len: *mut usize,
            out_width: *mut u32,
            out_height: *mut u32,
        ) -> c_int;
        fn aval_vt_free_frame(rgba: *mut u8);
        fn aval_vt_destroy(dec: *mut c_void);
    }

    /// Owns the opaque VideoToolbox decoder handle for one session.
    pub struct VideoToolboxAdapter {
        handle: *mut c_void,
    }

    // The handle is used only from the session's single owning thread; the
    // adapter never shares it. `Send` mirrors `OpenH264Adapter` so the session
    // can move a boxed adapter to its worker thread (§4).
    unsafe impl Send for VideoToolboxAdapter {}

    impl VideoToolboxAdapter {
        /// Creates the VideoToolbox-backed decoder. The decompression session
        /// itself is created lazily on the first access unit that carries
        /// SPS/PPS, so this only allocates the wrapper.
        ///
        /// # Errors
        ///
        /// [`AvalDecodeError::DecodeFailed`] if the wrapper cannot be allocated.
        pub fn new() -> Result<Self, AvalDecodeError> {
            let handle = unsafe { aval_vt_create() };
            if handle.is_null() {
                return Err(AvalDecodeError::DecodeFailed(
                    "failed to create VideoToolbox decoder".to_string(),
                ));
            }
            Ok(Self { handle })
        }
    }

    impl DecoderAdapter for VideoToolboxAdapter {
        fn decode(
            &mut self,
            access_unit: &[u8],
        ) -> Result<Option<DecodedRgbaFrame>, AvalDecodeError> {
            let mut out_rgba: *mut u8 = std::ptr::null_mut();
            let mut out_len: usize = 0;
            let mut out_width: u32 = 0;
            let mut out_height: u32 = 0;
            let rc = unsafe {
                aval_vt_decode(
                    self.handle,
                    access_unit.as_ptr(),
                    access_unit.len(),
                    &mut out_rgba,
                    &mut out_len,
                    &mut out_width,
                    &mut out_height,
                )
            };
            match rc {
                1 => {
                    if out_rgba.is_null() {
                        return Err(AvalDecodeError::DecoderOutputInvalid);
                    }
                    // Copy the C-owned buffer into an owned Vec, then free it.
                    let rgba =
                        unsafe { std::slice::from_raw_parts(out_rgba, out_len) }
                            .to_vec();
                    unsafe { aval_vt_free_frame(out_rgba) };
                    Ok(Some(DecodedRgbaFrame {
                        width: out_width as usize,
                        height: out_height as usize,
                        rgba,
                    }))
                }
                0 => Ok(None), // Priming.
                _ => Err(AvalDecodeError::DecodeFailed(
                    "VideoToolbox rejected the access unit".to_string(),
                )),
            }
        }
    }

    impl Drop for VideoToolboxAdapter {
        fn drop(&mut self) {
            unsafe { aval_vt_destroy(self.handle) };
        }
    }
}

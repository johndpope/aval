//! AVAL AVC (H.264 Constrained Baseline) decode core for the Flutter port.
//!
//! This crate is a Rust port of the web player's decoder-worker
//! (`packages/player-web/src/decoder-worker/`), wrapping the `openh264` decoder
//! behind a small, protocol-shaped session API and a C ABI suitable for
//! `dart:ffi`. See `flutter/ARCHITECTURE.md` sections 2, 3.3, 4, and 6.
//!
//! Module map (mirrors the TypeScript sources it ports):
//! - [`ledger`]  <- `frame-credit-ledger.ts`  (backpressure / decoded-byte budget;
//!   unchanged across the format-1.0 sync `67c4c0e`)
//! - [`sample_sequence`] <- `sample-sequence.ts` (reworked unit/chunk continuity) +
//!   the structural slice of `core-validation.ts::validateSampleShape`
//! - [`decoder`] <- `core.ts` + `protocol.ts` (configure / submit_chunk /
//!   take_frame / release_frame / snapshot / dispose)
//! - [`yuv`]     <- the new I420 -> RGBA8888 (BT.709 limited-range) conversion
//!   step (ARCHITECTURE.md 3.3, risk register #13)
//! - [`ffi`]     <- the `extern "C"` boundary
//! - [`error`]   <- the shared status/error taxonomy

pub mod decoder;
pub mod error;
pub mod ffi;
pub mod ledger;
pub mod sample_sequence;
pub mod yuv;

pub use decoder::{DecoderSession, SessionConfig, SubmitOutcome, VideoCodec};
pub use error::{AvalDecodeError, AvalDecodeStatus};
pub use ledger::FrameCreditLedger;
pub use sample_sequence::{DecodeChunk, DecoderSampleSequence};

/// JavaScript `Number.MAX_SAFE_INTEGER` (2^53 - 1).
///
/// The web ledger/validation code uses `Number.isSafeInteger` bounds; the Rust
/// port keeps the same numeric ceiling where parity matters (see
/// `frame-credit-ledger.ts` and `core-validation.ts`).
pub const MAX_SAFE_INTEGER: u64 = (1 << 53) - 1;

/// Ported verbatim from `DECODER_WORKER_HARD_LIMITS` (`protocol.ts:10-16`).
///
/// `max_sample_bytes` / `max_decoded_bytes` are `Number.MAX_SAFE_INTEGER` in the
/// TypeScript source; they are represented here with [`MAX_SAFE_INTEGER`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecoderHardLimits {
    /// Maximum native decoder input queue depth.
    pub max_decode_queue_size: usize,
    /// Maximum accepted samples waiting to enter the decoder.
    pub max_pending_samples: usize,
    /// Combined submitted-output and transferred-frame credit ceiling.
    pub max_outstanding_frames: usize,
    /// Maximum accepted encoded access-unit size, in bytes.
    pub max_sample_bytes: u64,
    /// Maximum logical RGBA bytes leased to the caller at once.
    pub max_decoded_bytes: u64,
}

/// The single frozen limits table (`Object.freeze(DECODER_WORKER_HARD_LIMITS)`).
pub const DECODER_WORKER_HARD_LIMITS: DecoderHardLimits = DecoderHardLimits {
    max_decode_queue_size: 12,
    max_pending_samples: 24,
    max_outstanding_frames: 12,
    max_sample_bytes: MAX_SAFE_INTEGER,
    max_decoded_bytes: MAX_SAFE_INTEGER,
};

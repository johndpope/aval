//! Error/status vocabulary shared by the internal session logic and the C ABI.
//!
//! [`AvalDecodeStatus`] is `#[repr(C)]` and is the *only* error representation that crosses the
//! FFI boundary (see `ffi.rs`); every `extern "C"` function returns one. The variants intentionally
//! mirror the `DecoderWorkerErrorCode` values used by
//! `packages/player-web/src/decoder-worker/core-validation.ts` /
//! `frame-credit-ledger.ts` (`DECODED_BYTE_BUDGET_EXCEEDED`, `DECODER_OUTPUT_INVALID`,
//! `FRAME_RELEASE_INVALID`) so a Dart-side error mapping can reuse the same taxonomy the web
//! player already documents.

use std::fmt;

/// Status code returned by every `extern "C"` function in this crate.
///
/// `Ok` (0) means the call did what its name says. Every other value is a non-panicking error
/// result - the crate never aborts the host process for an ordinary decode/ledger error (a Rust
/// panic inside FFI-called code is still caught at the boundary and reported as `Panicked`, see
/// `ffi::catch_ffi`).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AvalDecodeStatus {
    /// The call completed successfully.
    Ok = 0,
    /// A required pointer argument was null.
    NullPointer = 1,
    /// An argument was structurally invalid (e.g. zero-length buffer where data was required).
    InvalidArgument = 2,
    /// The underlying OpenH264 decoder rejected or failed to decode the access unit.
    DecodeFailed = 3,
    /// `take_frame` was called but no decoded frame is currently queued.
    NoFrameAvailable = 4,
    /// Ledger parity with `FrameCreditLedger#lease`'s `DECODED_BYTE_BUDGET_EXCEEDED`: leasing the
    /// newly decoded frame would exceed the session's configured decoded-byte budget. Treat as
    /// fatal for the session, matching the TS ledger's `fatal: true` on this error.
    DecodedByteBudgetExceeded = 5,
    /// Ledger parity with `FrameCreditLedger#lease`'s `DECODER_OUTPUT_INVALID`: the internal
    /// frame-id space was exhausted (practically unreachable, kept for parity).
    DecoderOutputInvalid = 6,
    /// Ledger parity with `FrameCreditLedger#release`/`#revoke`'s `FRAME_RELEASE_INVALID`:
    /// `release_frame` was called with a `frame_id` that is zero, or that does not correspond to
    /// a currently-outstanding lease (including a double release).
    FrameReleaseInvalid = 7,
    /// A Rust panic was caught at the FFI boundary; the session is left in a defined-but-unusable
    /// state and should be destroyed.
    Panicked = 8,
    /// The declared codec configuration is not decodable by this crate. openh264/H.264 is the only
    /// native decoder; H.265/VP9/AV1 are declared-but-rejected at configure time (see
    /// [`AvalDecodeError::Unsupported`] and the `DecoderAdapter` seam in ARCHITECTURE.md §2).
    Unsupported = 9,
}

impl AvalDecodeStatus {
    #[must_use]
    pub const fn is_ok(self) -> bool {
        matches!(self, Self::Ok)
    }
}

impl fmt::Display for AvalDecodeStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            Self::Ok => "ok",
            Self::NullPointer => "null pointer argument",
            Self::InvalidArgument => "invalid argument",
            Self::DecodeFailed => "decode failed",
            Self::NoFrameAvailable => "no frame available",
            Self::DecodedByteBudgetExceeded => "decoded byte budget exceeded",
            Self::DecoderOutputInvalid => "decoder output invalid (frame id space exhausted)",
            Self::FrameReleaseInvalid => "frame release invalid (unknown or already-released frame id)",
            Self::Panicked => "internal panic caught at FFI boundary",
            Self::Unsupported => "unsupported codec configuration (openh264/H.264 only)",
        };
        f.write_str(s)
    }
}

/// Internal (non-FFI) error type used by `ledger.rs` and `decoder.rs`. Every variant carries a
/// direct mapping to an [`AvalDecodeStatus`] via [`AvalDecodeError::status`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AvalDecodeError {
    InvalidArgument(&'static str),
    DecodeFailed(String),
    DecodedByteBudgetExceeded,
    DecoderOutputInvalid,
    FrameReleaseInvalid,
    /// A declared but non-decodable codec configuration. Emitted at configure
    /// time for any `codecFamily` other than H.264 (openh264 is the only native
    /// decoder). Fatal in the TS sense — the session cannot proceed.
    Unsupported(&'static str),
}

impl AvalDecodeError {
    #[must_use]
    pub const fn status(&self) -> AvalDecodeStatus {
        match self {
            Self::InvalidArgument(_) => AvalDecodeStatus::InvalidArgument,
            Self::DecodeFailed(_) => AvalDecodeStatus::DecodeFailed,
            Self::DecodedByteBudgetExceeded => AvalDecodeStatus::DecodedByteBudgetExceeded,
            Self::DecoderOutputInvalid => AvalDecodeStatus::DecoderOutputInvalid,
            Self::FrameReleaseInvalid => AvalDecodeStatus::FrameReleaseInvalid,
            Self::Unsupported(_) => AvalDecodeStatus::Unsupported,
        }
    }

    /// Whether this error is "fatal" in the same sense the TS `DecoderWorkerCoreError.fatal` flag
    /// is: the session should be torn down rather than continued. Kept as a method (rather than
    /// baked into the status enum) so callers that only need the status code don't have to reason
    /// about fatality, mirroring how `core-validation.ts` call sites branch on `.fatal` separately
    /// from `.code`.
    #[must_use]
    pub const fn is_fatal(&self) -> bool {
        matches!(
            self,
            Self::DecodedByteBudgetExceeded
                | Self::DecoderOutputInvalid
                | Self::FrameReleaseInvalid
                | Self::Unsupported(_)
        )
    }
}

impl fmt::Display for AvalDecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidArgument(msg) => write!(f, "invalid argument: {msg}"),
            Self::DecodeFailed(msg) => write!(f, "decode failed: {msg}"),
            Self::DecodedByteBudgetExceeded => {
                write!(f, "decoded output exceeds the session frame-byte budget")
            }
            Self::DecoderOutputInvalid => write!(f, "decoder frame id space was exhausted"),
            Self::FrameReleaseInvalid => write!(
                f,
                "released frame id is not owned by this decoder session, or is not a positive id"
            ),
            Self::Unsupported(msg) => write!(f, "unsupported codec configuration: {msg}"),
        }
    }
}

impl std::error::Error for AvalDecodeError {}

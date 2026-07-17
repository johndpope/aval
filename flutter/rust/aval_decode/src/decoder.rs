//! Protocol-shaped decode session.
//!
//! Ports the command/event vocabulary of
//! `packages/player-web/src/decoder-worker/{core.ts, protocol.ts}` (format 1.0,
//! upstream merge `67c4c0e`) onto the synchronous `openh264` decoder. The
//! `DecoderWorkerCore` class owns a single `VideoDecoder`, gates input with the
//! [`FrameCreditLedger`] and [`DecoderSampleSequence`], and emits
//! frame/ack/error events over a Worker port. Here the same lifecycle is
//! expressed as ordinary methods ([`DecoderSession::configure`],
//! [`DecoderSession::activate_generation`], [`DecoderSession::submit_chunk`],
//! [`DecoderSession::take_frame`], [`DecoderSession::release_frame`],
//! [`DecoderSession::abort_generation`], [`DecoderSession::snapshot`],
//! [`DecoderSession::dispose`]).
//!
//! ## Codec-generic seam, H.264-only native decode
//!
//! Format 1.0 made the worker codec-neutral: [`SessionConfig`] now declares a
//! [`VideoCodec`] family and a bit depth, mirroring `DecoderWorkerVideoProfile`
//! (`protocol.ts:39-46`). This crate keeps the declaration generic but only
//! *decodes* H.264 — [`DecoderSession::configure`] rejects H.265/VP9/AV1 with
//! [`AvalDecodeError::Unsupported`]. The `DecoderAdapter` seam stays codec-generic
//! (ARCHITECTURE.md §2); a future dav1d/libvpx/openh265 crate slots in behind the
//! same session shape.
//!
//! ## Decode-chunk vs displayed-frame distinction
//!
//! A submission is now an encoded **chunk** ([`DecodeChunk`]), not a "sample". A
//! chunk carries `displayed_frame_count` outputs (0 hidden, 1 for H.264, N for a
//! VP9 superframe) each mapped to a `presentation_index` inside its unit. Because
//! AVAL H.264 is Constrained Baseline (no B-frames, one reference, closed GOP),
//! decode order equals display order and one chunk in produces at most one frame
//! out synchronously, so the async event pump / dequeue-callback machinery
//! collapses away. The session API carries the general chunk shape regardless so
//! the Dart caller matches the web protocol; a chunk asserting more than one
//! displayed frame is rejected as [`AvalDecodeError::Unsupported`] (openh264 is
//! strictly 1:1).
//!
//! What is faithfully preserved from `core.ts`:
//! - configure-once semantics (`ALREADY_CONFIGURED`),
//! - the exact derived decoded-byte budget rule (`validateConfiguration`),
//! - monotonic generation activation and generation-scoped submit,
//! - the outstanding-frame credit gate before accepting a submission
//!   (now denominated in displayed frames, TS `sumDisplayedFrames`),
//! - chunk unit/decode-index continuity via [`DecoderSampleSequence`],
//! - the frame-credit lease/release lifecycle across the boundary,
//! - the metrics snapshot vocabulary (`DecoderWorkerMetrics`),
//! - fatal-failure latching (a fatal error tears the session down; further calls
//!   report it), mirroring `#fail`.
//!
//! What is intentionally *not* ported (WebCodecs/Worker-only, see the report):
//! the async support probe / `probe-config`, `decodeQueueSize`/dequeue callbacks,
//! request-id monotonicity, boundary-flush plumbing (`flushCalls`), `VideoFrame`
//! transfer, and the WebCodecs colour-space echo checks in `core-validation.ts`
//! (`avc1.*` codec parsing and level-limit math live in `aval_format`, not this
//! crate — ARCHITECTURE.md §6).

use std::collections::{HashMap, VecDeque};

use openh264::decoder::Decoder;
use openh264::formats::YUVSource;

use crate::error::AvalDecodeError;
use crate::ledger::FrameCreditLedger;
use crate::sample_sequence::{expected_timestamp, DecodeChunk, DecoderSampleSequence};
use crate::yuv;
use crate::DECODER_WORKER_HARD_LIMITS;

/// Declared codec family. Mirrors `VideoCodec` from `@pixel-point/aval-format`
/// (`"h264" | "h265" | "vp9" | "av1"`). Only [`VideoCodec::H264`] is decodable by
/// this crate; the rest are accepted as a declaration and rejected at configure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoCodec {
    /// H.264 / AVC — the only natively decoded family (openh264).
    H264,
    /// H.265 / HEVC — declared only (future licensing-gated crate).
    H265,
    /// VP9 — declared only (future libvpx crate).
    Vp9,
    /// AV1 — declared only (future dav1d crate).
    Av1,
}

impl VideoCodec {
    /// Maps the C ABI codec discriminant (`0=h264, 1=h265, 2=vp9, 3=av1`).
    #[must_use]
    pub const fn from_u32(value: u32) -> Option<Self> {
        match value {
            0 => Some(Self::H264),
            1 => Some(Self::H265),
            2 => Some(Self::Vp9),
            3 => Some(Self::Av1),
            _ => None,
        }
    }
}

/// Session configuration. A decode-relevant port of
/// `DecoderWorkerConfigureCommand` (`protocol.ts:106-114`): the declared codec
/// family/bit-depth ([`DecoderWorkerVideoProfile`]), coded surface geometry, and
/// the two limits that gate frame credit. The full WebCodecs codec string,
/// level-limit math, and colour-space expectation are validated upstream in
/// `aval_format`/`aval_player` before the bytes reach this crate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionConfig {
    /// Declared codec family (must be [`VideoCodec::H264`] to configure).
    pub codec: VideoCodec,
    /// Declared luma bit depth (must be `8` for H.264; only AV1 allows `10`).
    pub bit_depth: u8,
    /// Coded (decoder-surface) width in pixels.
    pub coded_width: usize,
    /// Coded (decoder-surface) height in pixels.
    pub coded_height: usize,
    /// Combined submitted-output and leased-frame ceiling
    /// (`DecoderWorkerLimits.maxOutstandingFrames`, 1..=12).
    pub max_outstanding_frames: usize,
    /// Logical RGBA bytes leased at once
    /// (`DecoderWorkerLimits.maxDecodedBytes`); must equal the exact derived
    /// budget, see [`maximum_decoded_rgba_bytes`].
    pub max_decoded_bytes: u64,
}

/// Exact per-surface decoded RGBA byte count for a coded surface.
///
/// Local stand-in for `aval-format`'s decoded-surface budget for the unpadded
/// case: `width * height * 4`. Returns `None` on overflow.
#[must_use]
pub fn maximum_decoded_rgba_bytes(coded_width: usize, coded_height: usize) -> Option<u64> {
    yuv::rgba_len(coded_width, coded_height).map(|len| len as u64)
}

/// Outcome of [`DecoderSession::submit_chunk`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubmitOutcome {
    /// A displayed frame became available and was leased under this `frame_id`.
    /// Retrieve it with [`DecoderSession::take_frame`].
    Frame {
        /// Ledger frame id of the produced frame.
        frame_id: u64,
    },
    /// No displayed frame this call — the decoder is priming (`decode()` returned
    /// `None`), or the chunk was hidden (`displayed_frame_count == 0`).
    Priming,
}

/// A decoded, converted, RGBA frame held by the session until released.
#[derive(Debug)]
struct StoredFrame {
    frame_id: u64,
    generation: u64,
    ordinal: u64,
    unit_instance: u64,
    unit_frame: u64,
    decode_index: u64,
    timestamp: u64,
    duration: u64,
    width: usize,
    height: usize,
    rgba: Vec<u8>,
}

/// A borrowed view of a frame returned by [`DecoderSession::take_frame`].
///
/// The backing bytes stay owned by the session (and valid) until
/// [`DecoderSession::release_frame`] is called with the same `frame_id`.
#[derive(Debug, Clone, Copy)]
pub struct FrameView<'a> {
    /// Ledger frame id; pass to [`DecoderSession::release_frame`] when done.
    pub frame_id: u64,
    /// Global presentation ordinal (`presentation_ordinal_base + presentation_index`).
    pub ordinal: u64,
    /// Source unit instance.
    pub unit_instance: u64,
    /// Displayed-frame index within the unit (the chunk's `presentation_index`).
    pub unit_frame: u64,
    /// Decode-order index of the chunk that produced this frame.
    pub decode_index: u64,
    /// Presentation timestamp.
    pub timestamp: u64,
    /// Frame duration.
    pub duration: u64,
    /// Frame width in pixels.
    pub width: usize,
    /// Frame height in pixels.
    pub height: usize,
    /// Tightly-packed RGBA8888 bytes (`width * height * 4`).
    pub rgba: &'a [u8],
}

/// Metrics snapshot. Ports the meaningful subset of `DecoderWorkerMetrics`
/// (`protocol.ts:211-233`). WebCodecs/async-only counters (`flushCalls`,
/// `boundaryFlushCalls`, `resetCalls`, `decodeQueueSize`) are omitted because the
/// synchronous openh264 path has no input queue or boundary flush; see the report.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DecoderMetrics {
    /// Successful `configure` calls (0 or 1).
    pub configure_calls: u64,
    /// Accepted chunks (TS `acceptedSamples`).
    pub accepted_samples: u64,
    /// Chunks actually handed to the decoder (TS `submittedChunks`).
    pub submitted_chunks: u64,
    /// Displayed frames produced by the decoder (TS `outputFrames`).
    pub output_frames: u64,
    /// Frames handed to the caller via `take_frame` (TS `deliveredFrames`).
    pub delivered_frames: u64,
    /// Frames released by the caller (TS `releasedFrames`).
    pub released_frames: u64,
    /// Frames dropped by generation abort/retire before delivery (TS `staleFrames`).
    pub stale_frames: u64,
    /// Frames whose backing buffer was closed/discarded (TS `closedFrames`).
    pub closed_frames: u64,
    /// Chunks accepted but not yet handed to the decoder. Always `0` here — the
    /// synchronous path has no pending queue (TS `pendingSamples`).
    pub pending_samples: u64,
    /// In-flight display obligation not yet delivered (pending + expected +
    /// buffered). Always `0` here — decode delivers synchronously
    /// (TS `submittedFrames`).
    pub submitted_frames: u64,
    /// Currently leased (outstanding) frames (TS `leasedFrames`).
    pub leased_frames: u64,
    /// Currently leased decoded bytes (TS `leasedDecodedBytes`).
    pub leased_decoded_bytes: u64,
    /// Active generation, or `None` if no generation is active.
    pub active_generation: Option<u64>,
    /// Next submission ordinal = accepted chunks (TS `nextSubmissionOrdinal`).
    pub next_submission_ordinal: u64,
    /// Next output ordinal = delivered + stale frames (TS `nextOutputOrdinal`).
    pub next_output_ordinal: u64,
    /// Fatal errors latched by the session.
    pub errors: u64,
    /// Whether the session has been disposed.
    pub disposed: bool,
}

/// Owner of the sole `openh264` decoder for a session.
pub struct DecoderSession {
    decoder: Option<Decoder>,
    config: Option<SessionConfig>,
    credits: FrameCreditLedger,
    sequence: DecoderSampleSequence,

    active_generation: Option<u64>,
    last_generation: u64,

    ready: VecDeque<u64>,
    frames: HashMap<u64, StoredFrame>,

    configure_calls: u64,
    accepted_samples: u64,
    submitted_chunks: u64,
    output_frames: u64,
    delivered_frames: u64,
    released_frames: u64,
    stale_frames: u64,
    closed_frames: u64,
    errors: u64,

    failure: Option<AvalDecodeError>,
    disposed: bool,
}

impl Default for DecoderSession {
    fn default() -> Self {
        Self::new()
    }
}

impl DecoderSession {
    /// Creates a new, unconfigured session.
    #[must_use]
    pub fn new() -> Self {
        Self {
            decoder: None,
            config: None,
            credits: FrameCreditLedger::new(),
            sequence: DecoderSampleSequence::new(),
            active_generation: None,
            last_generation: 0,
            ready: VecDeque::new(),
            frames: HashMap::new(),
            configure_calls: 0,
            accepted_samples: 0,
            submitted_chunks: 0,
            output_frames: 0,
            delivered_frames: 0,
            released_frames: 0,
            stale_frames: 0,
            closed_frames: 0,
            errors: 0,
            failure: None,
            disposed: false,
        }
    }

    /// Configures the session exactly once (TS `#configure`).
    ///
    /// # Errors
    ///
    /// - [`AvalDecodeError::Unsupported`] if the declared codec is not H.264
    ///   (openh264 is the only native decoder).
    /// - [`AvalDecodeError::InvalidArgument`] if already configured, disposed,
    ///   the geometry/limits are out of range, the bit depth is not 8, or
    ///   `max_decoded_bytes` is not the exact derived budget (TS
    ///   `ALREADY_CONFIGURED` / `PROTOCOL_ERROR`).
    /// - [`AvalDecodeError::DecodeFailed`] if the `openh264` decoder cannot be
    ///   created (TS `DECODER_CONFIGURE_FAILED`).
    pub fn configure(&mut self, config: SessionConfig) -> Result<(), AvalDecodeError> {
        self.check_usable()?;
        if self.configure_calls != 0 || self.decoder.is_some() {
            return Err(AvalDecodeError::InvalidArgument(
                "decoder session may be configured only once",
            ));
        }
        Self::validate_config(&config)?;

        let decoder = match Decoder::new() {
            Ok(decoder) => decoder,
            Err(error) => {
                return Err(self.fail(AvalDecodeError::DecodeFailed(format!(
                    "failed to create openh264 decoder: {error}"
                ))));
            }
        };

        self.decoder = Some(decoder);
        self.config = Some(config);
        self.configure_calls += 1;
        Ok(())
    }

    /// Activates a new generation (TS `#activateGeneration`). Generations must
    /// increase monotonically and be positive.
    ///
    /// # Errors
    ///
    /// [`AvalDecodeError::InvalidArgument`] if not configured, disposed, or the
    /// generation is not strictly greater than the last activated generation.
    pub fn activate_generation(&mut self, generation: u64) -> Result<(), AvalDecodeError> {
        self.assert_configured()?;
        if generation == 0 {
            return Err(AvalDecodeError::InvalidArgument(
                "generation must be a positive integer",
            ));
        }
        if generation <= self.last_generation {
            return Err(AvalDecodeError::InvalidArgument(
                "decoder generations must increase monotonically",
            ));
        }
        self.sequence.activate(generation);
        self.active_generation = Some(generation);
        self.last_generation = generation;
        Ok(())
    }

    /// Aborts the active generation (TS `#abortGeneration`), dropping any decoded
    /// frames that are queued but not yet taken. Frames already handed out by
    /// [`DecoderSession::take_frame`] stay leased until the caller releases them,
    /// so their FFI pointer never dangles.
    ///
    /// # Errors
    ///
    /// [`AvalDecodeError::InvalidArgument`] if not configured/disposed or
    /// `generation` is not the active generation.
    pub fn abort_generation(&mut self, generation: u64) -> Result<(), AvalDecodeError> {
        self.assert_configured()?;
        if self.active_generation != Some(generation) {
            return Err(AvalDecodeError::InvalidArgument(
                "only the active decoder generation can be aborted",
            ));
        }
        self.active_generation = None;
        self.sequence.abort(generation);
        // Drop only queued-but-untaken frames of this generation (TS retire of
        // buffered, not-yet-transferred frames). Delivered-unreleased frames stay.
        let stale: Vec<u64> = self
            .ready
            .iter()
            .copied()
            .filter(|id| {
                self.frames
                    .get(id)
                    .is_some_and(|frame| frame.generation == generation)
            })
            .collect();
        for frame_id in stale {
            self.drop_frame(frame_id);
            self.stale_frames += 1;
            self.closed_frames += 1;
        }
        Ok(())
    }

    /// Submits one encoded chunk (TS `#submit` + `#pump` + `handleOutput`,
    /// collapsed into a synchronous decode).
    ///
    /// # Errors
    ///
    /// - [`AvalDecodeError::Unsupported`] if `displayed_frame_count > 1` (openh264
    ///   is 1:1; superframes need a VP9/AV1 decoder).
    /// - [`AvalDecodeError::InvalidArgument`] if not configured/disposed, the
    ///   generation is not active, the outstanding-frame credit is exhausted
    ///   (TS `BACKPRESSURE_LIMIT`), or the chunk fails unit/continuity validation.
    /// - [`AvalDecodeError::DecodeFailed`] if `openh264` rejects the bitstream.
    /// - [`AvalDecodeError::DecoderOutputInvalid`] if the decoded geometry is
    ///   inconsistent, or a hidden chunk unexpectedly produced a frame (fatal,
    ///   TS `DECODER_OUTPUT_INVALID`).
    /// - [`AvalDecodeError::DecodedByteBudgetExceeded`] if leasing the frame would
    ///   exceed the byte budget (fatal).
    pub fn submit_chunk(
        &mut self,
        generation: u64,
        chunk: &DecodeChunk<'_>,
    ) -> Result<SubmitOutcome, AvalDecodeError> {
        self.assert_configured()?;
        if self.active_generation != Some(generation) {
            return Err(AvalDecodeError::InvalidArgument(
                "decode submission does not target the active generation",
            ));
        }
        let config = self.config.expect("configured session has a config");

        // openh264 yields at most one displayed frame per decode(); a chunk that
        // asserts a superframe cannot be decoded here (configure already rejects
        // the codecs that produce them, but guard the chunk shape too).
        if chunk.displayed_frame_count > 1 {
            return Err(AvalDecodeError::Unsupported(
                "openh264 yields one displayed frame per chunk; superframes need a VP9/AV1 decoder",
            ));
        }

        // Outstanding-frame credit gate (TS `#submit` denominated in displayed
        // frames). In the synchronous collapse there is no pending queue and no
        // in-flight decoder callback, so outstanding == leased. A hidden chunk
        // (0 displayed frames) needs no credit.
        if chunk.displayed_frame_count > 0
            && !self
                .credits
                .has_submission_credit(0, config.max_outstanding_frames)
        {
            return Err(AvalDecodeError::InvalidArgument(
                "decode submission exceeds the outstanding-frame budget",
            ));
        }

        // Unit/decode-order continuity (advances the sequence on success).
        self.sequence
            .accept(generation, std::slice::from_ref(chunk))?;
        self.accepted_samples += 1;
        self.submitted_chunks += 1;

        // Decode, converting the borrowed I420 into an owned RGBA buffer before
        // the decoder borrow ends.
        let decoder = self.decoder.as_mut().expect("configured session decoder");
        let converted = match decoder.decode(chunk.data) {
            Ok(Some(yuv)) => {
                let (width, height) = yuv.dimensions();
                let (y_stride, uv_stride, _) = yuv.strides();
                let len =
                    yuv::rgba_len(width, height).ok_or(AvalDecodeError::DecoderOutputInvalid)?;
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
                Some((width, height, rgba))
            }
            Ok(None) => None,
            Err(error) => {
                return Err(AvalDecodeError::DecodeFailed(format!(
                    "openh264 rejected the chunk: {error}"
                )));
            }
        };

        // Hidden chunk: no displayed output is expected.
        if chunk.displayed_frame_count == 0 {
            if converted.is_some() {
                // TS: "fails closed when a hidden chunk unexpectedly produces a frame".
                self.closed_frames += 1;
                return Err(self.fail(AvalDecodeError::DecoderOutputInvalid));
            }
            return Ok(SubmitOutcome::Priming);
        }

        // From here `displayed_frame_count == 1`.
        let Some((width, height, rgba)) = converted else {
            return Ok(SubmitOutcome::Priming);
        };

        // Geometry must match the configured coded surface (TS validateDecodedFrame).
        if width != config.coded_width || height != config.coded_height {
            return Err(self.fail(AvalDecodeError::DecoderOutputInvalid));
        }

        let presentation_index = chunk.presentation_indices[0];
        // `validate_chunk_shape` guarantees `base + unit_frame_count <= MAX_SAFE`
        // and `presentation_index < unit_frame_count`, so this cannot overflow.
        let ordinal = chunk.presentation_ordinal_base + presentation_index;
        let timestamp = expected_timestamp(chunk, 0)?;

        let decoded_bytes = rgba.len() as u64;
        let frame_id = match self
            .credits
            .lease(generation, decoded_bytes, config.max_decoded_bytes)
        {
            Ok(id) => id,
            Err(error) => return Err(self.fail(error)),
        };
        self.output_frames += 1;

        self.frames.insert(
            frame_id,
            StoredFrame {
                frame_id,
                generation,
                ordinal,
                unit_instance: chunk.unit_instance,
                unit_frame: presentation_index,
                decode_index: chunk.decode_index,
                timestamp,
                duration: chunk.duration,
                width,
                height,
                rgba,
            },
        );
        self.ready.push_back(frame_id);
        Ok(SubmitOutcome::Frame { frame_id })
    }

    /// Removes and returns the next ready frame in FIFO order (TS frame event
    /// delivery). `Ok(None)` means no frame is currently queued.
    ///
    /// # Errors
    ///
    /// [`AvalDecodeError::InvalidArgument`] if disposed, or a latched fatal
    /// failure is replayed.
    pub fn take_frame(&mut self) -> Result<Option<FrameView<'_>>, AvalDecodeError> {
        self.check_usable()?;
        let Some(frame_id) = self.ready.pop_front() else {
            return Ok(None);
        };
        self.delivered_frames += 1;
        let frame = self
            .frames
            .get(&frame_id)
            .expect("ready frame id is present in the frame table");
        Ok(Some(FrameView {
            frame_id: frame.frame_id,
            ordinal: frame.ordinal,
            unit_instance: frame.unit_instance,
            unit_frame: frame.unit_frame,
            decode_index: frame.decode_index,
            timestamp: frame.timestamp,
            duration: frame.duration,
            width: frame.width,
            height: frame.height,
            rgba: &frame.rgba,
        }))
    }

    /// Releases a frame, freeing its buffer and replenishing credit (TS
    /// `#releaseFrame`).
    ///
    /// # Errors
    ///
    /// [`AvalDecodeError::FrameReleaseInvalid`] if `frame_id` is unknown, zero,
    /// or already released (fatal — treated as ownership corruption, matching
    /// the TS worker which fails the session on a bad release).
    pub fn release_frame(&mut self, frame_id: u64) -> Result<(), AvalDecodeError> {
        self.check_usable()?;
        if let Err(error) = self.credits.release(frame_id) {
            return Err(self.fail(error));
        }
        self.frames.remove(&frame_id);
        // A frame is normally taken before release, but tolerate release of an
        // untaken frame by removing it from the ready queue too.
        self.ready.retain(|&id| id != frame_id);
        self.released_frames += 1;
        Ok(())
    }

    /// Returns a metrics snapshot (TS `snapshotMetrics`). Always succeeds, even
    /// after failure or disposal, matching the TS `snapshot` command.
    #[must_use]
    pub fn snapshot(&self) -> DecoderMetrics {
        DecoderMetrics {
            configure_calls: self.configure_calls,
            accepted_samples: self.accepted_samples,
            submitted_chunks: self.submitted_chunks,
            output_frames: self.output_frames,
            delivered_frames: self.delivered_frames,
            released_frames: self.released_frames,
            stale_frames: self.stale_frames,
            closed_frames: self.closed_frames,
            // No pending queue and synchronous delivery in the openh264 collapse.
            pending_samples: 0,
            submitted_frames: 0,
            leased_frames: self.credits.count() as u64,
            leased_decoded_bytes: self.credits.decoded_bytes(),
            active_generation: self.active_generation,
            next_submission_ordinal: self.sequence.accepted_chunks(),
            next_output_ordinal: self.delivered_frames + self.stale_frames,
            errors: self.errors,
            disposed: self.disposed,
        }
    }

    /// Tears the session down (TS `#dispose`). Idempotent.
    pub fn dispose(&mut self) {
        if self.disposed {
            return;
        }
        self.disposed = true;
        self.active_generation = None;
        self.ready.clear();
        self.frames.clear();
        self.sequence.clear_active();
        self.credits.clear();
        self.decoder = None;
    }

    /// Whether a fatal error has been latched.
    #[must_use]
    pub fn has_failed(&self) -> bool {
        self.failure.is_some()
    }

    // --- internal helpers -------------------------------------------------

    fn validate_config(config: &SessionConfig) -> Result<(), AvalDecodeError> {
        // Codec-generic seam, H.264-only native decode (ARCHITECTURE.md §2).
        if config.codec != VideoCodec::H264 {
            return Err(AvalDecodeError::Unsupported(
                "only H.264 is decodable natively (openh264); H.265/VP9/AV1 are declared-only",
            ));
        }
        // TS validateConfiguration: only AV1 supports a 10-bit worker profile.
        if config.bit_depth != 8 {
            return Err(AvalDecodeError::InvalidArgument(
                "H.264 profile must be 8-bit",
            ));
        }
        if config.coded_width == 0 || config.coded_height == 0 {
            return Err(AvalDecodeError::InvalidArgument(
                "coded dimensions must be positive",
            ));
        }
        if config.max_outstanding_frames < 1
            || config.max_outstanding_frames > DECODER_WORKER_HARD_LIMITS.max_outstanding_frames
        {
            return Err(AvalDecodeError::InvalidArgument(
                "maxOutstandingFrames must be between 1 and the hard cap (12)",
            ));
        }
        // TS validateConfiguration: `maxDecodedBytes` must exactly match the
        // derived decoded-surface budget.
        let per_surface = maximum_decoded_rgba_bytes(config.coded_width, config.coded_height)
            .ok_or(AvalDecodeError::InvalidArgument(
                "decoded-surface byte count overflows",
            ))?;
        let exact = per_surface
            .checked_mul(config.max_outstanding_frames as u64)
            .ok_or(AvalDecodeError::InvalidArgument(
                "decoded-surface budget overflows",
            ))?;
        if config.max_decoded_bytes != exact {
            return Err(AvalDecodeError::InvalidArgument(
                "maxDecodedBytes must exactly match the decoded-surface budget",
            ));
        }
        Ok(())
    }

    /// TS `#assertConfigured`: reject if not yet configured (also checks usable).
    fn assert_configured(&mut self) -> Result<(), AvalDecodeError> {
        self.check_usable()?;
        if self.decoder.is_none() || self.config.is_none() {
            return Err(AvalDecodeError::InvalidArgument(
                "decoder session must be configured before use",
            ));
        }
        Ok(())
    }

    /// Reject if disposed, or replay a latched fatal failure.
    fn check_usable(&self) -> Result<(), AvalDecodeError> {
        if self.disposed {
            return Err(AvalDecodeError::InvalidArgument(
                "decoder session is disposed",
            ));
        }
        if let Some(failure) = &self.failure {
            return Err(failure.clone());
        }
        Ok(())
    }

    /// TS `#fail`: latch a fatal error and tear down decode state, returning the
    /// same error for convenient `return Err(self.fail(err))` use.
    fn fail(&mut self, error: AvalDecodeError) -> AvalDecodeError {
        if self.failure.is_none() && !self.disposed {
            self.failure = Some(error.clone());
            self.errors += 1;
            self.active_generation = None;
            self.ready.clear();
            self.frames.clear();
            self.sequence.clear_active();
            self.credits.clear();
            self.decoder = None;
        }
        error
    }

    fn drop_frame(&mut self, frame_id: u64) {
        // Best-effort release of a stale/aborted frame; ignore ledger errors so
        // an already-consistent state is not turned fatal.
        let _ = self.credits.release(frame_id);
        self.frames.remove(&frame_id);
        self.ready.retain(|&id| id != frame_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config_2x2(max_outstanding: usize) -> SessionConfig {
        SessionConfig {
            codec: VideoCodec::H264,
            bit_depth: 8,
            coded_width: 2,
            coded_height: 2,
            max_outstanding_frames: max_outstanding,
            max_decoded_bytes: maximum_decoded_rgba_bytes(2, 2).unwrap() * max_outstanding as u64,
        }
    }

    fn key_chunk(unit_instance: u64) -> DecodeChunk<'static> {
        DecodeChunk {
            unit_id: "unit",
            unit_instance,
            decode_index: 0,
            unit_chunk_count: 1,
            unit_frame_count: 1,
            presentation_ordinal_base: unit_instance,
            presentation_indices: &[0],
            presentation_timestamp: unit_instance * 16_667 + 1,
            duration: 16_667,
            random_access: true,
            displayed_frame_count: 1,
            data: &[0x00, 0x00, 0x00, 0x01, 0x67],
        }
    }

    #[test]
    fn configure_is_once_only() {
        let mut session = DecoderSession::new();
        session.configure(config_2x2(4)).unwrap();
        let err = session.configure(config_2x2(4)).unwrap_err();
        assert!(matches!(err, AvalDecodeError::InvalidArgument(_)));
        assert_eq!(session.snapshot().configure_calls, 1);
    }

    #[test]
    fn configure_rejects_non_h264_codec() {
        for codec in [VideoCodec::H265, VideoCodec::Vp9, VideoCodec::Av1] {
            let mut session = DecoderSession::new();
            let cfg = SessionConfig {
                codec,
                ..config_2x2(4)
            };
            let err = session.configure(cfg).unwrap_err();
            assert!(matches!(err, AvalDecodeError::Unsupported(_)));
            assert!(err.is_fatal());
            assert_eq!(session.snapshot().configure_calls, 0);
        }
    }

    #[test]
    fn configure_rejects_non_8bit_depth() {
        let mut session = DecoderSession::new();
        let cfg = SessionConfig {
            bit_depth: 10,
            ..config_2x2(4)
        };
        assert!(matches!(
            session.configure(cfg).unwrap_err(),
            AvalDecodeError::InvalidArgument(_)
        ));
    }

    #[test]
    fn configure_requires_exact_decoded_byte_budget() {
        let mut session = DecoderSession::new();
        let mut cfg = config_2x2(4);
        cfg.max_decoded_bytes += 1;
        let err = session.configure(cfg).unwrap_err();
        assert!(matches!(err, AvalDecodeError::InvalidArgument(_)));

        let mut under = config_2x2(4);
        under.max_decoded_bytes -= 1;
        assert!(DecoderSession::new().configure(under).is_err());
    }

    #[test]
    fn configure_rejects_out_of_range_outstanding_frames() {
        let mut zero = config_2x2(4);
        zero.max_outstanding_frames = 0;
        zero.max_decoded_bytes = 0;
        assert!(DecoderSession::new().configure(zero).is_err());
        let mut over = config_2x2(4);
        over.max_outstanding_frames = 13; // above the hard cap of 12
        over.max_decoded_bytes = maximum_decoded_rgba_bytes(2, 2).unwrap() * 13;
        assert!(DecoderSession::new().configure(over).is_err());
    }

    #[test]
    fn submit_before_configure_is_rejected() {
        let mut session = DecoderSession::new();
        let err = session.submit_chunk(1, &key_chunk(0)).unwrap_err();
        assert!(matches!(err, AvalDecodeError::InvalidArgument(_)));
    }

    #[test]
    fn submit_requires_the_active_generation() {
        let mut session = DecoderSession::new();
        session.configure(config_2x2(4)).unwrap();
        // No generation activated yet.
        assert!(session.submit_chunk(1, &key_chunk(0)).is_err());
        session.activate_generation(1).unwrap();
        // Submitting to a non-active generation is rejected.
        assert!(session.submit_chunk(2, &key_chunk(0)).is_err());
    }

    #[test]
    fn submit_rejects_superframe_chunks_as_unsupported() {
        let mut session = DecoderSession::new();
        session.configure(config_2x2(4)).unwrap();
        session.activate_generation(1).unwrap();
        let superframe = DecodeChunk {
            unit_frame_count: 2,
            presentation_indices: &[0, 1],
            displayed_frame_count: 2,
            ..key_chunk(0)
        };
        let err = session.submit_chunk(1, &superframe).unwrap_err();
        assert!(matches!(err, AvalDecodeError::Unsupported(_)));
    }

    #[test]
    fn generations_must_increase_monotonically() {
        let mut session = DecoderSession::new();
        session.configure(config_2x2(4)).unwrap();
        session.activate_generation(2).unwrap();
        assert!(session.activate_generation(2).is_err());
        assert!(session.activate_generation(1).is_err());
        session.activate_generation(3).unwrap();
    }

    #[test]
    fn take_frame_on_empty_queue_returns_none() {
        let mut session = DecoderSession::new();
        session.configure(config_2x2(4)).unwrap();
        session.activate_generation(1).unwrap();
        assert!(session.take_frame().unwrap().is_none());
    }

    #[test]
    fn dispose_is_idempotent_and_blocks_further_use() {
        let mut session = DecoderSession::new();
        session.configure(config_2x2(4)).unwrap();
        session.dispose();
        session.dispose();
        assert!(session.snapshot().disposed);
        assert!(session.activate_generation(1).is_err());
    }

    #[test]
    fn release_of_unknown_frame_is_fatal() {
        let mut session = DecoderSession::new();
        session.configure(config_2x2(4)).unwrap();
        let err = session.release_frame(42).unwrap_err();
        assert_eq!(err, AvalDecodeError::FrameReleaseInvalid);
        assert!(session.has_failed());
        // Session is latched failed now.
        assert!(session.activate_generation(1).is_err());
    }
}

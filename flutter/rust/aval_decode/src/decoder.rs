//! Protocol-shaped decode session.
//!
//! Ports the command/event vocabulary of
//! `packages/player-web/src/decoder-worker/{core.ts, protocol.ts}` onto the
//! synchronous `openh264` decoder. The `DecoderWorkerCore` class owns a single
//! `VideoDecoder`, gates input with the [`FrameCreditLedger`] and
//! [`DecoderSampleSequence`], and emits frame/ack/error events over a Worker
//! port. Here the same lifecycle is expressed as ordinary methods
//! ([`DecoderSession::configure`], [`DecoderSession::activate_generation`],
//! [`DecoderSession::submit_access_unit`], [`DecoderSession::take_frame`],
//! [`DecoderSession::release_frame`], [`DecoderSession::abort_generation`],
//! [`DecoderSession::snapshot`], [`DecoderSession::dispose`]), because AVAL
//! content is Constrained Baseline (no B-frames, one reference frame, closed
//! GOP): decode order equals display order and one access unit in produces at
//! most one frame out synchronously, so the async event pump / dequeue-callback
//! machinery collapses away.
//!
//! What is faithfully preserved from `core.ts`:
//! - configure-once semantics (`ALREADY_CONFIGURED`),
//! - the exact derived decoded-byte budget rule (`validateConfiguration`),
//! - monotonic generation activation and generation-scoped submit,
//! - the outstanding-frame credit gate before accepting a submission,
//! - sample ordinal/contiguity validation via [`DecoderSampleSequence`],
//! - low-delay output-order enforcement (`ordinal == nextOutputOrdinal`),
//! - the frame-credit lease/release lifecycle across the boundary,
//! - the metrics snapshot vocabulary (`DecoderWorkerMetrics`),
//! - fatal-failure latching (a fatal error tears the session down; further
//!   calls report it), mirroring `#fail`.
//!
//! What is intentionally *not* ported (WebCodecs/Worker-only, see the report):
//! the async support probe, `decodeQueueSize`/dequeue callbacks, request-id
//! monotonicity, `VideoFrame`-transfer / structured-clone plumbing, and the
//! full WebCodecs colour-space echo checks in `core-validation.ts`
//! (`avc1.*` codec parsing and level-limit math live in `aval_format`, not
//! this crate — ARCHITECTURE.md 6).

use std::collections::{HashMap, VecDeque};

use openh264::decoder::Decoder;
use openh264::formats::YUVSource;

use crate::error::AvalDecodeError;
use crate::ledger::FrameCreditLedger;
use crate::sample_sequence::{AccessUnitSample, DecoderSampleSequence};
use crate::yuv;
use crate::DECODER_WORKER_HARD_LIMITS;

/// Session configuration. A reduced, decode-relevant port of
/// `DecoderWorkerConfigureCommand` (`protocol.ts:98-106`): the coded surface
/// geometry plus the two limits that gate frame credit. The AVC codec string,
/// level-limit math, and colour-space expectation are validated upstream in
/// `aval_format`/`aval_player` before the bytes reach this crate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionConfig {
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
/// Local stand-in for `aval-format`'s `maximumAvcDecodedRgbaBytes` for the
/// unpadded case: `width * height * 4`. Returns `None` on overflow.
#[must_use]
pub fn maximum_decoded_rgba_bytes(coded_width: usize, coded_height: usize) -> Option<u64> {
    yuv::rgba_len(coded_width, coded_height).map(|len| len as u64)
}

/// Outcome of [`DecoderSession::submit_access_unit`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubmitOutcome {
    /// A frame became available and was leased under this `frame_id`. Retrieve
    /// it with [`DecoderSession::take_frame`].
    Frame { frame_id: u64 },
    /// No frame yet — the decoder is priming (`decode()` returned `None`).
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
    /// Global decode/display ordinal.
    pub ordinal: u64,
    /// Source unit instance.
    pub unit_instance: u64,
    /// Frame index within the unit instance.
    pub unit_frame: u64,
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
/// (`protocol.ts:181-203`); WebCodecs-only counters (`decodeQueueSize`,
/// `staleFrames` from async reordering, `closedFrames`) are omitted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DecoderMetrics {
    /// Successful `configure` calls (0 or 1).
    pub configure_calls: u64,
    /// Accepted access units.
    pub accepted_samples: u64,
    /// Access units actually handed to the decoder.
    pub submitted_chunks: u64,
    /// Frames produced by the decoder.
    pub output_frames: u64,
    /// Frames handed to the caller via `take_frame`.
    pub delivered_frames: u64,
    /// Frames released by the caller.
    pub released_frames: u64,
    /// Currently leased (outstanding) frames.
    pub leased_frames: u64,
    /// Currently leased decoded bytes.
    pub leased_decoded_bytes: u64,
    /// Active generation, or `None` if no generation is active.
    pub active_generation: Option<u64>,
    /// Next expected submission ordinal.
    pub next_submission_ordinal: u64,
    /// Next expected output ordinal.
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
    next_output_ordinal: u64,

    ready: VecDeque<u64>,
    frames: HashMap<u64, StoredFrame>,

    configure_calls: u64,
    accepted_samples: u64,
    submitted_chunks: u64,
    output_frames: u64,
    delivered_frames: u64,
    released_frames: u64,
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
            next_output_ordinal: 0,
            ready: VecDeque::new(),
            frames: HashMap::new(),
            configure_calls: 0,
            accepted_samples: 0,
            submitted_chunks: 0,
            output_frames: 0,
            delivered_frames: 0,
            released_frames: 0,
            errors: 0,
            failure: None,
            disposed: false,
        }
    }

    /// Configures the session exactly once (TS `#configure`).
    ///
    /// # Errors
    ///
    /// - [`AvalDecodeError::InvalidArgument`] if already configured, disposed,
    ///   the geometry/limits are out of range, or `max_decoded_bytes` is not the
    ///   exact derived budget (TS `ALREADY_CONFIGURED` / `PROTOCOL_ERROR`).
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

    /// Aborts the active generation (TS `#abortGeneration`), retiring any frames
    /// still leased under it and dropping any that are queued but untaken.
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
        // Drop queued-but-untaken frames from this generation.
        let stale: Vec<u64> = self
            .frames
            .values()
            .filter(|frame| frame.generation == generation)
            .map(|frame| frame.frame_id)
            .collect();
        for frame_id in stale {
            self.drop_frame(frame_id);
        }
        Ok(())
    }

    /// Submits one access unit (TS `#submit` + `#pump` + `#handleOutput`,
    /// collapsed into a synchronous decode).
    ///
    /// # Errors
    ///
    /// - [`AvalDecodeError::InvalidArgument`] if not configured/disposed, the
    ///   generation is not active, the outstanding-frame credit is exhausted
    ///   (TS `BACKPRESSURE_LIMIT`), or the sample fails ordinal/contiguity
    ///   validation.
    /// - [`AvalDecodeError::DecodeFailed`] if `openh264` rejects the bitstream.
    /// - [`AvalDecodeError::DecoderOutputInvalid`] if the decoded geometry or
    ///   output order is inconsistent (fatal, TS `DECODER_OUTPUT_INVALID`).
    /// - [`AvalDecodeError::DecodedByteBudgetExceeded`] if leasing the frame
    ///   would exceed the byte budget (fatal).
    pub fn submit_access_unit(
        &mut self,
        generation: u64,
        sample: &AccessUnitSample<'_>,
    ) -> Result<SubmitOutcome, AvalDecodeError> {
        self.assert_configured()?;
        if self.active_generation != Some(generation) {
            return Err(AvalDecodeError::InvalidArgument(
                "decode submission does not target the active generation",
            ));
        }
        let config = self.config.expect("configured session has a config");

        // Credit gate: synchronous decode has no in-flight submitted frames, so
        // this is `credits.count + 1 <= maxOutstandingFrames` (TS `#submit`'s
        // outstanding-frame budget check with pending == submitted == 0).
        if !self
            .credits
            .has_submission_credit(0, config.max_outstanding_frames)
        {
            return Err(AvalDecodeError::InvalidArgument(
                "decode submission exceeds the outstanding-frame budget",
            ));
        }

        // Ordinal/contiguity validation (advances the sequence on success).
        self.sequence
            .accept(generation, std::slice::from_ref(sample))?;
        self.accepted_samples += 1;
        self.submitted_chunks += 1;

        // Decode, converting the borrowed I420 into an owned RGBA buffer before
        // the decoder borrow ends.
        let decoder = self.decoder.as_mut().expect("configured session decoder");
        let converted = match decoder.decode(sample.data) {
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
                    "openh264 rejected the access unit: {error}"
                )));
            }
        };

        let Some((width, height, rgba)) = converted else {
            return Ok(SubmitOutcome::Priming);
        };

        // Geometry must match the configured coded surface (TS validateDecodedFrame).
        if width != config.coded_width || height != config.coded_height {
            return Err(self.fail(AvalDecodeError::DecoderOutputInvalid));
        }
        // Low-delay output order: this frame is the next expected output ordinal.
        if sample.ordinal != self.next_output_ordinal {
            return Err(self.fail(AvalDecodeError::DecoderOutputInvalid));
        }

        let decoded_bytes = rgba.len() as u64;
        let frame_id = match self
            .credits
            .lease(generation, decoded_bytes, config.max_decoded_bytes)
        {
            Ok(id) => id,
            Err(error) => return Err(self.fail(error)),
        };
        self.next_output_ordinal += 1;
        self.output_frames += 1;

        self.frames.insert(
            frame_id,
            StoredFrame {
                frame_id,
                generation,
                ordinal: sample.ordinal,
                unit_instance: sample.unit_instance,
                unit_frame: sample.unit_frame,
                timestamp: sample.timestamp,
                duration: sample.duration,
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
            leased_frames: self.credits.count() as u64,
            leased_decoded_bytes: self.credits.decoded_bytes(),
            active_generation: self.active_generation,
            next_submission_ordinal: self.sequence.next_ordinal(),
            next_output_ordinal: self.next_output_ordinal,
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
            coded_width: 2,
            coded_height: 2,
            max_outstanding_frames: max_outstanding,
            max_decoded_bytes: maximum_decoded_rgba_bytes(2, 2).unwrap() * max_outstanding as u64,
        }
    }

    fn key_sample(ordinal: u64) -> AccessUnitSample<'static> {
        AccessUnitSample {
            ordinal,
            unit_id: "unit",
            unit_instance: 0,
            unit_frame: 0,
            unit_frame_count: 1,
            is_key: true,
            timestamp: ordinal * 16_667 + 1,
            duration: 16_667,
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
        let mut zero = SessionConfig {
            coded_width: 2,
            coded_height: 2,
            max_outstanding_frames: 0,
            max_decoded_bytes: 0,
        };
        assert!(DecoderSession::new().configure(zero).is_err());
        zero.max_outstanding_frames = 13; // above the hard cap of 12
        zero.max_decoded_bytes = maximum_decoded_rgba_bytes(2, 2).unwrap() * 13;
        assert!(DecoderSession::new().configure(zero).is_err());
    }

    #[test]
    fn submit_before_configure_is_rejected() {
        let mut session = DecoderSession::new();
        let err = session.submit_access_unit(1, &key_sample(0)).unwrap_err();
        assert!(matches!(err, AvalDecodeError::InvalidArgument(_)));
    }

    #[test]
    fn submit_requires_the_active_generation() {
        let mut session = DecoderSession::new();
        session.configure(config_2x2(4)).unwrap();
        // No generation activated yet.
        assert!(session.submit_access_unit(1, &key_sample(0)).is_err());
        session.activate_generation(1).unwrap();
        // Submitting to a non-active generation is rejected.
        assert!(session.submit_access_unit(2, &key_sample(0)).is_err());
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

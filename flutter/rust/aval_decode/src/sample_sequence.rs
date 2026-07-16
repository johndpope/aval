//! Global ordinal / timestamp continuity for submitted access units.
//!
//! Ports `packages/player-web/src/decoder-worker/sample-sequence.ts` (50 LOC,
//! the `DecoderSampleSequence` class) together with the ordinal/contiguity slice
//! of `core-validation.ts::validateSample` (lines 157-216) that the sequence
//! relies on to reject a malformed batch before advancing.
//!
//! Error mapping: the TS code throws `PROTOCOL_ERROR` / `GENERATION_MISMATCH`
//! `DecoderWorkerCoreError`s here. Those codes are not part of this crate's C
//! ABI status enum (`error.rs`), which is deliberately scoped to the
//! ledger/decode taxonomy, so every validation failure in this module is
//! reported as [`AvalDecodeError::InvalidArgument`] with a descriptive
//! `&'static str`. This is the one intentional error-taxonomy narrowing versus
//! the TypeScript source (documented in the crate report).

use crate::error::AvalDecodeError;
use crate::MAX_SAFE_INTEGER;

/// Maximum encoded unit-id length, from `core-validation.ts:183`
/// (`unitId.length` must be between 1 and 128).
pub const MAX_UNIT_ID_LEN: usize = 128;

/// One owned access unit handed to the decoder. Mirrors the fields of the TS
/// `DecoderWorkerSample` interface (`protocol.ts:86-96`) that carry decode
/// semantics; the WebCodecs-only `type: EncodedVideoChunkType` becomes
/// [`AccessUnitSample::is_key`], and `data: ArrayBuffer` becomes a byte slice.
#[derive(Debug, Clone, Copy)]
pub struct AccessUnitSample<'a> {
    /// Global decode ordinal; must be contiguous with the sequence.
    pub ordinal: u64,
    /// Stable id for the source unit (1..=128 bytes when interpreted as UTF-8).
    pub unit_id: &'a str,
    /// Which instance of the unit this replay belongs to.
    pub unit_instance: u64,
    /// Zero-based frame index within the unit instance.
    pub unit_frame: u64,
    /// Total frames in the unit instance (`unit_frame < unit_frame_count`).
    pub unit_frame_count: u64,
    /// Whether this access unit is an IDR/key frame (TS `type === "key"`).
    pub is_key: bool,
    /// Presentation timestamp; strictly increasing across the sequence.
    pub timestamp: u64,
    /// Frame duration in the same units as `timestamp`.
    pub duration: u64,
    /// Annex-B encoded access-unit bytes (non-empty).
    pub data: &'a [u8],
}

/// Validates one sample against the expected ordinal and previous timestamp.
///
/// Direct port of the representable checks in `core-validation.ts::validateSample`
/// (157-216). Purely structural WebCodecs/protocol-shape checks that have no
/// meaning for a typed Rust struct (`hasExactKeys`, `data instanceof ArrayBuffer`)
/// are omitted; every value check that guards decode correctness is kept.
///
/// # Errors
///
/// [`AvalDecodeError::InvalidArgument`] describing the first failed check.
pub fn validate_sample(
    sample: &AccessUnitSample<'_>,
    expected_ordinal: u64,
    previous_timestamp: Option<u64>,
) -> Result<(), AvalDecodeError> {
    if sample.ordinal != expected_ordinal {
        return Err(AvalDecodeError::InvalidArgument(
            "decode ordinal does not match the expected next ordinal",
        ));
    }
    // TS: `sample.ordinal >= Number.MAX_SAFE_INTEGER` — leaves no safe successor.
    if sample.ordinal >= MAX_SAFE_INTEGER {
        return Err(AvalDecodeError::InvalidArgument(
            "decode ordinal leaves no safe successor",
        ));
    }
    let id_len = sample.unit_id.len();
    if !(1..=MAX_UNIT_ID_LEN).contains(&id_len) {
        return Err(AvalDecodeError::InvalidArgument(
            "decode sample unitId length must be between 1 and 128",
        ));
    }
    // `unit_instance` / `unit_frame` are unsigned, so the "non-negative integer"
    // checks hold by construction. `unit_frame_count` must be positive.
    if sample.unit_frame_count < 1 {
        return Err(AvalDecodeError::InvalidArgument(
            "decode sample unitFrameCount must be a positive integer",
        ));
    }
    if sample.unit_frame >= sample.unit_frame_count {
        return Err(AvalDecodeError::InvalidArgument(
            "decode sample unitFrame exceeds its unitFrameCount",
        ));
    }
    if sample.duration < 1 {
        return Err(AvalDecodeError::InvalidArgument(
            "decode sample duration must be a positive integer",
        ));
    }
    // TS: `sample.timestamp > Number.MAX_SAFE_INTEGER - sample.duration`.
    if sample.timestamp > MAX_SAFE_INTEGER - sample.duration {
        return Err(AvalDecodeError::InvalidArgument(
            "decode timestamp plus duration exceeds the safe integer range",
        ));
    }
    if let Some(previous) = previous_timestamp {
        if sample.timestamp <= previous {
            return Err(AvalDecodeError::InvalidArgument(
                "decode timestamps must be strictly increasing",
            ));
        }
    }
    if sample.data.is_empty() {
        return Err(AvalDecodeError::InvalidArgument(
            "decode sample data must not be empty",
        ));
    }
    Ok(())
}

/// Owns global ordinal/timestamp continuity; AVC owns unit semantics.
///
/// Direct port of the TS `DecoderSampleSequence` class.
#[derive(Debug, Default)]
pub struct DecoderSampleSequence {
    active_generation: Option<u64>,
    next_ordinal: u64,
    last_timestamp: Option<u64>,
}

impl DecoderSampleSequence {
    /// Creates a fresh sequence (`next_ordinal == 0`, no active generation).
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// The next ordinal the sequence expects (TS `get nextOrdinal`).
    #[must_use]
    pub fn next_ordinal(&self) -> u64 {
        self.next_ordinal
    }

    /// Marks `generation` active (TS `activate`).
    pub fn activate(&mut self, generation: u64) {
        self.active_generation = Some(generation);
    }

    /// Clears the active generation iff it currently equals `generation`
    /// (TS `abort`).
    pub fn abort(&mut self, generation: u64) {
        if self.active_generation == Some(generation) {
            self.active_generation = None;
        }
    }

    /// Unconditionally clears the active generation (TS `clearActive`).
    pub fn clear_active(&mut self) {
        self.active_generation = None;
    }

    /// Validates the entire batch atomically, then advances the sequence
    /// (TS `accept`). Nothing is mutated unless every sample passes.
    ///
    /// # Errors
    ///
    /// - [`AvalDecodeError::InvalidArgument`] if `generation` is not the active
    ///   generation (TS `GENERATION_MISMATCH`), or if any sample fails
    ///   [`validate_sample`].
    pub fn accept(
        &mut self,
        generation: u64,
        samples: &[AccessUnitSample<'_>],
    ) -> Result<(), AvalDecodeError> {
        if self.active_generation != Some(generation) {
            return Err(AvalDecodeError::InvalidArgument(
                "decode submission does not target the active generation",
            ));
        }
        let mut ordinal = self.next_ordinal;
        let mut timestamp = self.last_timestamp;
        for sample in samples {
            validate_sample(sample, ordinal, timestamp)?;
            ordinal += 1;
            timestamp = Some(sample.timestamp);
        }
        self.next_ordinal = ordinal;
        self.last_timestamp = timestamp;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample<'a>(ordinal: u64, timestamp: u64, unit_id: &'a str) -> AccessUnitSample<'a> {
        AccessUnitSample {
            ordinal,
            unit_id,
            unit_instance: 0,
            unit_frame: 0,
            unit_frame_count: 1,
            is_key: true,
            timestamp,
            duration: 16_667,
            data: &[0x01],
        }
    }

    #[test]
    fn accept_advances_ordinal_and_timestamp() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        seq.accept(1, &[sample(0, 0, "idle"), sample(1, 16_667, "idle")])
            .unwrap();
        assert_eq!(seq.next_ordinal(), 2);
        // Continues from the advanced state.
        seq.accept(1, &[sample(2, 40_000, "idle")]).unwrap();
        assert_eq!(seq.next_ordinal(), 3);
    }

    #[test]
    fn accept_rejects_inactive_generation() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        let err = seq.accept(2, &[sample(0, 0, "idle")]).unwrap_err();
        assert!(matches!(err, AvalDecodeError::InvalidArgument(_)));
        // No advance on rejection.
        assert_eq!(seq.next_ordinal(), 0);
    }

    #[test]
    fn accept_rejects_noncontiguous_ordinal() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        assert!(seq.accept(1, &[sample(1, 0, "idle")]).is_err());
        assert_eq!(seq.next_ordinal(), 0);
    }

    #[test]
    fn accept_requires_strictly_increasing_timestamps() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        // Equal timestamps within a batch are rejected.
        assert!(seq
            .accept(1, &[sample(0, 100, "idle"), sample(1, 100, "idle")])
            .is_err());
        // And the batch was atomic: nothing advanced.
        assert_eq!(seq.next_ordinal(), 0);
    }

    #[test]
    fn accept_is_atomic_on_a_mid_batch_failure() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        // Second sample has a bad ordinal (skips 1).
        let err = seq
            .accept(1, &[sample(0, 0, "idle"), sample(2, 20_000, "idle")])
            .unwrap_err();
        assert!(matches!(err, AvalDecodeError::InvalidArgument(_)));
        assert_eq!(seq.next_ordinal(), 0);
    }

    #[test]
    fn abort_only_clears_the_matching_generation() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(5);
        seq.abort(4); // different generation: no-op
        seq.accept(5, &[sample(0, 0, "idle")]).unwrap();
        seq.abort(5); // matching generation clears active
        assert!(seq.accept(5, &[sample(1, 20_000, "idle")]).is_err());
    }

    #[test]
    fn validate_sample_field_checks() {
        // unit_frame must be < unit_frame_count.
        let mut bad = sample(0, 0, "idle");
        bad.unit_frame = 2;
        bad.unit_frame_count = 2;
        assert!(validate_sample(&bad, 0, None).is_err());

        // empty unit_id rejected.
        let empty_id = sample(0, 0, "");
        assert!(validate_sample(&empty_id, 0, None).is_err());

        // empty data rejected.
        let mut empty_data = sample(0, 0, "idle");
        empty_data.data = &[];
        assert!(validate_sample(&empty_data, 0, None).is_err());

        // a well-formed sample passes.
        assert!(validate_sample(&sample(0, 0, "idle"), 0, None).is_ok());
    }
}

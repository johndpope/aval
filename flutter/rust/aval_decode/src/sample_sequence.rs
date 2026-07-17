//! Generation-local independent-unit and decode-order continuity for submitted
//! encoded chunks.
//!
//! Ports `packages/player-web/src/decoder-worker/sample-sequence.ts` (the
//! reworked `DecoderSampleSequence` class, format-1.0 chunk vocabulary) together
//! with the structural slice of `core-validation.ts::validateSampleShape`
//! (lines 195-290) that the sequence relies on to reject a malformed batch
//! before advancing.
//!
//! ## Vocabulary change vs the pre-1.0 fork (samples -> chunks)
//!
//! The old protocol carried a global decode `ordinal` and a single
//! `type: EncodedVideoChunkType` per *sample*. Format 1.0 (upstream merge
//! `67c4c0e`) renames the wire unit to a **chunk** and reshapes it around
//! *independent units*:
//! - `decodeIndex` / `unitChunkCount` — a unit occurrence spans `unitChunkCount`
//!   chunks in decode order (`decodeIndex` `0..unitChunkCount-1`); the old global
//!   `ordinal` is gone and is now derived as [`DecoderSampleSequence::accepted_chunks`]
//!   (TS `nextSubmissionOrdinal = sequence.acceptedChunks`, `core.ts:246`).
//! - `presentationOrdinalBase` + `presentationIndices` — the **decode-chunk vs
//!   displayed-frame distinction**: one chunk maps `displayedFrameCount` outputs
//!   to authored frame indices inside the unit. A hidden VP9/AV1 chunk carries
//!   `displayedFrameCount: 0` and an empty `presentationIndices`; a VP9 superframe
//!   carries N. For H.264 this is always 1:1 (`unitChunkCount == unitFrameCount`,
//!   `decodeIndex == presentationIndices[0]`, `displayedFrameCount == 1`), but the
//!   struct carries the general shape so the Dart caller matches the web protocol.
//! - `randomAccess: boolean` replaces `type: EncodedVideoChunkType`.
//! - `presentationTimestamp` replaces `timestamp`.
//!
//! Error mapping: the TS code throws `PROTOCOL_ERROR` / `GENERATION_MISMATCH`
//! `DecoderWorkerCoreError`s here. Those codes are not part of this crate's C ABI
//! status enum (`error.rs`), so every validation failure is reported as
//! [`AvalDecodeError::InvalidArgument`] with a descriptive `&'static str` — the
//! one intentional error-taxonomy narrowing versus TypeScript.

use std::collections::HashSet;

use crate::error::AvalDecodeError;
use crate::MAX_SAFE_INTEGER;

/// Maximum encoded unit-id length, from `core-validation.ts:215`
/// (`unitId.length` must be between 1 and 128).
pub const MAX_UNIT_ID_LEN: usize = 128;

/// One owned wire-1.0 encoded chunk in decoder submission order. Mirrors the
/// fields of the TS `DecoderWorkerSample` interface (`protocol.ts:91-104`) that
/// carry decode semantics; `data: ArrayBuffer` becomes a byte slice.
///
/// `presentation_indices` maps every displayed output carried by this chunk to
/// its authored frame index inside the unit. Hidden chunks use an empty slice
/// and `displayed_frame_count == 0`. For H.264 there is exactly one entry.
#[derive(Debug, Clone, Copy)]
pub struct DecodeChunk<'a> {
    /// Stable id for the source unit (1..=128 bytes when interpreted as UTF-8).
    pub unit_id: &'a str,
    /// Which occurrence of the unit this chunk belongs to (monotonic per generation).
    pub unit_instance: u64,
    /// This chunk's zero-based index within its unit occurrence's decode order.
    pub decode_index: u64,
    /// Total chunks in this unit occurrence (`decode_index < unit_chunk_count`).
    pub unit_chunk_count: u64,
    /// Total displayed frames in this unit occurrence.
    pub unit_frame_count: u64,
    /// Presentation-ordinal base for the unit; a displayed frame's global ordinal
    /// is `presentation_ordinal_base + presentation_index`.
    pub presentation_ordinal_base: u64,
    /// Authored frame indices (within the unit) for the outputs this chunk yields.
    /// Length must equal `displayed_frame_count`; empty for a hidden chunk.
    pub presentation_indices: &'a [u64],
    /// Presentation timestamp of the chunk's first displayed output.
    pub presentation_timestamp: u64,
    /// Frame duration in the same units as `presentation_timestamp`.
    pub duration: u64,
    /// Whether this chunk begins at random access (TS `randomAccess`, IDR for H.264).
    pub random_access: bool,
    /// Number of displayed frames this chunk yields (0 hidden, 1 for H.264, N for
    /// a VP9/AV1 superframe).
    pub displayed_frame_count: u64,
    /// Encoded chunk bytes (non-empty).
    pub data: &'a [u8],
}

/// Presentation timestamp for the `displayed_index`-th output carried by a chunk
/// (TS `expectedTimestamp` / `checkedTimestamp`): `presentation_timestamp +
/// duration * displayed_index`, rejected if it leaves the safe-integer range.
///
/// # Errors
///
/// [`AvalDecodeError::InvalidArgument`] if the timeline overflows `MAX_SAFE_INTEGER`.
pub fn expected_timestamp(
    chunk: &DecodeChunk<'_>,
    displayed_index: u64,
) -> Result<u64, AvalDecodeError> {
    checked_timestamp(chunk.presentation_timestamp, chunk.duration, displayed_index)
}

fn checked_timestamp(timestamp: u64, duration: u64, index: u64) -> Result<u64, AvalDecodeError> {
    duration
        .checked_mul(index)
        .and_then(|offset| timestamp.checked_add(offset))
        .filter(|&ts| ts <= MAX_SAFE_INTEGER)
        .ok_or(AvalDecodeError::InvalidArgument(
            "decode chunk presentation timeline exceeds safe integers",
        ))
}

/// Validates one chunk's structural shape (TS `validateSampleShape`,
/// `core-validation.ts:195-290`).
///
/// Purely structural WebCodecs/protocol-shape checks that have no meaning for a
/// typed Rust struct (`hasExactKeys`, `data instanceof ArrayBuffer`, JS number
/// integrality) are omitted; every value check that guards decode correctness is
/// kept.
///
/// # Errors
///
/// [`AvalDecodeError::InvalidArgument`] describing the first failed check.
pub fn validate_chunk_shape(chunk: &DecodeChunk<'_>) -> Result<(), AvalDecodeError> {
    let id_len = chunk.unit_id.len();
    if !(1..=MAX_UNIT_ID_LEN).contains(&id_len) {
        return Err(AvalDecodeError::InvalidArgument(
            "decode chunk unitId length must be between 1 and 128",
        ));
    }
    // `unit_instance` / `decode_index` are unsigned, so the "non-negative" checks
    // hold by construction.
    if chunk.unit_chunk_count < 1 {
        return Err(AvalDecodeError::InvalidArgument(
            "decode chunk unitChunkCount must be a positive integer",
        ));
    }
    if chunk.decode_index >= chunk.unit_chunk_count {
        return Err(AvalDecodeError::InvalidArgument(
            "decode chunk decodeIndex exceeds unitChunkCount",
        ));
    }
    if chunk.unit_frame_count < 1 {
        return Err(AvalDecodeError::InvalidArgument(
            "decode chunk unitFrameCount must be a positive integer",
        ));
    }
    if chunk.presentation_ordinal_base > MAX_SAFE_INTEGER - chunk.unit_frame_count {
        return Err(AvalDecodeError::InvalidArgument(
            "presentation ordinal range exceeds safe integers",
        ));
    }
    // TS: `presentationIndices.length !== displayedFrameCount`.
    if chunk.presentation_indices.len() as u64 != chunk.displayed_frame_count {
        return Err(AvalDecodeError::InvalidArgument(
            "presentationIndices must match displayedFrameCount",
        ));
    }
    if chunk.displayed_frame_count > 0 && chunk.duration == 0 {
        return Err(AvalDecodeError::InvalidArgument(
            "displayed chunks must have a positive duration",
        ));
    }
    let mut local_indices = HashSet::new();
    for (index, &presentation_index) in chunk.presentation_indices.iter().enumerate() {
        if presentation_index >= chunk.unit_frame_count {
            return Err(AvalDecodeError::InvalidArgument(
                "presentation index exceeds unitFrameCount",
            ));
        }
        if !local_indices.insert(presentation_index) {
            return Err(AvalDecodeError::InvalidArgument(
                "presentation indices must be unique within a chunk",
            ));
        }
        checked_timestamp(chunk.presentation_timestamp, chunk.duration, index as u64)?;
    }
    if chunk.data.is_empty() {
        return Err(AvalDecodeError::InvalidArgument(
            "decode chunk data must not be empty",
        ));
    }
    Ok(())
}

/// In-flight validation state for one independent-unit occurrence. Mirrors the TS
/// `UnitSequence` interface (`sample-sequence.ts:8-18`).
#[derive(Debug, Clone)]
struct UnitSequence {
    unit_id: String,
    unit_instance: u64,
    unit_chunk_count: u64,
    unit_frame_count: u64,
    presentation_ordinal_base: u64,
    seen_presentation_indices: HashSet<u64>,
    seen_timestamps: HashSet<u64>,
    next_decode_index: u64,
    displayed_frame_count: u64,
}

/// Owns generation-local independent-unit and decode-order continuity.
///
/// Direct port of the reworked TS `DecoderSampleSequence` class.
#[derive(Debug, Default)]
pub struct DecoderSampleSequence {
    active_generation: Option<u64>,
    next_unit_instance: u64,
    active_unit: Option<UnitSequence>,
    accepted_chunks: u64,
}

impl DecoderSampleSequence {
    /// Creates a fresh sequence (no active generation, zero accepted chunks).
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Number of chunks accepted since construction — the global decode ordinal
    /// counter that `core.ts` reports as `nextSubmissionOrdinal`
    /// (TS `get acceptedChunks`).
    #[must_use]
    pub fn accepted_chunks(&self) -> u64 {
        self.accepted_chunks
    }

    /// Marks `generation` active and resets the per-generation unit cursor
    /// (TS `activate`).
    pub fn activate(&mut self, generation: u64) {
        self.active_generation = Some(generation);
        self.next_unit_instance = 0;
        self.active_unit = None;
    }

    /// Clears the active generation and its open unit iff it currently equals
    /// `generation` (TS `abort`).
    pub fn abort(&mut self, generation: u64) {
        if self.active_generation == Some(generation) {
            self.active_generation = None;
            self.active_unit = None;
        }
    }

    /// Unconditionally clears the active generation and its open unit
    /// (TS `clearActive`).
    pub fn clear_active(&mut self) {
        self.active_generation = None;
        self.active_unit = None;
    }

    /// Validates the entire batch atomically, then advances the sequence
    /// (TS `accept`). Nothing is mutated unless every chunk passes: the working
    /// unit/instance cursor is a clone that is committed only on success.
    ///
    /// # Errors
    ///
    /// - [`AvalDecodeError::InvalidArgument`] if `generation` is not the active
    ///   generation (TS `GENERATION_MISMATCH`), any chunk fails
    ///   [`validate_chunk_shape`], or the unit continuity / completeness rules are
    ///   violated (TS `PROTOCOL_ERROR`).
    pub fn accept(
        &mut self,
        generation: u64,
        chunks: &[DecodeChunk<'_>],
    ) -> Result<(), AvalDecodeError> {
        if self.active_generation != Some(generation) {
            return Err(AvalDecodeError::InvalidArgument(
                "decode submission does not target the active generation",
            ));
        }

        let mut next_unit_instance = self.next_unit_instance;
        let mut active_unit = self.active_unit.clone();
        for chunk in chunks {
            validate_chunk_shape(chunk)?;
            if active_unit.is_none() {
                if chunk.decode_index != 0 {
                    return Err(AvalDecodeError::InvalidArgument(
                        "every unit occurrence must begin at decodeIndex zero",
                    ));
                }
                if chunk.unit_instance != next_unit_instance {
                    return Err(AvalDecodeError::InvalidArgument(
                        "unitInstance must equal the next unit instance",
                    ));
                }
                if !chunk.random_access {
                    return Err(AvalDecodeError::InvalidArgument(
                        "every unit occurrence must begin at random access",
                    ));
                }
                if next_unit_instance >= MAX_SAFE_INTEGER {
                    return Err(AvalDecodeError::InvalidArgument(
                        "unitInstance leaves no safe successor",
                    ));
                }
                active_unit = Some(UnitSequence {
                    unit_id: chunk.unit_id.to_owned(),
                    unit_instance: chunk.unit_instance,
                    unit_chunk_count: chunk.unit_chunk_count,
                    unit_frame_count: chunk.unit_frame_count,
                    presentation_ordinal_base: chunk.presentation_ordinal_base,
                    seen_presentation_indices: HashSet::new(),
                    seen_timestamps: HashSet::new(),
                    next_decode_index: 0,
                    displayed_frame_count: 0,
                });
                next_unit_instance += 1;
            }

            let unit = active_unit
                .as_mut()
                .expect("active unit was set above when absent");
            validate_unit_relation(unit, chunk)?;
            for (index, &presentation_index) in chunk.presentation_indices.iter().enumerate() {
                if !unit.seen_presentation_indices.insert(presentation_index) {
                    return Err(AvalDecodeError::InvalidArgument(
                        "unit presentation indices must be unique and complete",
                    ));
                }
                let timestamp = expected_timestamp(chunk, index as u64)?;
                if !unit.seen_timestamps.insert(timestamp) {
                    return Err(AvalDecodeError::InvalidArgument(
                        "unit presentation timestamps must be unique",
                    ));
                }
            }
            unit.displayed_frame_count = unit
                .displayed_frame_count
                .checked_add(chunk.displayed_frame_count)
                .ok_or(AvalDecodeError::InvalidArgument(
                    "unit displayed-frame count is unsafe",
                ))?;
            unit.next_decode_index += 1;
            if unit.next_decode_index == unit.unit_chunk_count {
                if unit.displayed_frame_count != unit.unit_frame_count
                    || unit.seen_presentation_indices.len() as u64 != unit.unit_frame_count
                {
                    return Err(AvalDecodeError::InvalidArgument(
                        "unit displayed-frame metadata is incomplete",
                    ));
                }
                active_unit = None;
            }
        }

        let chunk_count = chunks.len() as u64;
        if self.accepted_chunks > MAX_SAFE_INTEGER - chunk_count {
            return Err(AvalDecodeError::InvalidArgument(
                "accepted chunk count exceeds safe integers",
            ));
        }
        self.next_unit_instance = next_unit_instance;
        self.active_unit = active_unit;
        self.accepted_chunks += chunk_count;
        Ok(())
    }
}

fn validate_unit_relation(
    unit: &UnitSequence,
    chunk: &DecodeChunk<'_>,
) -> Result<(), AvalDecodeError> {
    if chunk.unit_id != unit.unit_id
        || chunk.unit_instance != unit.unit_instance
        || chunk.unit_chunk_count != unit.unit_chunk_count
        || chunk.unit_frame_count != unit.unit_frame_count
        || chunk.presentation_ordinal_base != unit.presentation_ordinal_base
    {
        return Err(AvalDecodeError::InvalidArgument(
            "decode chunks in one unit occurrence must share exact unit metadata",
        ));
    }
    if chunk.decode_index != unit.next_decode_index {
        return Err(AvalDecodeError::InvalidArgument(
            "decodeIndex must equal the unit's next decode index",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 1:1 H.264-style chunk: one chunk == one displayed frame, forming a
    /// complete single-chunk unit.
    fn h264_chunk<'a>(unit_id: &'a str, unit_instance: u64, timestamp: u64) -> DecodeChunk<'a> {
        DecodeChunk {
            unit_id,
            unit_instance,
            decode_index: 0,
            unit_chunk_count: 1,
            unit_frame_count: 1,
            presentation_ordinal_base: 0,
            presentation_indices: &[0],
            presentation_timestamp: timestamp,
            duration: 16_667,
            random_access: true,
            displayed_frame_count: 1,
            data: &[0x01],
        }
    }

    /// Builds one chunk of a multi-chunk unit (mirrors the TS `unitChunk` helper):
    /// three-chunk / three-frame unit, `decodeIndex == presentationIndex`.
    fn unit_chunk<'a>(unit_id: &'a str, decode_index: u64) -> DecodeChunk<'a> {
        const INDICES: [&[u64]; 3] = [&[0], &[1], &[2]];
        DecodeChunk {
            unit_id,
            unit_instance: 0,
            decode_index,
            unit_chunk_count: 3,
            unit_frame_count: 3,
            presentation_ordinal_base: 0,
            presentation_indices: INDICES[decode_index as usize],
            presentation_timestamp: decode_index * 1_000,
            duration: 1_000,
            random_access: decode_index == 0,
            displayed_frame_count: 1,
            data: &[0x01],
        }
    }

    #[test]
    fn accept_advances_accepted_chunks_and_unit_instance() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        // Two complete single-chunk units in one batch: instances 0 then 1.
        seq.accept(1, &[h264_chunk("idle", 0, 0), h264_chunk("idle", 1, 16_667)])
            .unwrap();
        assert_eq!(seq.accepted_chunks(), 2);
        // A third unit continues the instance counter from 2.
        seq.accept(1, &[h264_chunk("idle", 2, 40_000)]).unwrap();
        assert_eq!(seq.accepted_chunks(), 3);
    }

    #[test]
    fn accept_rejects_inactive_generation() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        let err = seq.accept(2, &[h264_chunk("idle", 0, 0)]).unwrap_err();
        assert!(matches!(err, AvalDecodeError::InvalidArgument(_)));
        assert_eq!(seq.accepted_chunks(), 0);
    }

    #[test]
    fn accept_requires_units_to_begin_at_decode_index_zero_and_random_access() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        // A first chunk with decode_index 1 has no open unit -> rejected.
        let mut bad = h264_chunk("idle", 0, 0);
        bad.decode_index = 1;
        bad.unit_chunk_count = 2;
        assert!(seq.accept(1, &[bad]).is_err());
        // A non-key first chunk is rejected.
        let mut not_key = h264_chunk("idle", 0, 0);
        not_key.random_access = false;
        assert!(seq.accept(1, &[not_key]).is_err());
        assert_eq!(seq.accepted_chunks(), 0);
    }

    #[test]
    fn accept_requires_monotonic_unit_instance() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        seq.accept(1, &[h264_chunk("idle", 0, 0)]).unwrap();
        // Next unit must be instance 1, not 0 again.
        assert!(seq.accept(1, &[h264_chunk("idle", 0, 16_667)]).is_err());
        assert_eq!(seq.accepted_chunks(), 1);
    }

    #[test]
    fn accept_keeps_partial_unit_state_across_submits() {
        // Mirrors the TS "keeps partial unit state across submits" case: a
        // three-chunk unit fed one chunk per accept, completing on the third.
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        seq.accept(1, &[unit_chunk("u", 0)]).unwrap();
        seq.accept(1, &[unit_chunk("u", 1)]).unwrap();
        seq.accept(1, &[unit_chunk("u", 2)]).unwrap();
        assert_eq!(seq.accepted_chunks(), 3);
        // The unit closed, so the next occurrence must be instance 1.
        assert!(seq.accept(1, &[unit_chunk("u", 0)]).is_err());
    }

    #[test]
    fn accept_rejects_wrong_decode_index_within_a_unit() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        seq.accept(1, &[unit_chunk("u", 0)]).unwrap();
        // Skipping to decode_index 2 mid-unit is rejected.
        assert!(seq.accept(1, &[unit_chunk("u", 2)]).is_err());
        assert_eq!(seq.accepted_chunks(), 1);
    }

    #[test]
    fn accept_rejects_incomplete_unit_frame_metadata() {
        // A unit that claims 2 frames but only presents 1 across its chunks.
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        let chunk = DecodeChunk {
            unit_frame_count: 2,
            ..h264_chunk("u", 0, 0)
        };
        assert!(seq.accept(1, &[chunk]).is_err());
        assert_eq!(seq.accepted_chunks(), 0);
    }

    #[test]
    fn accept_is_atomic_on_a_mid_batch_failure() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        // First chunk is a valid unit; second reuses instance 0 (must be 1).
        let err = seq
            .accept(1, &[h264_chunk("idle", 0, 0), h264_chunk("idle", 0, 20_000)])
            .unwrap_err();
        assert!(matches!(err, AvalDecodeError::InvalidArgument(_)));
        assert_eq!(seq.accepted_chunks(), 0);
    }

    #[test]
    fn accept_maps_multiple_displayed_outputs_from_one_chunk() {
        // A superframe-style chunk: one chunk, two displayed frames. The sequence
        // is codec-neutral and accepts it (native decode rejects non-H.264 at
        // configure; that gate lives in the session, not here).
        let mut seq = DecoderSampleSequence::new();
        seq.activate(1);
        let chunk = DecodeChunk {
            unit_frame_count: 2,
            presentation_indices: &[0, 1],
            displayed_frame_count: 2,
            ..h264_chunk("sf", 0, 0)
        };
        seq.accept(1, &[chunk]).unwrap();
        assert_eq!(seq.accepted_chunks(), 1);
    }

    #[test]
    fn abort_only_clears_the_matching_generation() {
        let mut seq = DecoderSampleSequence::new();
        seq.activate(5);
        seq.abort(4); // different generation: no-op
        seq.accept(5, &[h264_chunk("idle", 0, 0)]).unwrap();
        seq.abort(5); // matching generation clears active
        assert!(seq.accept(5, &[h264_chunk("idle", 1, 20_000)]).is_err());
    }

    #[test]
    fn validate_chunk_shape_field_checks() {
        // presentationIndices length must equal displayedFrameCount.
        let mut mismatch = h264_chunk("idle", 0, 0);
        mismatch.displayed_frame_count = 2;
        assert!(validate_chunk_shape(&mismatch).is_err());

        // presentation index must be < unit_frame_count.
        let out_of_range = DecodeChunk {
            presentation_indices: &[3],
            ..h264_chunk("idle", 0, 0)
        };
        assert!(validate_chunk_shape(&out_of_range).is_err());

        // empty unit_id rejected.
        assert!(validate_chunk_shape(&h264_chunk("", 0, 0)).is_err());

        // empty data rejected.
        let empty_data = DecodeChunk {
            data: &[],
            ..h264_chunk("idle", 0, 0)
        };
        assert!(validate_chunk_shape(&empty_data).is_err());

        // a well-formed 1:1 chunk passes.
        assert!(validate_chunk_shape(&h264_chunk("idle", 0, 0)).is_ok());
    }
}

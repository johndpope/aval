//! Frame-credit backpressure ledger.
//!
//! A near-1:1 port of `packages/player-web/src/decoder-worker/frame-credit-ledger.ts`
//! (89 LOC). It accounts every decoded frame handed to the caller as a
//! [`FrameLease`] keyed by an incrementing `frame_id`, gating both the number of
//! outstanding frames ([`FrameCreditLedger::has_submission_credit`]) and a
//! decoded-byte budget ([`FrameCreditLedger::lease`]). The caller replenishes
//! credit with [`FrameCreditLedger::release`] once it is done with a frame.
//!
//! Error parity: the three TypeScript `DecoderWorkerCoreError` codes raised here
//! (`DECODED_BYTE_BUDGET_EXCEEDED`, `DECODER_OUTPUT_INVALID`, `FRAME_RELEASE_INVALID`)
//! map to the identically-named [`AvalDecodeError`] variants (see `error.rs`),
//! all of which are `is_fatal() == true`, matching the `fatal: true` flag the
//! TS ledger sets on every throw.

use std::collections::HashMap;

use crate::error::AvalDecodeError;

/// One accounted decoded frame. Mirrors the TS `FrameLease` interface
/// (`frame-credit-ledger.ts:3-6`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FrameLease {
    generation: u64,
    decoded_bytes: u64,
}

/// Accounts decoded frames until the caller releases them.
///
/// Direct port of the TS `FrameCreditLedger` class. `frame_id`s start at 1 and
/// increase monotonically (never reused), so a released id can never be
/// confused with a live one.
#[derive(Debug, Default)]
pub struct FrameCreditLedger {
    leases: HashMap<u64, FrameLease>,
    next_frame_id: u64,
    decoded_bytes: u64,
}

impl FrameCreditLedger {
    /// Creates an empty ledger with `next_frame_id == 1` (TS `#nextFrameId = 1`).
    #[must_use]
    pub fn new() -> Self {
        Self {
            leases: HashMap::new(),
            next_frame_id: 1,
            decoded_bytes: 0,
        }
    }

    /// Number of currently outstanding leases (TS `get count`).
    #[must_use]
    pub fn count(&self) -> usize {
        self.leases.len()
    }

    /// Total leased decoded bytes (TS `get decodedBytes`).
    #[must_use]
    pub fn decoded_bytes(&self) -> u64 {
        self.decoded_bytes
    }

    /// Whether another chunk may be submitted (TS `hasSubmissionCredit`).
    ///
    /// `submitted_frames + leases.len() < maximum_outstanding_frames`.
    #[must_use]
    pub fn has_submission_credit(
        &self,
        submitted_frames: usize,
        maximum_outstanding_frames: usize,
    ) -> bool {
        submitted_frames + self.leases.len() < maximum_outstanding_frames
    }

    /// Leases a newly decoded frame, returning its `frame_id` (TS `lease`).
    ///
    /// # Errors
    ///
    /// - [`AvalDecodeError::DecodedByteBudgetExceeded`] if adding `decoded_bytes`
    ///   would exceed `maximum_decoded_bytes` (TS `DECODED_BYTE_BUDGET_EXCEEDED`).
    /// - [`AvalDecodeError::DecoderOutputInvalid`] if the `frame_id` space is
    ///   exhausted — practically unreachable, kept for parity with the TS
    ///   `Number.isSafeInteger` guard (`DECODER_OUTPUT_INVALID`).
    pub fn lease(
        &mut self,
        generation: u64,
        decoded_bytes: u64,
        maximum_decoded_bytes: u64,
    ) -> Result<u64, AvalDecodeError> {
        // TS: `this.#decodedBytes + decodedBytes > maximumDecodedBytes`. Use a
        // checked add so an arithmetic overflow is reported as the same fatal
        // budget error rather than panicking.
        let projected = self
            .decoded_bytes
            .checked_add(decoded_bytes)
            .ok_or(AvalDecodeError::DecodedByteBudgetExceeded)?;
        if projected > maximum_decoded_bytes {
            return Err(AvalDecodeError::DecodedByteBudgetExceeded);
        }
        let frame_id = self.next_frame_id;
        // TS: `!Number.isSafeInteger(frameId)` -> DECODER_OUTPUT_INVALID.
        let next = frame_id
            .checked_add(1)
            .ok_or(AvalDecodeError::DecoderOutputInvalid)?;
        self.next_frame_id = next;
        self.leases.insert(
            frame_id,
            FrameLease {
                generation,
                decoded_bytes,
            },
        );
        self.decoded_bytes = projected;
        Ok(frame_id)
    }

    /// Releases a lease, replenishing credit (TS `release`).
    ///
    /// # Errors
    ///
    /// [`AvalDecodeError::FrameReleaseInvalid`] if `frame_id` is `0` or does not
    /// correspond to a live lease (including a double release).
    pub fn release(&mut self, frame_id: u64) -> Result<(), AvalDecodeError> {
        let lease = self.require_lease(frame_id)?;
        self.leases.remove(&frame_id);
        // Cannot underflow: `decoded_bytes` always includes every live lease.
        self.decoded_bytes -= lease.decoded_bytes;
        Ok(())
    }

    /// Rolls back a transfer that failed before ownership changed (TS `revoke`).
    ///
    /// # Errors
    ///
    /// Same as [`FrameCreditLedger::release`].
    pub fn revoke(&mut self, frame_id: u64) -> Result<(), AvalDecodeError> {
        self.release(frame_id)
    }

    /// The generation that leased `frame_id`, if it is live. Not present in the
    /// TS source; used by the session to detect stale releases across
    /// generations without exposing the internal map.
    #[must_use]
    pub fn lease_generation(&self, frame_id: u64) -> Option<u64> {
        self.leases.get(&frame_id).map(|lease| lease.generation)
    }

    /// Drops every lease and resets the byte counter (TS `clear`).
    ///
    /// Note: `next_frame_id` is deliberately *not* reset, matching the TS class
    /// (only `#leases`/`#decodedBytes` are cleared), so ids stay unique for the
    /// lifetime of the ledger.
    pub fn clear(&mut self) {
        self.leases.clear();
        self.decoded_bytes = 0;
    }

    /// TS `#requireLease`: `frame_id` must be a positive, currently-owned id.
    fn require_lease(&self, frame_id: u64) -> Result<FrameLease, AvalDecodeError> {
        if frame_id == 0 {
            return Err(AvalDecodeError::FrameReleaseInvalid);
        }
        self.leases
            .get(&frame_id)
            .copied()
            .ok_or(AvalDecodeError::FrameReleaseInvalid)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Mirrors decoder-worker.test.ts's credit-holding assertions and the
    // frame-credit-ledger.ts semantics directly.

    #[test]
    fn has_submission_credit_matches_ts_boundary() {
        let mut ledger = FrameCreditLedger::new();
        // No leases: submitted + 0 < max.
        assert!(ledger.has_submission_credit(0, 2));
        assert!(ledger.has_submission_credit(1, 2));
        assert!(!ledger.has_submission_credit(2, 2));
        // One outstanding lease shifts the boundary down by one.
        ledger.lease(1, 16, 1_000).unwrap();
        assert!(ledger.has_submission_credit(0, 2));
        assert!(!ledger.has_submission_credit(1, 2));
    }

    #[test]
    fn lease_assigns_incrementing_ids_from_one_and_tracks_bytes() {
        let mut ledger = FrameCreditLedger::new();
        assert_eq!(ledger.lease(1, 24, 1_000).unwrap(), 1);
        assert_eq!(ledger.lease(1, 24, 1_000).unwrap(), 2);
        assert_eq!(ledger.count(), 2);
        assert_eq!(ledger.decoded_bytes(), 48);
    }

    #[test]
    fn lease_rejects_budget_overflow_as_fatal() {
        let mut ledger = FrameCreditLedger::new();
        ledger.lease(1, 40, 48).unwrap();
        let err = ledger.lease(1, 24, 48).unwrap_err();
        assert_eq!(err, AvalDecodeError::DecodedByteBudgetExceeded);
        assert!(err.is_fatal());
        // The rejected lease left no residue.
        assert_eq!(ledger.count(), 1);
        assert_eq!(ledger.decoded_bytes(), 40);
    }

    #[test]
    fn release_replenishes_and_rejects_bad_ids() {
        let mut ledger = FrameCreditLedger::new();
        let id = ledger.lease(1, 24, 1_000).unwrap();
        ledger.release(id).unwrap();
        assert_eq!(ledger.count(), 0);
        assert_eq!(ledger.decoded_bytes(), 0);
        // Double release is fatal ownership corruption (TS FRAME_RELEASE_INVALID).
        assert_eq!(
            ledger.release(id).unwrap_err(),
            AvalDecodeError::FrameReleaseInvalid
        );
        // Zero and unknown ids are equally invalid.
        assert_eq!(
            ledger.release(0).unwrap_err(),
            AvalDecodeError::FrameReleaseInvalid
        );
        assert_eq!(
            ledger.release(999).unwrap_err(),
            AvalDecodeError::FrameReleaseInvalid
        );
    }

    #[test]
    fn clear_drops_leases_but_keeps_id_monotonicity() {
        let mut ledger = FrameCreditLedger::new();
        let first = ledger.lease(1, 8, 1_000).unwrap();
        ledger.clear();
        assert_eq!(ledger.count(), 0);
        assert_eq!(ledger.decoded_bytes(), 0);
        // Ids never rewind, so a cleared id can never collide with a live one.
        let next = ledger.lease(2, 8, 1_000).unwrap();
        assert!(next > first);
    }

    #[test]
    fn revoke_is_release() {
        let mut ledger = FrameCreditLedger::new();
        let id = ledger.lease(1, 8, 1_000).unwrap();
        ledger.revoke(id).unwrap();
        assert_eq!(ledger.count(), 0);
    }
}

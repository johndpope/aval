//! C ABI for `dart:ffi`.
//!
//! Every entry point is `extern "C"`, takes/returns `#[repr(C)]` data, and wraps
//! its body in [`std::panic::catch_unwind`] (`Cargo.toml` sets
//! `panic = "unwind"` precisely so a panic becomes [`AvalDecodeStatus::Panicked`]
//! instead of aborting the host process). Errors are reported through the
//! [`AvalDecodeStatus`] return code; there is no other error channel across the
//! boundary (see `error.rs`).
//!
//! Frame ownership: a decoded frame's RGBA bytes stay owned by the Rust session.
//! [`aval_decode_take_frame`] hands out a raw pointer + length that remains valid
//! until [`aval_decode_release_frame`] is called with the same `frame_id`. On the
//! Dart side wrap the pointer with `Pointer<Uint8>.asTypedList(len)` and register
//! a `NativeFinalizer` that calls `aval_decode_release_frame`, so the native
//! allocation is freed exactly once, GC-safe (ARCHITECTURE.md 4).
//!
//! Lifecycle: [`aval_decode_session_create`] -> configure/activate/submit/take/
//! release/... -> [`aval_decode_dispose`] (idempotent logical teardown) ->
//! [`aval_decode_session_destroy`] (frees the handle). Passing a null handle to
//! any call returns [`AvalDecodeStatus::NullPointer`].

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

use crate::decoder::{DecoderSession, SessionConfig, SubmitOutcome};
use crate::error::{AvalDecodeError, AvalDecodeStatus};
use crate::sample_sequence::AccessUnitSample;

/// Opaque session handle. Created by [`aval_decode_session_create`], freed by
/// [`aval_decode_session_destroy`].
pub struct AvalDecoder {
    session: DecoderSession,
}

/// Configuration passed to [`aval_decode_configure`]. Mirrors [`SessionConfig`].
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AvalDecodeConfig {
    /// Coded surface width in pixels.
    pub coded_width: u32,
    /// Coded surface height in pixels.
    pub coded_height: u32,
    /// Outstanding-frame ceiling (1..=12).
    pub max_outstanding_frames: u32,
    /// Exact derived decoded-byte budget.
    pub max_decoded_bytes: u64,
}

/// One access unit passed to [`aval_decode_submit_access_unit`].
///
/// `data`/`unit_id` are borrowed for the duration of the call only; the callee
/// copies whatever it retains.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AvalDecodeSample {
    /// Global decode ordinal.
    pub ordinal: u64,
    /// Presentation timestamp.
    pub timestamp: u64,
    /// Frame duration.
    pub duration: u64,
    /// Source unit instance.
    pub unit_instance: u64,
    /// Frame index within the unit instance.
    pub unit_frame: u64,
    /// Total frames in the unit instance.
    pub unit_frame_count: u64,
    /// Non-zero if this is a key/IDR access unit.
    pub is_key: u8,
    /// Pointer to Annex-B access-unit bytes.
    pub data: *const u8,
    /// Length of `data` in bytes.
    pub data_len: usize,
    /// Pointer to UTF-8 unit-id bytes (1..=128 bytes).
    pub unit_id: *const u8,
    /// Length of `unit_id` in bytes.
    pub unit_id_len: usize,
}

/// Written by [`aval_decode_submit_access_unit`] to report whether a frame was
/// produced.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct AvalSubmitResult {
    /// Non-zero if a frame became available (retrievable via `take_frame`).
    pub produced_frame: u8,
    /// Frame id of the produced frame (only meaningful if `produced_frame != 0`).
    pub frame_id: u64,
}

/// Written by [`aval_decode_take_frame`]. `data` is valid until the matching
/// [`aval_decode_release_frame`]. (`*const u8` defaults to null via `Default`.)
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct AvalDecodeFrame {
    /// Ledger frame id; pass to [`aval_decode_release_frame`].
    pub frame_id: u64,
    /// Pointer to RGBA8888 bytes (Rust-owned).
    pub data: *const u8,
    /// Length of `data` (`width * height * 4`).
    pub len: usize,
    /// Frame width in pixels.
    pub width: u32,
    /// Frame height in pixels.
    pub height: u32,
    /// Global decode/display ordinal.
    pub ordinal: u64,
    /// Presentation timestamp.
    pub timestamp: u64,
    /// Frame duration.
    pub duration: u64,
    /// Source unit instance.
    pub unit_instance: u64,
    /// Frame index within the unit instance.
    pub unit_frame: u64,
}

/// Metrics written by [`aval_decode_snapshot`]. Mirrors
/// [`crate::decoder::DecoderMetrics`]; `active_generation` uses `-1` for "none".
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct AvalDecodeMetrics {
    /// Successful `configure` calls (0 or 1).
    pub configure_calls: u64,
    /// Accepted access units.
    pub accepted_samples: u64,
    /// Access units handed to the decoder.
    pub submitted_chunks: u64,
    /// Frames produced by the decoder.
    pub output_frames: u64,
    /// Frames delivered via `take_frame`.
    pub delivered_frames: u64,
    /// Frames released by the caller.
    pub released_frames: u64,
    /// Currently leased frames.
    pub leased_frames: u64,
    /// Currently leased decoded bytes.
    pub leased_decoded_bytes: u64,
    /// Active generation, or `-1` if none is active.
    pub active_generation: i64,
    /// Next expected submission ordinal.
    pub next_submission_ordinal: u64,
    /// Next expected output ordinal.
    pub next_output_ordinal: u64,
    /// Fatal errors latched by the session.
    pub errors: u64,
    /// Non-zero if the session is disposed.
    pub disposed: u8,
}

/// Creates a new, unconfigured session. Returns a handle to pass to the other
/// entry points, or null if allocation panicked.
///
/// # Safety
///
/// The returned pointer must eventually be freed with
/// [`aval_decode_session_destroy`].
#[no_mangle]
pub extern "C" fn aval_decode_session_create() -> *mut AvalDecoder {
    catch_unwind(|| {
        Box::into_raw(Box::new(AvalDecoder {
            session: DecoderSession::new(),
        }))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Destroys a session handle created by [`aval_decode_session_create`].
///
/// # Safety
///
/// `handle` must be a pointer previously returned by
/// [`aval_decode_session_create`] and not already destroyed. Passing null is a
/// no-op.
#[no_mangle]
pub unsafe extern "C" fn aval_decode_session_destroy(handle: *mut AvalDecoder) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // Reclaim and drop the box.
        drop(unsafe { Box::from_raw(handle) });
    }));
}

/// Configures the session. See [`DecoderSession::configure`].
///
/// # Safety
///
/// `handle` must be valid; `config` must point to a readable [`AvalDecodeConfig`].
#[no_mangle]
pub unsafe extern "C" fn aval_decode_configure(
    handle: *mut AvalDecoder,
    config: *const AvalDecodeConfig,
) -> AvalDecodeStatus {
    with_session(handle, |session| {
        let Some(config) = (unsafe { config.as_ref() }) else {
            return AvalDecodeStatus::NullPointer;
        };
        status_of(session.configure(SessionConfig {
            coded_width: config.coded_width as usize,
            coded_height: config.coded_height as usize,
            max_outstanding_frames: config.max_outstanding_frames as usize,
            max_decoded_bytes: config.max_decoded_bytes,
        }))
    })
}

/// Activates a generation. See [`DecoderSession::activate_generation`].
///
/// # Safety
///
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn aval_decode_activate_generation(
    handle: *mut AvalDecoder,
    generation: u64,
) -> AvalDecodeStatus {
    with_session(handle, |session| {
        status_of(session.activate_generation(generation))
    })
}

/// Aborts the active generation. See [`DecoderSession::abort_generation`].
///
/// # Safety
///
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn aval_decode_abort_generation(
    handle: *mut AvalDecoder,
    generation: u64,
) -> AvalDecodeStatus {
    with_session(handle, |session| {
        status_of(session.abort_generation(generation))
    })
}

/// Submits one access unit for `generation`. See
/// [`DecoderSession::submit_access_unit`].
///
/// On success, `out_result` (if non-null) reports whether a frame was produced
/// and its `frame_id`.
///
/// # Safety
///
/// `handle` must be valid; `sample` must point to a readable [`AvalDecodeSample`]
/// whose `data`/`unit_id` pointers are readable for their declared lengths;
/// `out_result` may be null.
#[no_mangle]
pub unsafe extern "C" fn aval_decode_submit_access_unit(
    handle: *mut AvalDecoder,
    generation: u64,
    sample: *const AvalDecodeSample,
    out_result: *mut AvalSubmitResult,
) -> AvalDecodeStatus {
    with_session(handle, |session| {
        let Some(sample) = (unsafe { sample.as_ref() }) else {
            return AvalDecodeStatus::NullPointer;
        };
        if sample.data.is_null() || sample.unit_id.is_null() {
            return AvalDecodeStatus::NullPointer;
        }
        if sample.data_len == 0 {
            return AvalDecodeStatus::InvalidArgument;
        }
        let data = unsafe { slice::from_raw_parts(sample.data, sample.data_len) };
        let unit_id_bytes = unsafe { slice::from_raw_parts(sample.unit_id, sample.unit_id_len) };
        let Ok(unit_id) = std::str::from_utf8(unit_id_bytes) else {
            return AvalDecodeStatus::InvalidArgument;
        };
        let access_unit = AccessUnitSample {
            ordinal: sample.ordinal,
            unit_id,
            unit_instance: sample.unit_instance,
            unit_frame: sample.unit_frame,
            unit_frame_count: sample.unit_frame_count,
            is_key: sample.is_key != 0,
            timestamp: sample.timestamp,
            duration: sample.duration,
            data,
        };
        match session.submit_access_unit(generation, &access_unit) {
            Ok(outcome) => {
                if !out_result.is_null() {
                    let result = match outcome {
                        SubmitOutcome::Frame { frame_id } => AvalSubmitResult {
                            produced_frame: 1,
                            frame_id,
                        },
                        SubmitOutcome::Priming => AvalSubmitResult::default(),
                    };
                    unsafe { out_result.write(result) };
                }
                AvalDecodeStatus::Ok
            }
            Err(error) => error.status(),
        }
    })
}

/// Removes and returns the next ready frame. See [`DecoderSession::take_frame`].
///
/// Returns [`AvalDecodeStatus::NoFrameAvailable`] when the ready queue is empty.
///
/// # Safety
///
/// `handle` must be valid; `out_frame` must point to a writable
/// [`AvalDecodeFrame`].
#[no_mangle]
pub unsafe extern "C" fn aval_decode_take_frame(
    handle: *mut AvalDecoder,
    out_frame: *mut AvalDecodeFrame,
) -> AvalDecodeStatus {
    with_session(handle, |session| {
        if out_frame.is_null() {
            return AvalDecodeStatus::NullPointer;
        }
        match session.take_frame() {
            Ok(Some(frame)) => {
                let out = AvalDecodeFrame {
                    frame_id: frame.frame_id,
                    data: frame.rgba.as_ptr(),
                    len: frame.rgba.len(),
                    width: frame.width as u32,
                    height: frame.height as u32,
                    ordinal: frame.ordinal,
                    timestamp: frame.timestamp,
                    duration: frame.duration,
                    unit_instance: frame.unit_instance,
                    unit_frame: frame.unit_frame,
                };
                unsafe { out_frame.write(out) };
                AvalDecodeStatus::Ok
            }
            Ok(None) => AvalDecodeStatus::NoFrameAvailable,
            Err(error) => error.status(),
        }
    })
}

/// Releases a frame. See [`DecoderSession::release_frame`]. This is the call a
/// Dart `NativeFinalizer` should invoke.
///
/// # Safety
///
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn aval_decode_release_frame(
    handle: *mut AvalDecoder,
    frame_id: u64,
) -> AvalDecodeStatus {
    with_session(handle, |session| status_of(session.release_frame(frame_id)))
}

/// Writes a metrics snapshot. See [`DecoderSession::snapshot`].
///
/// # Safety
///
/// `handle` must be valid; `out_metrics` must point to a writable
/// [`AvalDecodeMetrics`].
#[no_mangle]
pub unsafe extern "C" fn aval_decode_snapshot(
    handle: *mut AvalDecoder,
    out_metrics: *mut AvalDecodeMetrics,
) -> AvalDecodeStatus {
    with_session(handle, |session| {
        if out_metrics.is_null() {
            return AvalDecodeStatus::NullPointer;
        }
        let metrics = session.snapshot();
        let out = AvalDecodeMetrics {
            configure_calls: metrics.configure_calls,
            accepted_samples: metrics.accepted_samples,
            submitted_chunks: metrics.submitted_chunks,
            output_frames: metrics.output_frames,
            delivered_frames: metrics.delivered_frames,
            released_frames: metrics.released_frames,
            leased_frames: metrics.leased_frames,
            leased_decoded_bytes: metrics.leased_decoded_bytes,
            active_generation: metrics
                .active_generation
                .map_or(-1, |generation| generation as i64),
            next_submission_ordinal: metrics.next_submission_ordinal,
            next_output_ordinal: metrics.next_output_ordinal,
            errors: metrics.errors,
            disposed: u8::from(metrics.disposed),
        };
        unsafe { out_metrics.write(out) };
        AvalDecodeStatus::Ok
    })
}

/// Logical teardown. See [`DecoderSession::dispose`]. Idempotent; the handle is
/// still valid (metrics remain readable) until [`aval_decode_session_destroy`].
///
/// # Safety
///
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn aval_decode_dispose(handle: *mut AvalDecoder) -> AvalDecodeStatus {
    with_session(handle, |session| {
        session.dispose();
        AvalDecodeStatus::Ok
    })
}

/// Runs `body` with a `&mut DecoderSession` behind the handle, catching panics.
fn with_session<F>(handle: *mut AvalDecoder, body: F) -> AvalDecodeStatus
where
    F: FnOnce(&mut DecoderSession) -> AvalDecodeStatus,
{
    if handle.is_null() {
        return AvalDecodeStatus::NullPointer;
    }
    // Safety: the caller contract requires `handle` to be a live pointer from
    // `aval_decode_session_create`; we hold the only reference for this call.
    let decoder = unsafe { &mut *handle };
    catch_unwind(AssertUnwindSafe(|| body(&mut decoder.session)))
        .unwrap_or(AvalDecodeStatus::Panicked)
}

fn status_of(result: Result<(), AvalDecodeError>) -> AvalDecodeStatus {
    match result {
        Ok(()) => AvalDecodeStatus::Ok,
        Err(error) => error.status(),
    }
}

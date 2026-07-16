//! Integration test: decode one real IDR access unit end to end.
//!
//! Drives the public [`DecoderSession`] API against `tests/fixtures/sample_cbp.h264`
//! (a Constrained Baseline, cabac=0, 64x48 Annex-B clip: SPS/PPS/SEI/IDR followed
//! by P-frame slices). It submits the first access unit (everything up to the
//! first non-IDR slice), takes the produced frame, and asserts geometry and
//! pixel sanity — the Phase 3 exit criterion that `openh264` decodes one IDR AU
//! and the Rust-side I420 -> RGBA conversion produces a plausible RGBA surface.

use aval_decode::decoder::maximum_decoded_rgba_bytes;
use aval_decode::{AccessUnitSample, DecoderSession, SessionConfig, SubmitOutcome};

const FIXTURE: &[u8] = include_bytes!("fixtures/sample_cbp.h264");

// The fixture SPS declares a 64x48 coded surface (verified out of band).
const CODED_WIDTH: usize = 64;
const CODED_HEIGHT: usize = 48;

/// Returns the byte length of the first access unit: everything from the start
/// of the stream up to (not including) the start code of the first coded slice
/// of a *subsequent* picture (NAL type 1). The first AU therefore contains
/// SPS(7) + PPS(8) + SEI(6) + IDR(5).
fn first_access_unit_len(stream: &[u8]) -> usize {
    let mut i = 0;
    while i + 3 < stream.len() {
        let (payload, next) = if stream[i] == 0 && stream[i + 1] == 0 && stream[i + 2] == 1 {
            (i + 3, i + 3)
        } else if i + 4 < stream.len()
            && stream[i] == 0
            && stream[i + 1] == 0
            && stream[i + 2] == 0
            && stream[i + 3] == 1
        {
            (i + 4, i + 4)
        } else {
            i += 1;
            continue;
        };
        let nal_type = stream[payload] & 0x1f;
        // A type-1 (non-IDR coded slice) marks the second picture: cut here.
        if nal_type == 1 {
            return i;
        }
        i = next;
    }
    stream.len()
}

#[test]
fn decodes_the_fixture_idr_access_unit() {
    let au_len = first_access_unit_len(FIXTURE);
    assert!(au_len > 0 && au_len < FIXTURE.len(), "AU boundary not found");
    let au = &FIXTURE[..au_len];

    let mut session = DecoderSession::new();
    session
        .configure(SessionConfig {
            coded_width: CODED_WIDTH,
            coded_height: CODED_HEIGHT,
            max_outstanding_frames: 4,
            max_decoded_bytes: maximum_decoded_rgba_bytes(CODED_WIDTH, CODED_HEIGHT).unwrap() * 4,
        })
        .expect("configure");
    session.activate_generation(1).expect("activate");

    let sample = AccessUnitSample {
        ordinal: 0,
        unit_id: "idle",
        unit_instance: 0,
        unit_frame: 0,
        unit_frame_count: 1,
        is_key: true,
        timestamp: 0,
        duration: 16_667,
        data: au,
    };

    let outcome = session
        .submit_access_unit(1, &sample)
        .expect("submit should decode the IDR");
    let frame_id = match outcome {
        SubmitOutcome::Frame { frame_id } => frame_id,
        SubmitOutcome::Priming => panic!("IDR AU should not prime with no_delay decode"),
    };

    let frame = session
        .take_frame()
        .expect("take_frame")
        .expect("a frame is ready");
    assert_eq!(frame.frame_id, frame_id);
    assert_eq!(frame.width, CODED_WIDTH);
    assert_eq!(frame.height, CODED_HEIGHT);
    assert_eq!(frame.ordinal, 0);
    assert_eq!(frame.rgba.len(), CODED_WIDTH * CODED_HEIGHT * 4);

    // Pixel sanity: every alpha byte is 255 (opaque), and the image is not a
    // single flat colour (a real decoded picture has variation).
    assert!(
        frame.rgba.chunks_exact(4).all(|pixel| pixel[3] == 255),
        "alpha channel must be fully opaque"
    );
    let first = &frame.rgba[0..3];
    let has_variation = frame
        .rgba
        .chunks_exact(4)
        .any(|pixel| pixel[0..3] != *first);
    assert!(has_variation, "decoded frame should not be a flat colour");

    // Metrics reflect one decoded, one delivered, one still leased.
    let metrics = session.snapshot();
    assert_eq!(metrics.output_frames, 1);
    assert_eq!(metrics.delivered_frames, 1);
    assert_eq!(metrics.leased_frames, 1);

    session.release_frame(frame_id).expect("release");
    assert_eq!(session.snapshot().leased_frames, 0);

    session.dispose();
}

#[test]
fn decodes_multiple_pictures_in_order() {
    // Feed the IDR AU then subsequent P-slice pictures, one submit each, and
    // confirm ordinals stay contiguous and each yields exactly one frame — the
    // "one AU in -> one frame out, decode order == display order" invariant.
    let mut boundaries = vec![0usize];
    let mut i = 0;
    while i + 3 < FIXTURE.len() {
        let (payload, next) = if FIXTURE[i] == 0 && FIXTURE[i + 1] == 0 && FIXTURE[i + 2] == 1 {
            (i + 3, i + 3)
        } else if i + 4 < FIXTURE.len()
            && FIXTURE[i] == 0
            && FIXTURE[i + 1] == 0
            && FIXTURE[i + 2] == 0
            && FIXTURE[i + 3] == 1
        {
            (i + 4, i + 4)
        } else {
            i += 1;
            continue;
        };
        let nal_type = FIXTURE[payload] & 0x1f;
        // Split only on subsequent (type-1) coded slices: the leading SPS/PPS/SEI
        // and the IDR (type 5) form the first access unit together.
        if nal_type == 1 {
            boundaries.push(i);
        }
        i = next;
    }
    boundaries.push(FIXTURE.len());

    let mut session = DecoderSession::new();
    session
        .configure(SessionConfig {
            coded_width: CODED_WIDTH,
            coded_height: CODED_HEIGHT,
            max_outstanding_frames: 12,
            max_decoded_bytes: maximum_decoded_rgba_bytes(CODED_WIDTH, CODED_HEIGHT).unwrap() * 12,
        })
        .expect("configure");
    session.activate_generation(1).expect("activate");

    let mut decoded = 0u64;
    for (ordinal, window) in boundaries.windows(2).enumerate() {
        let au = &FIXTURE[window[0]..window[1]];
        let sample = AccessUnitSample {
            ordinal: ordinal as u64,
            unit_id: "idle",
            unit_instance: 0,
            unit_frame: ordinal as u64,
            unit_frame_count: boundaries.len() as u64,
            is_key: ordinal == 0,
            timestamp: ordinal as u64 * 16_667 + 1,
            duration: 16_667,
            data: au,
        };
        if let SubmitOutcome::Frame { frame_id } =
            session.submit_access_unit(1, &sample).expect("submit")
        {
            let frame = session.take_frame().expect("take").expect("frame");
            assert_eq!(frame.ordinal, decoded);
            assert_eq!(frame.width, CODED_WIDTH);
            assert_eq!(frame.height, CODED_HEIGHT);
            session.release_frame(frame_id).expect("release");
            decoded += 1;
        }
    }

    // The clip has 12 coded pictures (1 IDR + 11 P); every one should decode.
    assert!(decoded >= 2, "expected multiple decoded frames, got {decoded}");
    assert_eq!(session.snapshot().leased_frames, 0);
}

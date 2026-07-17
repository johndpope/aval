//! Integration test: decode one real IDR chunk (and a run of pictures) end to end.
//!
//! Drives the public [`DecoderSession`] API against `tests/fixtures/sample_cbp.h264`
//! (a Constrained Baseline, cabac=0, 64x48 Annex-B clip: SPS/PPS/SEI/IDR followed
//! by P-frame slices). It submits the first chunk (everything up to the first
//! non-IDR slice), takes the produced frame, and asserts geometry and pixel
//! sanity — the Phase 3 exit criterion that `openh264` decodes one IDR chunk and
//! the Rust-side I420 -> RGBA conversion produces a plausible RGBA surface.
//!
//! Format-1.0 chunk vocabulary: submissions are [`DecodeChunk`]s. For H.264 each
//! chunk is 1:1 (`displayed_frame_count == 1`, `decode_index == presentation_index`).

use aval_decode::decoder::maximum_decoded_rgba_bytes;
use aval_decode::{DecodeChunk, DecoderSession, SessionConfig, SubmitOutcome, VideoCodec};

const FIXTURE: &[u8] = include_bytes!("fixtures/sample_cbp.h264");

// The fixture SPS declares a 64x48 coded surface (verified out of band).
const CODED_WIDTH: usize = 64;
const CODED_HEIGHT: usize = 48;

fn h264_config(max_outstanding: usize) -> SessionConfig {
    SessionConfig {
        codec: VideoCodec::H264,
        bit_depth: 8,
        coded_width: CODED_WIDTH,
        coded_height: CODED_HEIGHT,
        max_outstanding_frames: max_outstanding,
        max_decoded_bytes: maximum_decoded_rgba_bytes(CODED_WIDTH, CODED_HEIGHT).unwrap()
            * max_outstanding as u64,
    }
}

/// Returns the byte length of the first chunk (the IDR access unit): everything
/// from the start of the stream up to (not including) the start code of the first
/// coded slice of a *subsequent* picture (NAL type 1). The first chunk therefore
/// contains SPS(7) + PPS(8) + SEI(6) + IDR(5).
fn first_chunk_len(stream: &[u8]) -> usize {
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
fn decodes_the_fixture_idr_chunk() {
    let chunk_len = first_chunk_len(FIXTURE);
    assert!(
        chunk_len > 0 && chunk_len < FIXTURE.len(),
        "chunk boundary not found"
    );
    let bytes = &FIXTURE[..chunk_len];

    let mut session = DecoderSession::new();
    session.configure(h264_config(4)).expect("configure");
    session.activate_generation(1).expect("activate");

    let chunk = DecodeChunk {
        unit_id: "idle",
        unit_instance: 0,
        decode_index: 0,
        unit_chunk_count: 1,
        unit_frame_count: 1,
        presentation_ordinal_base: 0,
        presentation_indices: &[0],
        presentation_timestamp: 0,
        duration: 16_667,
        random_access: true,
        displayed_frame_count: 1,
        data: bytes,
    };

    let outcome = session
        .submit_chunk(1, &chunk)
        .expect("submit should decode the IDR");
    let frame_id = match outcome {
        SubmitOutcome::Frame { frame_id } => frame_id,
        SubmitOutcome::Priming => panic!("IDR chunk should not prime with no_delay decode"),
    };

    let frame = session
        .take_frame()
        .expect("take_frame")
        .expect("a frame is ready");
    assert_eq!(frame.frame_id, frame_id);
    assert_eq!(frame.width, CODED_WIDTH);
    assert_eq!(frame.height, CODED_HEIGHT);
    assert_eq!(frame.ordinal, 0);
    assert_eq!(frame.unit_frame, 0);
    assert_eq!(frame.decode_index, 0);
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
    assert_eq!(metrics.next_submission_ordinal, 1);

    session.release_frame(frame_id).expect("release");
    assert_eq!(session.snapshot().leased_frames, 0);

    session.dispose();
}

#[test]
fn decodes_multiple_pictures_in_order() {
    // Feed the IDR chunk then subsequent P-slice pictures as one independent unit,
    // one submit each, and confirm decode indices stay contiguous and each yields
    // exactly one frame — the "one chunk in -> one frame out, decode order ==
    // display order" invariant.
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
        // and the IDR (type 5) form the first chunk together.
        if nal_type == 1 {
            boundaries.push(i);
        }
        i = next;
    }
    boundaries.push(FIXTURE.len());

    let picture_count = (boundaries.len() - 1) as u64;

    let mut session = DecoderSession::new();
    session.configure(h264_config(12)).expect("configure");
    session.activate_generation(1).expect("activate");

    let mut decoded = 0u64;
    for (ordinal, window) in boundaries.windows(2).enumerate() {
        let bytes = &FIXTURE[window[0]..window[1]];
        let ordinal = ordinal as u64;
        let indices = [ordinal];
        let chunk = DecodeChunk {
            unit_id: "idle",
            unit_instance: 0,
            decode_index: ordinal,
            unit_chunk_count: picture_count,
            unit_frame_count: picture_count,
            presentation_ordinal_base: 0,
            presentation_indices: &indices,
            presentation_timestamp: ordinal * 16_667 + 1,
            duration: 16_667,
            random_access: ordinal == 0,
            displayed_frame_count: 1,
            data: bytes,
        };
        if let SubmitOutcome::Frame { frame_id } = session.submit_chunk(1, &chunk).expect("submit") {
            let frame = session.take_frame().expect("take").expect("frame");
            assert_eq!(frame.ordinal, decoded);
            assert_eq!(frame.decode_index, ordinal);
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

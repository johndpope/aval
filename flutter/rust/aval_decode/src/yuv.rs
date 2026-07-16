//! Planar I420 (YUV 4:2:0) -> RGBA8888 conversion, BT.709 limited-range.
//!
//! There is no analog to this step in the web player: WebCodecs' `VideoFrame`
//! performed YUV->RGB invisibly before the renderer ran (ARCHITECTURE.md 3.3).
//! With the `openh264` core the decoder yields planar I420, so this crate must
//! convert explicitly, immediately after decode, so the buffer that crosses the
//! FFI boundary is already RGBA (matching what WebCodecs produced in v1).
//!
//! Per ARCHITECTURE.md risk register #13 this is a first-class, independently
//! tested unit: [`i420_to_rgba`] is a pure function and [`yuv_to_rgb`] exposes
//! the single-pixel kernel so the coefficients can be pinned against known
//! test patterns with exact expected RGBA output.
//!
//! # Coefficients
//!
//! BT.709, limited ("studio") range: luma in `[16, 235]`, chroma in `[16, 240]`.
//! With `Kr = 0.2126`, `Kb = 0.0722`, `Kg = 1 - Kr - Kb = 0.7152`:
//!
//! ```text
//! c = Y - 16,  d = U - 128,  e = V - 128
//! Yp = (255 / 219) * c                                   = 1.164383 * c
//! R  = Yp + (255 / 224) * 2 * (1 - Kr) * e               = Yp + 1.792741 * e
//! G  = Yp - (255 / 224) * 2 * (1 - Kb) * (Kb / Kg) * d
//!         - (255 / 224) * 2 * (1 - Kr) * (Kr / Kg) * e   = Yp - 0.213249 * d - 0.532909 * e
//! B  = Yp + (255 / 224) * 2 * (1 - Kb) * d               = Yp + 2.112402 * d
//! ```
//!
//! Each channel is rounded to nearest and clamped to `[0, 255]`; alpha is always
//! `255` (the decoded picture is opaque — the AVAL packed-alpha layout carries
//! its alpha as a *second luma pane* within the same picture, handled downstream
//! by the renderer, not here).

use crate::error::AvalDecodeError;

/// Bytes per output pixel (R, G, B, A).
pub const RGBA_BYTES_PER_PIXEL: usize = 4;

// BT.709 limited-range coefficients (see module docs for derivation).
const Y_MUL: f32 = 1.164_383;
const RV_MUL: f32 = 1.792_741;
const GU_MUL: f32 = -0.213_249;
const GV_MUL: f32 = -0.532_909;
const BU_MUL: f32 = 2.112_402;

/// Required RGBA output length for a `width` x `height` image, or `None` on
/// overflow.
#[must_use]
pub fn rgba_len(width: usize, height: usize) -> Option<usize> {
    width
        .checked_mul(height)
        .and_then(|pixels| pixels.checked_mul(RGBA_BYTES_PER_PIXEL))
}

/// Converts a single limited-range BT.709 YUV triple to non-premultiplied RGB.
///
/// Exposed so the conversion kernel can be tested and reasoned about
/// independently of plane/stride bookkeeping.
#[must_use]
pub fn yuv_to_rgb(y: u8, u: u8, v: u8) -> [u8; 3] {
    let c = f32::from(y) - 16.0;
    let d = f32::from(u) - 128.0;
    let e = f32::from(v) - 128.0;
    let yp = Y_MUL * c;
    let r = RV_MUL.mul_add(e, yp);
    let g = GV_MUL.mul_add(e, GU_MUL.mul_add(d, yp));
    let b = BU_MUL.mul_add(d, yp);
    [clamp_round(r), clamp_round(g), clamp_round(b)]
}

#[inline]
fn clamp_round(value: f32) -> u8 {
    // Round half away from zero, then clamp into the u8 range.
    let rounded = value.round();
    if rounded <= 0.0 {
        0
    } else if rounded >= 255.0 {
        255
    } else {
        rounded as u8
    }
}

/// Converts a planar I420 image to a tightly-packed RGBA8888 buffer.
///
/// `y_stride` is the byte stride of the luma plane; `uv_stride` is the byte
/// stride of *each* chroma plane. Strides may exceed the visible width (as they
/// do in `openh264`'s decoded buffers) — only the visible `width` x `height`
/// region is read and written. The output is written row-major, top-down, with
/// no padding (`width * height * 4` bytes) and alpha fixed at `255`.
///
/// # Errors
///
/// [`AvalDecodeError::InvalidArgument`] if the dimensions are zero, if a stride
/// is narrower than its plane's visible width, if `out` is not exactly
/// `width * height * 4` bytes, or if any input plane is too small for the
/// declared dimensions and strides.
#[allow(clippy::too_many_arguments)]
pub fn i420_to_rgba(
    y_plane: &[u8],
    u_plane: &[u8],
    v_plane: &[u8],
    width: usize,
    height: usize,
    y_stride: usize,
    uv_stride: usize,
    out: &mut [u8],
) -> Result<(), AvalDecodeError> {
    if width == 0 || height == 0 {
        return Err(AvalDecodeError::InvalidArgument(
            "i420_to_rgba requires non-zero width and height",
        ));
    }
    // 4:2:0 chroma is half-resolution, rounded up for odd dimensions.
    let chroma_width = width.div_ceil(2);
    let chroma_height = height.div_ceil(2);
    if y_stride < width || uv_stride < chroma_width {
        return Err(AvalDecodeError::InvalidArgument(
            "i420_to_rgba stride is narrower than the plane width",
        ));
    }
    let wanted = rgba_len(width, height).ok_or(AvalDecodeError::InvalidArgument(
        "i420_to_rgba output length overflows",
    ))?;
    if out.len() != wanted {
        return Err(AvalDecodeError::InvalidArgument(
            "i420_to_rgba output buffer length does not match width * height * 4",
        ));
    }
    // Last byte read from each plane must be in bounds.
    let y_needed = (height - 1) * y_stride + width;
    let uv_needed = (chroma_height - 1) * uv_stride + chroma_width;
    if y_plane.len() < y_needed || u_plane.len() < uv_needed || v_plane.len() < uv_needed {
        return Err(AvalDecodeError::InvalidArgument(
            "i420_to_rgba input plane is too small for the declared geometry",
        ));
    }

    for row in 0..height {
        let y_row = row * y_stride;
        let uv_row = (row / 2) * uv_stride;
        let out_row = row * width * RGBA_BYTES_PER_PIXEL;
        for col in 0..width {
            let y = y_plane[y_row + col];
            let chroma_col = col / 2;
            let u = u_plane[uv_row + chroma_col];
            let v = v_plane[uv_row + chroma_col];
            let [r, g, b] = yuv_to_rgb(y, u, v);
            let base = out_row + col * RGBA_BYTES_PER_PIXEL;
            out[base] = r;
            out[base + 1] = g;
            out[base + 2] = b;
            out[base + 3] = 255;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `(input YUV, expected RGB)` pair.
    type Vector = ((u8, u8, u8), (u8, u8, u8));

    // Expected RGB values were derived independently from the BT.709 limited-range
    // formula in the module docs (rounded to nearest, clamped to [0, 255]); they
    // are hardcoded here rather than recomputed with the same code so the test is
    // not tautological. See risk register #13.
    const VECTORS: &[Vector] = &[
        ((16, 128, 128), (0, 0, 0)),        // limited-range black
        ((235, 128, 128), (255, 255, 255)), // limited-range white
        ((126, 128, 128), (128, 128, 128)), // neutral mid-gray
        ((90, 240, 16), (0, 122, 255)),
        ((81, 90, 240), (255, 24, 0)),
        ((145, 54, 34), (0, 216, 0)),
    ];

    #[test]
    fn single_pixel_kernel_matches_known_vectors() {
        for &((y, u, v), (r, g, b)) in VECTORS {
            assert_eq!(yuv_to_rgb(y, u, v), [r, g, b], "yuv_to_rgb({y}, {u}, {v})");
        }
    }

    #[test]
    fn converts_a_uniform_2x2_patch_for_every_vector() {
        // A 2x2 image where all four luma samples share one chroma sample; every
        // output pixel must equal the vector's expected RGBA, alpha == 255.
        for &((y, u, v), (r, g, b)) in VECTORS {
            let y_plane = [y; 4];
            let u_plane = [u; 1];
            let v_plane = [v; 1];
            let mut out = [0u8; 16];
            i420_to_rgba(&y_plane, &u_plane, &v_plane, 2, 2, 2, 1, &mut out).unwrap();
            for pixel in out.chunks_exact(4) {
                assert_eq!(pixel, [r, g, b, 255]);
            }
        }
    }

    #[test]
    fn maps_luma_positions_through_stride_correctly() {
        // Neutral chroma so output is grayscale; distinct luma per pixel verifies
        // row/column indexing. Luma stride (4) is wider than width (2).
        // Y=16 -> 0, Y=235 -> 255, Y=126 -> 128.
        let y_plane = [
            16, 235, 0xEE, 0xEE, // row 0 visible: 16, 235; padding beyond width
            126, 235, 0xEE, 0xEE, // row 1 visible: 126, 235
        ];
        let u_plane = [128u8; 1];
        let v_plane = [128u8; 1];
        let mut out = [0u8; 16];
        i420_to_rgba(&y_plane, &u_plane, &v_plane, 2, 2, 4, 1, &mut out).unwrap();
        assert_eq!(&out[0..4], &[0, 0, 0, 255]); // (0,0) Y=16
        assert_eq!(&out[4..8], &[255, 255, 255, 255]); // (1,0) Y=235
        assert_eq!(&out[8..12], &[128, 128, 128, 255]); // (0,1) Y=126
        assert_eq!(&out[12..16], &[255, 255, 255, 255]); // (1,1) Y=235
    }

    #[test]
    fn rejects_bad_geometry_and_buffers() {
        let y = [16u8; 4];
        let u = [128u8; 1];
        let v = [128u8; 1];
        let mut out = [0u8; 16];
        // zero dimension
        assert!(i420_to_rgba(&y, &u, &v, 0, 2, 2, 1, &mut out).is_err());
        // stride narrower than width
        assert!(i420_to_rgba(&y, &u, &v, 2, 2, 1, 1, &mut out).is_err());
        // wrong output length
        let mut short = [0u8; 8];
        assert!(i420_to_rgba(&y, &u, &v, 2, 2, 2, 1, &mut short).is_err());
        // input plane too small
        let tiny = [16u8; 1];
        assert!(i420_to_rgba(&tiny, &u, &v, 2, 2, 2, 1, &mut out).is_err());
    }

    #[test]
    fn rgba_len_computes_and_detects_overflow() {
        assert_eq!(rgba_len(64, 48), Some(64 * 48 * 4));
        assert_eq!(rgba_len(usize::MAX, 2), None);
    }
}

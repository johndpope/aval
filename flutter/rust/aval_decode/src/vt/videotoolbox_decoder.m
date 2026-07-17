// VideoToolbox H.264 decode backend for aval_decode (ARCHITECTURE.md §2(c)).
//
// Exposes a tiny C ABI consumed by the Rust `VideoToolboxAdapter`
// (src/adapter.rs). One Annex-B access unit in, at most one decoded RGBA8888
// picture out, in DECODE order (temporal processing disabled) — matching the
// exact contract the OpenH264 backend already satisfies, so the session's
// frame-credit ledger, decode-order continuity, and container-driven
// presentation ordering are all unaffected by the backend swap.
//
// Why Objective-C rather than raw CoreMedia FFI from Rust: the CoreMedia /
// VideoToolbox / CoreVideo call sequence (format-description creation, sample
// buffer construction, decompression session lifecycle, pixel-buffer lock and
// stride-aware readback) is far less error-prone here, where the SDK headers
// and CF ownership rules are first-class. CF handles are released explicitly;
// only the ObjC wrapper object is ARC-managed.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

// ---------------------------------------------------------------------------
// C ABI (mirrored by extern "C" decls in src/adapter.rs).
// ---------------------------------------------------------------------------
typedef struct AvalVtDecoder AvalVtDecoder;

AvalVtDecoder *aval_vt_create(void);
// Returns: 1 = frame produced, 0 = priming (no output), -1 = error.
int aval_vt_decode(AvalVtDecoder *dec, const uint8_t *data, size_t len,
                   uint8_t **out_rgba, size_t *out_len, uint32_t *out_width,
                   uint32_t *out_height);
void aval_vt_free_frame(uint8_t *rgba);
void aval_vt_destroy(AvalVtDecoder *dec);

// ---------------------------------------------------------------------------
// Decoder object.
// ---------------------------------------------------------------------------
@interface AvalVtDecoderObjc : NSObject
@end

@implementation AvalVtDecoderObjc {
  CMVideoFormatDescriptionRef _format;
  VTDecompressionSessionRef _session;

  uint8_t *_sps;
  size_t _spsLen;
  uint8_t *_pps;
  size_t _ppsLen;

  // Set by the synchronous decode output handler.
  CVImageBufferRef _captured;
}

- (void)dealloc {
  [self teardownSession];
  free(_sps);
  free(_pps);
}

- (void)teardownSession {
  if (_session) {
    VTDecompressionSessionInvalidate(_session);
    CFRelease(_session);
    _session = NULL;
  }
  if (_format) {
    CFRelease(_format);
    _format = NULL;
  }
}

// Replace a cached parameter set; returns YES if the bytes changed.
static BOOL replaceParam(uint8_t **slot, size_t *slotLen, const uint8_t *src,
                         size_t len) {
  if (*slot && *slotLen == len && memcmp(*slot, src, len) == 0) {
    return NO;
  }
  free(*slot);
  *slot = malloc(len);
  memcpy(*slot, src, len);
  *slotLen = len;
  return YES;
}

// (Re)create the format description + decompression session from cached
// SPS/PPS. Returns YES on success.
- (BOOL)ensureSession {
  if (_session && _format) {
    return YES;
  }
  if (!_sps || !_pps) {
    return NO; // No parameter sets seen yet.
  }

  const uint8_t *const paramPtrs[2] = {_sps, _pps};
  const size_t paramSizes[2] = {_spsLen, _ppsLen};
  CMVideoFormatDescriptionRef format = NULL;
  OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
      kCFAllocatorDefault, 2, paramPtrs, paramSizes,
      /*NALUnitHeaderLength=*/4, &format);
  if (status != noErr || !format) {
    return NO;
  }

  // Request BGRA output so the readback path is a fixed, well-supported format
  // on every Apple GPU; the Rust side swizzles nothing — this ObjC writes RGBA.
  const int32_t pixelFormat = kCVPixelFormatType_32BGRA;
  CFNumberRef pixelFormatNum =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixelFormat);
  const void *keys[] = {kCVPixelBufferPixelFormatTypeKey};
  const void *values[] = {pixelFormatNum};
  CFDictionaryRef destAttrs = CFDictionaryCreate(
      kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFRelease(pixelFormatNum);

  VTDecompressionSessionRef session = NULL;
  status = VTDecompressionSessionCreate(kCFAllocatorDefault, format,
                                        /*decoderSpecification=*/NULL, destAttrs,
                                        /*outputCallback=*/NULL, &session);
  CFRelease(destAttrs);
  if (status != noErr || !session) {
    CFRelease(format);
    return NO;
  }

  _format = format;
  _session = session;
  return YES;
}

// Decode one Annex-B access unit. Fills out params on a produced frame.
// Returns 1 / 0 / -1 as documented on aval_vt_decode.
- (int)decode:(const uint8_t *)data
          len:(size_t)len
      outRgba:(uint8_t **)outRgba
       outLen:(size_t *)outLen
     outWidth:(uint32_t *)outWidth
    outHeight:(uint32_t *)outHeight {
  // --- Scan Annex-B NAL units; cache SPS/PPS, collect VCL payloads as AVCC. ---
  BOOL paramsChanged = NO;
  // AVCC output buffer grows as VCL NALs are appended (4-byte length + payload).
  uint8_t *avcc = NULL;
  size_t avccLen = 0;

  size_t i = 0;
  while (i + 3 < len) {
    // Find a start code (00 00 01 or 00 00 00 01).
    if (!(data[i] == 0 && data[i + 1] == 0 &&
          (data[i + 2] == 1 || (data[i + 2] == 0 && i + 3 < len && data[i + 3] == 1)))) {
      i++;
      continue;
    }
    size_t startCodeLen = (data[i + 2] == 1) ? 3 : 4;
    size_t nalStart = i + startCodeLen;
    if (nalStart >= len) {
      break;
    }
    // Find the next start code to bound this NAL.
    size_t j = nalStart;
    while (j + 2 < len &&
           !(data[j] == 0 && data[j + 1] == 0 &&
             (data[j + 2] == 1 ||
              (data[j + 2] == 0 && j + 3 < len && data[j + 3] == 1)))) {
      j++;
    }
    size_t nalEnd = (j + 2 < len) ? j : len;
    size_t nalLen = nalEnd - nalStart;
    if (nalLen == 0) {
      i = nalEnd;
      continue;
    }
    uint8_t nalType = data[nalStart] & 0x1f;

    if (nalType == 7) {
      paramsChanged |= replaceParam(&_sps, &_spsLen, &data[nalStart], nalLen);
    } else if (nalType == 8) {
      paramsChanged |= replaceParam(&_pps, &_ppsLen, &data[nalStart], nalLen);
    } else if (nalType >= 1 && nalType <= 5) {
      // VCL slice: append as a 4-byte-big-endian length-prefixed AVCC unit.
      uint8_t *grown = realloc(avcc, avccLen + 4 + nalLen);
      if (!grown) {
        free(avcc);
        return -1;
      }
      avcc = grown;
      avcc[avccLen + 0] = (uint8_t)((nalLen >> 24) & 0xff);
      avcc[avccLen + 1] = (uint8_t)((nalLen >> 16) & 0xff);
      avcc[avccLen + 2] = (uint8_t)((nalLen >> 8) & 0xff);
      avcc[avccLen + 3] = (uint8_t)(nalLen & 0xff);
      memcpy(avcc + avccLen + 4, &data[nalStart], nalLen);
      avccLen += 4 + nalLen;
    }
    // SEI (6), AUD (9), and everything else are dropped.
    i = nalEnd;
  }

  // If parameter sets changed, rebuild the session before decoding.
  if (paramsChanged) {
    [self teardownSession];
  }
  if (![self ensureSession]) {
    free(avcc);
    // No session yet (parameter sets not seen) and no VCL to decode: priming.
    return 0;
  }
  if (avccLen == 0) {
    free(avcc);
    return 0; // Parameter-set-only access unit: priming, no picture.
  }

  // --- Wrap the AVCC bytes in a CMSampleBuffer. ---
  CMBlockBufferRef blockBuffer = NULL;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, /*memoryBlock=*/NULL, avccLen,
      kCFAllocatorDefault, /*customBlockSource=*/NULL, 0, avccLen, 0,
      &blockBuffer);
  if (status != kCMBlockBufferNoErr || !blockBuffer) {
    free(avcc);
    return -1;
  }
  status = CMBlockBufferReplaceDataBytes(avcc, blockBuffer, 0, avccLen);
  free(avcc);
  if (status != kCMBlockBufferNoErr) {
    CFRelease(blockBuffer);
    return -1;
  }

  CMSampleBufferRef sampleBuffer = NULL;
  const size_t sampleSize = avccLen;
  status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuffer, _format,
                                     1, 0, NULL, 1, &sampleSize, &sampleBuffer);
  CFRelease(blockBuffer);
  if (status != noErr || !sampleBuffer) {
    return -1;
  }

  // --- Decode synchronously, in decode order (no temporal reordering). ---
  _captured = NULL;
  VTDecodeInfoFlags infoFlags = 0;
  // flags = 0: synchronous (no kVTDecodeFrame_EnableAsynchronousDecompression)
  // and no kVTDecodeFrame_EnableTemporalProcessing → output in decode order,
  // one picture per frame, delivered before this call returns.
  status = VTDecompressionSessionDecodeFrameWithOutputHandler(
      _session, sampleBuffer, /*decodeFlags=*/0, &infoFlags,
      ^(OSStatus handlerStatus, VTDecodeInfoFlags handlerInfoFlags,
        CVImageBufferRef imageBuffer, CMTime pts, CMTime dur) {
        (void)handlerInfoFlags;
        (void)pts;
        (void)dur;
        if (handlerStatus == noErr && imageBuffer) {
          _captured = CVPixelBufferRetain(imageBuffer);
        }
      });
  CFRelease(sampleBuffer);
  if (status != noErr) {
    if (_captured) {
      CVPixelBufferRelease(_captured);
      _captured = NULL;
    }
    return -1;
  }
  if (!_captured) {
    return 0; // Decoder accepted the frame but produced no picture (priming).
  }

  // --- Read back BGRA → RGBA, stride-aware. ---
  CVPixelBufferRef pixelBuffer = _captured;
  _captured = NULL;
  CVReturn lock = CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  if (lock != kCVReturnSuccess) {
    CVPixelBufferRelease(pixelBuffer);
    return -1;
  }
  const size_t width = CVPixelBufferGetWidth(pixelBuffer);
  const size_t height = CVPixelBufferGetHeight(pixelBuffer);
  const size_t srcStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
  const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);

  int result = -1;
  const size_t rgbaLen = width * height * 4;
  uint8_t *rgba = malloc(rgbaLen);
  if (rgba && src) {
    for (size_t y = 0; y < height; y++) {
      const uint8_t *srcRow = src + y * srcStride;
      uint8_t *dstRow = rgba + y * width * 4;
      for (size_t x = 0; x < width; x++) {
        // Source is BGRA; write RGBA.
        dstRow[x * 4 + 0] = srcRow[x * 4 + 2]; // R
        dstRow[x * 4 + 1] = srcRow[x * 4 + 1]; // G
        dstRow[x * 4 + 2] = srcRow[x * 4 + 0]; // B
        dstRow[x * 4 + 3] = srcRow[x * 4 + 3]; // A
      }
    }
    *outRgba = rgba;
    *outLen = rgbaLen;
    *outWidth = (uint32_t)width;
    *outHeight = (uint32_t)height;
    result = 1;
  } else {
    free(rgba);
  }

  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferRelease(pixelBuffer);
  return result;
}

@end

// ---------------------------------------------------------------------------
// C ABI shims.
// ---------------------------------------------------------------------------
struct AvalVtDecoder {
  void *obj; // retained AvalVtDecoderObjc *
};

AvalVtDecoder *aval_vt_create(void) {
  AvalVtDecoder *dec = malloc(sizeof(AvalVtDecoder));
  if (!dec) {
    return NULL;
  }
  AvalVtDecoderObjc *obj = [[AvalVtDecoderObjc alloc] init];
  dec->obj = (__bridge_retained void *)obj;
  return dec;
}

int aval_vt_decode(AvalVtDecoder *dec, const uint8_t *data, size_t len,
                   uint8_t **out_rgba, size_t *out_len, uint32_t *out_width,
                   uint32_t *out_height) {
  if (!dec || !dec->obj) {
    return -1;
  }
  AvalVtDecoderObjc *obj = (__bridge AvalVtDecoderObjc *)dec->obj;
  return [obj decode:data
                 len:len
             outRgba:out_rgba
              outLen:out_len
            outWidth:out_width
           outHeight:out_height];
}

void aval_vt_free_frame(uint8_t *rgba) { free(rgba); }

void aval_vt_destroy(AvalVtDecoder *dec) {
  if (!dec) {
    return;
  }
  if (dec->obj) {
    // __bridge_transfer hands the +1 retain back to ARC; the temporary is
    // released at the end of this statement, deallocating the decoder.
    (void)(__bridge_transfer AvalVtDecoderObjc *)dec->obj;
    dec->obj = NULL;
  }
  free(dec);
}

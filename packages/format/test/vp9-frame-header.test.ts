import { describe, expect, it } from "vitest";

import { FormatError } from "../src/errors.js";
import { parseVp9FrameHeader } from "../src/vp9/frame-header.js";

const KEY_64_X_32_BT709 = Uint8Array.of(
  0x82, 0x49, 0x83, 0x42, 0x40, 0x03, 0xf0, 0x01, 0xf6, 0x08
);

describe("VP9 uncompressed frame headers", () => {
  it("parses a limited-range BT.709 profile-0 key frame", () => {
    expect(parseVp9FrameHeader(KEY_64_X_32_BT709)).toEqual({
      profile: 0,
      key: true,
      showFrame: true,
      showExistingFrame: false,
      displayedFrameCount: 1,
      errorResilient: false,
      width: 64,
      height: 32,
      renderWidth: 64,
      renderHeight: 32,
      color: {
        bitDepth: 8,
        chromaSubsampling: 1,
        colorPrimaries: 1,
        transferCharacteristics: 1,
        matrixCoefficients: 1,
        fullRange: false
      }
    });
  });

  it("retains hidden inter and show-existing semantics", () => {
    expect(parseVp9FrameHeader(Uint8Array.of(0x84))).toMatchObject({
      key: false,
      showFrame: false,
      showExistingFrame: false,
      displayedFrameCount: 0
    });
    expect(parseVp9FrameHeader(Uint8Array.of(0x88))).toMatchObject({
      key: false,
      showFrame: true,
      showExistingFrame: true,
      displayedFrameCount: 1
    });
  });

  it("rejects truncation, profiles other than zero, and wrong color", () => {
    for (const bytes of [
      new Uint8Array(),
      Uint8Array.of(0x82, 0x49),
      Uint8Array.of(0x92),
      Uint8Array.of(0x82, 0x49, 0x83, 0x42, 0x00, 0x03, 0xf0, 0x01, 0xf6)
    ]) {
      expect(() => parseVp9FrameHeader(bytes)).toThrow(FormatError);
    }
  });
});

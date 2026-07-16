import { FormatError } from "../errors.js";

/** Bounded MSB-first AV1 syntax reader. */
export class Av1BitReader {
  readonly #bytes: Uint8Array;
  readonly #path: string;
  #bitOffset = 0;

  public constructor(bytes: Uint8Array, path: string) {
    this.#bytes = bytes;
    this.#path = path;
  }

  public get bitOffset(): number {
    return this.#bitOffset;
  }

  public get bitsRemaining(): number {
    return this.#bytes.byteLength * 8 - this.#bitOffset;
  }

  public readBit(label: string): boolean {
    if (this.#bitOffset >= this.#bytes.byteLength * 8) {
      this.#fail(`truncated ${label}`);
    }
    const byte = this.#bytes[Math.floor(this.#bitOffset / 8)];
    if (byte === undefined) this.#fail(`truncated ${label}`);
    const shift = 7 - (this.#bitOffset % 8);
    this.#bitOffset += 1;
    return ((byte >> shift) & 1) === 1;
  }

  public readBits(width: number, label: string): number {
    if (!Number.isInteger(width) || width < 0 || width > 32) {
      this.#fail(`invalid bit width for ${label}`);
    }
    if (this.bitsRemaining < width) this.#fail(`truncated ${label}`);
    let value = 0;
    for (let index = 0; index < width; index += 1) {
      value = value * 2 + (this.readBit(label) ? 1 : 0);
    }
    return value;
  }

  public readTrailingBits(): void {
    if (!this.readBit("trailing_one_bit")) {
      this.#fail("trailing_one_bit must equal one");
    }
    while (this.bitsRemaining > 0) {
      if (this.readBit("trailing_zero_bit")) {
        this.#fail("trailing_zero_bit must equal zero");
      }
    }
  }

  #fail(message: string): never {
    throw new FormatError("PROFILE_INVALID", `AV1 ${message}`, {
      path: this.#path,
      offset: Math.floor(this.#bitOffset / 8)
    });
  }
}

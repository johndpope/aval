export interface SeededGenerator {
  nextUint32(): number;
  integer(maximumInclusive: number): number;
}

export const RELEASE_INTEGER_LIMITS = Object.freeze([
  32,
  64,
  128,
  256,
  1_024,
  4_096,
  100_000,
  200_000,
  1_048_576,
  16_777_216,
  1_073_741_824,
  Number.MAX_SAFE_INTEGER
]);

export function createSeededGenerator(seed: number): SeededGenerator {
  if (!Number.isSafeInteger(seed) || seed < 0 || seed > 0xffff_ffff) throw new RangeError("seed must be a uint32");
  let state = seed >>> 0;
  return Object.freeze({
    nextUint32() {
      state ^= state << 13;
      state ^= state >>> 17;
      state ^= state << 5;
      return state >>> 0;
    },
    integer(maximumInclusive: number) {
      if (!Number.isSafeInteger(maximumInclusive) || maximumInclusive < 0 || maximumInclusive > 0xffff_ffff) throw new RangeError("maximumInclusive is invalid");
      return this.nextUint32() % (maximumInclusive + 1);
    }
  });
}

export function boundaryValues(limit: number, cases: number, generator: SeededGenerator): readonly number[] {
  if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError("limit must be a positive safe integer");
  if (!Number.isSafeInteger(cases) || cases < 3 || cases > 100_000) throw new RangeError("cases must be in 3..100000");
  const values = [limit - 1, limit, limit === Number.MAX_SAFE_INTEGER ? limit : limit + 1];
  while (values.length < cases) {
    const spread = Math.min(limit, 0xffff_ffff);
    values.push(generator.integer(spread));
  }
  return values;
}

export function mutateOneField(input: unknown, fieldPath: readonly (string | number)[], replacement: unknown): unknown {
  const clone = structuredClone(input);
  let current: unknown = clone;
  for (let index = 0; index < fieldPath.length - 1; index += 1) {
    const part = fieldPath[index];
    if ((typeof part !== "string" && typeof part !== "number") || current === null || typeof current !== "object") throw new TypeError("mutation path is invalid");
    current = (current as Record<string | number, unknown>)[part];
  }
  const last = fieldPath.at(-1);
  if (last === undefined || current === null || typeof current !== "object") throw new TypeError("mutation path is invalid");
  (current as Record<string | number, unknown>)[last] = replacement;
  return clone;
}

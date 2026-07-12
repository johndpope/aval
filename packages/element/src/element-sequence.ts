/** Fail closed before an element-local identity can lose integer precision. */
export function nextElementSequence(
  value: number,
  name: string,
  maximum = Number.MAX_SAFE_INTEGER
): number {
  if (!Number.isSafeInteger(maximum) || maximum < 1) {
    throw new RangeError(`element ${name} sequence maximum is invalid`);
  }
  if (!Number.isSafeInteger(value) || value < 0 || value >= maximum) {
    throw new Error(`element ${name} sequence is exhausted`);
  }
  return value + 1;
}

export function addElementCount(value: number, delta: number, name: string): number {
  if (
    !Number.isSafeInteger(value) || value < 0 ||
    !Number.isSafeInteger(delta) || delta < 0 ||
    value > Number.MAX_SAFE_INTEGER - delta
  ) throw new Error(`element ${name} count is exhausted`);
  return value + delta;
}

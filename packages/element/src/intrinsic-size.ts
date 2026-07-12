export interface IntrinsicSizeInput {
  readonly width: number;
  readonly height: number;
  readonly pixelAspect: readonly [number, number];
}

export interface IntrinsicSizeResult {
  readonly width: number;
  readonly height: number;
  readonly aspectRatio: number;
}

export function computeIntrinsicSize(
  input: Readonly<IntrinsicSizeInput>
): Readonly<IntrinsicSizeResult> {
  const [pixelAspectNumerator, pixelAspectDenominator] = input.pixelAspect;
  if (
    !Number.isSafeInteger(input.width) || input.width < 1 ||
    !Number.isSafeInteger(input.height) || input.height < 1 ||
    !Number.isSafeInteger(pixelAspectNumerator) || pixelAspectNumerator < 1 ||
    !Number.isSafeInteger(pixelAspectDenominator) || pixelAspectDenominator < 1
  ) {
    throw new RangeError("intrinsic size requires positive integer canvas geometry");
  }
  return Object.freeze({
    width: input.width * pixelAspectNumerator / pixelAspectDenominator,
    height: input.height,
    aspectRatio:
      input.width * pixelAspectNumerator /
      (input.height * pixelAspectDenominator)
  });
}

export function applyIntrinsicSize(
  target: Readonly<{
    setIntrinsicSize(input: Readonly<{
      aspectRatio: number | null;
      width: number | null;
      height: number | null;
    }>): boolean;
  }>,
  intrinsic: Readonly<IntrinsicSizeResult> | null,
  widthHint: number | null,
  heightHint: number | null
): boolean {
  const aspect = intrinsic?.aspectRatio ?? (
    widthHint !== null && heightHint !== null ? widthHint / heightHint : null
  );
  const width = widthHint ?? (
    heightHint !== null && aspect !== null ? heightHint * aspect : intrinsic?.width ?? null
  );
  const height = heightHint ?? (
    widthHint !== null && aspect !== null ? widthHint / aspect : intrinsic?.height ?? null
  );
  return target.setIntrinsicSize(Object.freeze({ aspectRatio: aspect, width, height }));
}

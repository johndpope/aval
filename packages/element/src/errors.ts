export class RenderedMotionEnvironmentError extends Error {
  public constructor(message = "rendered-motion requires a browser custom-element environment") {
    super(message);
    this.name = "NotSupportedError";
  }
}

export class RenderedMotionNotReadyError extends Error {
  public constructor(message = "rendered-motion is not ready") {
    super(message);
    this.name = "NotReadyError";
  }
}

export function renderedMotionAbortError(message = "rendered-motion operation was aborted"): Error {
  const error = new Error(message);
  error.name = "AbortError";
  return error;
}

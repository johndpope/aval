/** Reconcile ambiguous registry writes by observing state after every mutation attempt. */
export function reconcileRegistryMutation({ planned, mutate, readState, certification }) {
  if (planned.result === "already-exact" || planned.result === "conflict") return Object.freeze({ operation: planned, error: null });
  if (planned.result !== "planned") throw new Error("registry reconciler requires a planned operation");
  let mutationError = null;
  try { mutate(); }
  catch (error) { mutationError = error; }
  let observed;
  try { observed = readState(); }
  catch (readError) {
    return Object.freeze({
      operation: certification.markPublicationOperationAmbiguous(planned),
      error: new AggregateError(mutationError === null ? [readError] : [mutationError, readError], "registry mutation outcome is ambiguous")
    });
  }
  try {
    const completed = certification.completePublicationOperation(planned, observed);
    return Object.freeze({ operation: completed, error: null, reconciledAfterMutationError: mutationError !== null });
  } catch (verificationError) {
    return Object.freeze({
      operation: certification.failPublicationOperation(planned, observed),
      error: mutationError === null ? verificationError : new AggregateError([mutationError, verificationError], "registry mutation failed and post-state is not exact")
    });
  }
}

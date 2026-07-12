export type ElementTerminalOperation = () =>
  boolean | void | Promise<boolean | void>;

/** Runs every terminal owner in order and converts all failures to one boolean. */
export async function aggregateElementTerminalCleanup(
  operations: readonly ElementTerminalOperation[]
): Promise<boolean> {
  let complete = true;
  for (const operation of operations) {
    try {
      if (await operation() === false) complete = false;
    } catch { complete = false; }
  }
  return complete;
}

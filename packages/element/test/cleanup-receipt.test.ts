import { describe, expect, it } from "vitest";

import { captureCleanupReceipt } from "../src/cleanup-receipt.js";

describe("cleanup receipt", () => {
  it("proves a cleaned acquisition participant without requiring an active player", () => {
    const receipt = captureCleanupReceipt({
      elementGeneration: 3,
      sourceGeneration: 7,
      participantId: 1 as never,
      participant: {
        snapshot: () => ({
          disposed: true,
          generation: null,
          account: {
            participantId: 1,
            activeLeaseCount: 0,
            disposed: true,
            participant: null
          },
          lifecycle: lifecycle()
        })
      } as never,
      pageRuntime: {
        snapshot: () => ({
          disposed: false,
          activeParticipants: 0,
          resources: { physicalBytes: 0, participants: [] },
          decoders: {
            activeLeaseCount: 0,
            queuedTicketCount: 0,
            parkedTicketCount: 0,
            tickets: []
          },
          reclamation: {}
        })
      } as never,
      session: null,
      planes: null,
      composition: null,
      player: null,
      operationFailureCount: 0
    });
    expect(receipt).toMatchObject({
      elementGeneration: 3,
      sourceGeneration: 7,
      completed: true,
      failureCount: 0,
      participantDisposed: true,
      participantRegistered: false
    });
    expect(Object.isFrozen(receipt)).toBe(true);
  });

  it("never throws on hostile terminal snapshots and fails closed", () => {
    const hostile = { snapshot: () => { throw new Error("snapshot failed"); } };
    const receipt = captureCleanupReceipt({
      elementGeneration: 1,
      sourceGeneration: 2,
      participantId: 1 as never,
      participant: hostile as never,
      pageRuntime: hostile as never,
      session: null,
      planes: null,
      composition: null,
      player: null,
      operationFailureCount: 0
    });
    expect(receipt.completed).toBe(false);
    expect(receipt.failureCount).toBeGreaterThan(0);
    expect(receipt).toMatchObject({
      participantDisposed: false,
      participantRegisteredCleanupCount: 1,
      participantTrackedWorkCount: 1,
      participantPendingWaitCount: 1
    });
  });
});

function lifecycle() {
  return {
    currentGeneration: null,
    reservedGeneration: 1,
    state: "disposed",
    registeredCleanupCount: 0,
    trackedWorkCount: 0,
    pendingWaitCount: 0,
    cleanupFailureCount: 0,
    retiredGenerationCount: 1
  };
}

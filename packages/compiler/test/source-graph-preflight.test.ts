import { describe, expect, it } from "vitest";

import { CompilerError } from "../src/diagnostics.js";
import type { SourceProject } from "../src/model.js";
import { preflightSourceGraph } from "../src/source-graph-preflight.js";

describe("source graph preflight", () => {
  it("accepts a valid locked portal route before media work", () => {
    expect(() => preflightSourceGraph(project())).not.toThrow();
  });

  it("rejects missing ports and impossible portal waits", () => {
    const missingPort = structuredClone(project()) as any;
    missingPort.edges[0].start.targetPort = "missing";
    expect(() => preflightSourceGraph(missingPort)).toThrow(CompilerError);

    const impossibleWait = structuredClone(project()) as any;
    impossibleWait.edges[0].start.maxWaitFrames = 0;
    expect(() => preflightSourceGraph(impossibleWait)).toThrow(CompilerError);
  });

  it("rejects a locked transition that references a body unit", () => {
    const value = structuredClone(project()) as any;
    value.edges[0].transition.unit = "idle-body";
    expect(() => preflightSourceGraph(value)).toThrow(
      /must be a bridge unit/u
    );
  });
});

function project(): SourceProject {
  return {
    projectVersion: "1.0",
    alpha: "opaque",
    canvas: {
      width: 32,
      height: 32,
      fit: "contain",
      pixelAspect: [1, 1],
      colorSpace: "srgb"
    },
    frameRate: { numerator: 30, denominator: 1 },
    sources: [{
      id: "frames",
      type: "png-sequence",
      directory: "frames",
      prefix: "frame-",
      digits: 4,
      suffix: ".png",
      firstNumber: 0,
      frameCount: 6
    }],
    encodings: [{
      codec: "h264",
      preset: "medium",
      renditions: [{ id: "opaque", width: 32, height: 32, crf: 20 }]
    }],
    units: [
      {
        id: "active-body",
        kind: "body",
        source: "frames",
        range: [4, 6],
        playback: "loop",
        ports: [{ id: "default", entryFrame: 0, portalFrames: [1] }]
      },
      {
        id: "bridge",
        kind: "bridge",
        source: "frames",
        range: [2, 4]
      },
      {
        id: "idle-body",
        kind: "body",
        source: "frames",
        range: [0, 2],
        playback: "loop",
        ports: [{ id: "default", entryFrame: 0, portalFrames: [1] }]
      }
    ],
    initialState: "idle",
    states: [
      { id: "active", bodyUnit: "active-body" },
      { id: "idle", bodyUnit: "idle-body" }
    ],
    edges: [{
      id: "idle-active",
      from: "idle",
      to: "active",
      trigger: { type: "event", name: "engage" },
      start: {
        type: "portal",
        sourcePort: "default",
        targetPort: "default",
        maxWaitFrames: 1
      },
      transition: { kind: "locked", unit: "bridge" },
      continuity: "exact-authored"
    }],
    bindings: [{ source: "pointer.enter", event: "engage" }]
  };
}

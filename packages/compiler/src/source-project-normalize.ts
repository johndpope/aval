import { cloneVideoEncodings } from "./compile/video-encoding-policy.js";
import type {
  NormalizedSourceProject,
  SourceProject
} from "./model.js";

/** Resolve author dimensions and freeze the canonical compiler project model. */
export function normalizeSourceProject(
  project: Readonly<SourceProject>
): Readonly<NormalizedSourceProject> {
  return Object.freeze({
    projectVersion: project.projectVersion,
    alpha: project.alpha,
    canvas: project.canvas,
    frameRate: project.frameRate,
    sources: project.sources,
    encodings: cloneVideoEncodings(project.encodings, project.canvas),
    units: project.units,
    initialState: project.initialState,
    states: project.states,
    edges: project.edges,
    bindings: project.bindings
  });
}

import { defineRenderedMotionElement, type RenderedMotionElement } from "@rendered-motion/element";
import { parseFrontIndex } from "@rendered-motion/format";
import type { MotionGraphDefinition } from "@rendered-motion/graph";
import type { IntegratedPlayer } from "@rendered-motion/player-web";

defineRenderedMotionElement();
const parse: typeof parseFrontIndex = parseFrontIndex;
const element: RenderedMotionElement | null = null;
const graph: MotionGraphDefinition | null = null;
const player: IntegratedPlayer | null = null;
void [parse, element, graph, player];

// @ts-expect-error source-private paths are not public package API.
import("@rendered-motion/player-web/src/runtime/page-resource-manager.js");

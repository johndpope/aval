import * as graph from "@rendered-motion/graph";
import * as format from "@rendered-motion/format";
import * as compiler from "@rendered-motion/compiler";
import * as playerWeb from "@rendered-motion/player-web";
import * as element from "@rendered-motion/element";

for (const [name, module] of Object.entries({ graph, format, compiler, playerWeb, element })) {
  if (Object.keys(module).length === 0) throw new Error(`${name} has no public exports`);
}
if (typeof element.defineRenderedMotionElement !== "function") throw new Error("element root has no definition helper");
process.stdout.write("node-esm-consumer:passed\n");

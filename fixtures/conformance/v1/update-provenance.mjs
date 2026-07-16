#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const fixture = dirname(fileURLToPath(import.meta.url));
const root = resolve(fixture, "../../..");
const output = resolve(fixture, "provenance.json");
const codecs = Object.freeze(["av1", "vp9", "h265", "h264"]);

async function descriptor(path) {
  const bytes = await readFile(resolve(root, path));
  return {
    path,
    bytes: bytes.byteLength,
    sha256: createHash("sha256").update(bytes).digest("hex")
  };
}

async function main() {
  const report = JSON.parse(await readFile(resolve(fixture, "build.json"), "utf8"));
  if (
    report.reportVersion !== "1.0" ||
    JSON.stringify(report.assets?.map(({ codec }) => codec)) !== JSON.stringify(codecs)
  ) {
    throw new Error("build.json is not the canonical ordered four-codec report");
  }
  const sourceProvenanceBytes = await readFile(
    resolve(root, "fixtures/compiler/v1/provenance.json")
  );
  const document = {
    provenanceVersion: "1.0",
    formatVersion: "1.0",
    fixture: "aval-v1-four-codec-bundle",
    license: "CC0-1.0 generated fixture sources",
    rebuild: "node packages/compiler/dist/cli.js compile fixtures/compiler/v1/source/motion.json --out fixtures/conformance/v1 --force",
    source: await descriptor("fixtures/compiler/v1/source/motion.json"),
    sourceProvenance: {
      provenancePath: "fixtures/compiler/v1/provenance.json",
      provenanceSha256: createHash("sha256")
        .update(sourceProvenanceBytes)
        .digest("hex")
    },
    buildReport: await descriptor("fixtures/conformance/v1/build.json"),
    outputs: await Promise.all(codecs.map((codec) =>
      descriptor(`fixtures/conformance/v1/${codec}.avl`)
    )),
    codecStrings: Object.fromEntries(report.assets.map(({ codec, codecString }) => [
      codec,
      codecString
    ])),
    toolchain: report.toolchain
  };
  const serialized = `${JSON.stringify(document, null, 2)}\n`;
  if (process.argv.includes("--check")) {
    const current = await readFile(output, "utf8");
    if (current !== serialized) throw new Error(`${relative(root, output)} drifted`);
    return;
  }
  await writeFile(output, serialized);
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 1;
});

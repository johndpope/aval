#!/usr/bin/env node
import { createHash } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { basename, dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import { verifyCandidateArtifactSet } from "./candidate-root.mjs";
import { readVerifiedRegularFile } from "./candidate-artifacts.mjs";

const scriptRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const parsed = parseArguments(process.argv.slice(2));
const root = resolve(parsed["repository-root"] ?? scriptRoot);
const certification = await import(resolve(scriptRoot, "packages/certification/dist/index.js"));
const artifactIndexPath = required(parsed, "artifacts");
const output = resolve(root, parsed.output ?? "artifacts/1.0.0/candidate-manifest.json");
const candidateRoot = resolve(root, parsed.root ?? dirname(output));
const resolvedIndexPath = resolve(root, artifactIndexPath);
const indexBytes = await readVerifiedRegularFile(basename(resolvedIndexPath), dirname(resolvedIndexPath), 16 * 1024 * 1024);
let index;
try { index = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(indexBytes)); }
catch (error) { throw new Error("artifact index is not strict UTF-8 JSON", { cause: error }); }
if (!Array.isArray(index.artifacts) || index.artifacts.length === 0) throw new Error("artifact index must contain artifacts");
const artifactSet = await verifyCandidateArtifactSet({ root: candidateRoot, artifacts: index.artifacts });
const status = spawnSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" });
if (status.status !== 0) throw new Error("could not inspect git status");
if (status.stdout.trim().length !== 0) throw new Error("candidate manifest requires a clean tree");
const commit = git("rev-parse", "HEAD");
const tree = git("rev-parse", "HEAD^{tree}");
if (artifactSet.layout.commit !== commit || artifactSet.layout.tree !== tree) throw new Error("candidate layout does not identify the immutable source commit/tree");
const policy = artifactSet.policy;
const tools = {
  node: process.versions.node,
  npm: gitCommand("npm", "--version"),
  typescript: packageVersion("typescript"),
  vitest: packageVersion("vitest"),
  playwright: packageVersion("@playwright/test"),
  apiExtractor: packageVersion("@microsoft/api-extractor")
};
certification.validateCandidateToolchain(policy.toolchain, tools);
const browserManifestBytes = requireText(resolve(scriptRoot, "node_modules/playwright-core/browsers.json"));
const browserManifest = JSON.parse(browserManifestBytes);
const browserPin = {
  playwrightBrowserManifestSha256: createHash("sha256").update(browserManifestBytes).digest("hex"),
  browsers: Object.fromEntries(["chromium", "firefox", "webkit"].map((name) => {
    const actual = browserManifest.browsers.find((entry) => entry.name === name);
    const expected = policy.ci.playwrightBrowsers[name];
    if (actual === undefined || expected === undefined || actual.revision !== expected.revision || actual.browserVersion !== expected.engineVersion) {
      throw new Error(`Playwright ${name} revision/engine does not match the candidate pin`);
    }
    return [name, { revision: actual.revision, engineVersion: actual.browserVersion }];
  }))
};
if (browserPin.playwrightBrowserManifestSha256 !== policy.ci.playwrightBrowserManifestSha256) throw new Error("Playwright browser manifest does not match the candidate pin");
const manifest = {
  schemaVersion: "1.0",
  manifestKind: "candidate",
  releaseVersion: "1.0.0",
  releaseSetDigest: artifactSet.releaseSet.releaseSetDigest,
  commit,
  tree,
  cleanTree: true,
  createdAt: parsed["created-at"] ?? new Date(git("show", "-s", "--format=%cI", "HEAD")).toISOString(),
  tools,
  browserPin,
  artifacts: index.artifacts
};
certification.validateCandidateManifest(manifest);
const canonical = certification.canonicalJsonBytes(manifest);
const digest = createHash("sha256").update(canonical).digest("hex");
if (parsed["expected-digest"] !== undefined && parsed["expected-digest"] !== digest) throw new Error("created candidate manifest does not match --expected-digest");
await writeFile(output, canonical, { flag: "wx" });
process.stdout.write(`${JSON.stringify({ output: relative(root, output), sha256: digest, releaseSetDigest: artifactSet.releaseSet.releaseSetDigest }, null, 2)}\n`);

function packageVersion(name) {
  return JSON.parse(requireText(resolve(scriptRoot, "node_modules", name, "package.json"))).version;
}
function requireText(path) {
  const result = spawnSync(process.execPath, ["-e", "process.stdout.write(require('node:fs').readFileSync(process.argv[1], 'utf8'))", path], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(`could not read ${path}`);
  return result.stdout;
}
function git(...args) { return gitCommand("git", ...args); }
function gitCommand(command, ...args) {
  const result = spawnSync(command, args, { cwd: root, encoding: "utf8" });
  if (result.status !== 0) throw new Error(result.stderr || `${command} failed`);
  return result.stdout.trim();
}
function parseArguments(args) {
  const result = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    if (!key?.startsWith("--")) throw new Error(`invalid argument ${key}`);
    result[key.slice(2)] = args[index + 1] ?? "true";
  }
  return result;
}
function required(values, key) {
  const value = values[key];
  if (value === undefined) throw new Error(`--${key} is required`);
  return value;
}

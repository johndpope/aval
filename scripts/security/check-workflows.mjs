#!/usr/bin/env node
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";

const directory = ".github/workflows";
const failures = [];
for (const name of (await readdir(directory)).filter((value) => /\.ya?ml$/u.test(value)).sort()) {
  const text = await readFile(join(directory, name), "utf8");
  const lines = text.split(/\r?\n/u);
  for (const [index, line] of lines.entries()) {
    const action = line.match(/uses:\s*([^\s#]+)@([^\s#]+)/u);
    if (action !== null && !/^[0-9a-f]{40}$/u.test(action[2] ?? "")) failures.push(`${name}:${index + 1}: action is not pinned to a full commit`);
  }
  if (!/permissions:\s*\n(?:\s+[^\n]+\n)*?\s+contents:\s*read/mu.test(text)) failures.push(`${name}: missing read-only contents permission`);
  if (!/timeout-minutes:/u.test(text)) failures.push(`${name}: every workflow must bound job time`);
  if (/actions\/checkout/u.test(text) && !/persist-credentials:\s*false/u.test(text)) failures.push(`${name}: checkout credentials must not persist`);
  if (/pull_request:/u.test(text) && /id-token:\s*write/u.test(text)) failures.push(`${name}: pull request workflow has id-token authority`);
  for (const location of inputExpressionsInRunBlocks(lines)) failures.push(`${name}:${location}: dispatch input expression must pass through a validated environment variable, never shell source`);
  const installs = [...text.matchAll(/npm install[^\n]*/gu)].map((match) => match[0]);
  for (const install of installs) if (!(new Set(["publish.yml", "rollback.yml"]).has(name) && install === "npm install --global npm@11.5.1")) failures.push(`${name}: workflow must use npm ci; only the exact trusted-publishing CLI install is allowed`);
  if (/actions\/upload-artifact/u.test(text)) {
    if (!/retention-days:\s*(?:30|90)\b/u.test(text)) failures.push(`${name}: uploaded artifacts require bounded reviewed retention`);
    if (!/if-no-files-found:\s*(?:error|warn)\b/u.test(text)) failures.push(`${name}: artifact upload must declare missing-file behavior`);
  }
  if (name === "release-candidate.yml") {
    for (const required of ["environment: release-candidate", "cancel-in-progress: false", "validate-workflow-inputs.mjs candidate", "path: artifacts/1.0.0/candidate"]) if (!text.includes(required)) failures.push(`${name}: missing protected candidate invariant ${required}`);
    if (/path:\s*artifacts\/1\.0\.0\s*$/mu.test(text)) failures.push(`${name}: must not upload loose duplicate release artifacts`);
  }
  if (name === "release-reports.yml") {
    if ((text.match(/^\s+run-id:/gmu) ?? []).length !== 2 || (text.match(/^\s+github-token:/gmu) ?? []).length !== 2) failures.push(`${name}: candidate and raw evidence downloads require exact cross-run bindings`);
    for (const required of [
      "environment: release-reports",
      "validate-workflow-inputs.mjs reports",
      "verify-workflow-run.mjs",
      ".github/workflows/release-candidate.yml",
      "render-report-index.mjs",
      "validate-report-index.mjs",
      "--require-passed true",
      "--require-closed-root true",
      "path: incoming/reports"
    ]) if (!text.includes(required)) failures.push(`${name}: missing protected report-assembly invariant ${required}`);
  }
  if (name === "release-final.yml") {
    if ((text.match(/^\s+run-id:/gmu) ?? []).length !== 2 || (text.match(/^\s+github-token:/gmu) ?? []).length !== 2) failures.push(`${name}: both cross-run input artifacts require exact run IDs and GitHub tokens`);
    for (const required of ["environment: release-final", "Protected release-reports workflow run ID", "verify-workflow-run.mjs", ".github/workflows/release-reports.yml", "finalize-release.mjs", "path: artifacts/final-release"]) if (!text.includes(required)) failures.push(`${name}: missing final-release invariant ${required}`);
  }
  if (name === "publish.yml") {
    if ((text.match(/^\s+run-id:/gmu) ?? []).length !== 2 || (text.match(/^\s+github-token:/gmu) ?? []).length !== 2) failures.push(`${name}: each final-release download requires exact run binding`);
    for (const required of ["environment: npm-publish-next", "environment: npm-promote-latest", "needs: publish-next", "expected-release-set-digest", "NPM_SHORT_LIVED_DIST_TAG_TOKEN", "test-registry-consumers.mjs"]) if (!text.includes(required)) failures.push(`${name}: missing protected publication invariant ${required}`);
    if (/release:pack|build-packages\.mjs/u.test(text)) failures.push(`${name}: publication must never rebuild release packages`);
  }
  if (name === "rollback.yml") {
    if ((text.match(/^\s+run-id:/gmu) ?? []).length !== 3 || (text.match(/^\s+github-token:/gmu) ?? []).length !== 3) failures.push(`${name}: rollback inputs require three exact cross-run artifact bindings`);
    for (const required of ["environment: npm-rollback", "NPM_SHORT_LIVED_DIST_TAG_TOKEN", "rollback-dist-tags.mjs", "expected-release-set-digest"]) if (!text.includes(required)) failures.push(`${name}: missing protected rollback invariant ${required}`);
  }
}
if (failures.length > 0) throw new Error(failures.join("\n"));
process.stdout.write(`${JSON.stringify({ status: "passed" })}\n`);

function inputExpressionsInRunBlocks(lines) {
  const locations = [];
  let blockIndent = null;
  for (const [index, line] of lines.entries()) {
    const indent = line.match(/^\s*/u)?.[0].length ?? 0;
    if (blockIndent !== null && line.trim() !== "" && indent <= blockIndent) blockIndent = null;
    const start = /^(\s*)run:\s*(.*)$/u.exec(line);
    if (start !== null) {
      blockIndent = start[2] === "|" || start[2] === ">" ? start[1].length : null;
      if (/\$\{\{\s*inputs\./u.test(start[2])) locations.push(index + 1);
      continue;
    }
    if (blockIndent !== null && /\$\{\{\s*inputs\./u.test(line)) locations.push(index + 1);
  }
  return locations;
}

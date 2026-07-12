#!/usr/bin/env node
import { spawnSync } from "node:child_process";

const mode = process.argv[2];
if (!new Set(["candidate", "authorize", "reports", "finalize", "publish", "rollback", "checkout"]).has(mode)) throw new Error("workflow input validation mode is invalid");
const commit = required("INPUT_COMMIT");
if (!/^[0-9a-f]{40}$/u.test(commit)) throw new Error("workflow commit must be one full lowercase SHA-1 object ID");
if (mode === "candidate" || mode === "authorize") {
  exact(required("GITHUB_EVENT_NAME"), "workflow_dispatch", "workflow event");
  exact(required("GITHUB_REF_NAME"), required("GITHUB_DEFAULT_BRANCH"), "protected default branch");
  if (mode === "candidate") exact(commit, required("GITHUB_SHA"), "default-branch dispatch commit");
  else if (!isAncestor(commit, "HEAD")) throw new Error("authorized release commit is not contained in the protected default branch");
  if (git("status", "--porcelain") !== "") throw new Error("protected workflow checkout is not clean");
}
if (mode === "candidate") {
  exact(required("INPUT_RELEASE_VERSION"), "1.0.0", "release version");
}
if (mode === "reports") {
  runId("INPUT_CANDIDATE_RUN_ID");
  artifactName("INPUT_CANDIDATE_ARTIFACT");
  digest("INPUT_CANDIDATE_DIGEST");
  runId("INPUT_RAW_REPORT_RUN_ID");
  artifactName("INPUT_RAW_REPORT_ARTIFACT");
  workflowPath("INPUT_RAW_REPORT_WORKFLOW");
}
if (mode === "finalize") {
  runId("INPUT_CANDIDATE_RUN_ID");
  artifactName("INPUT_CANDIDATE_ARTIFACT");
  digest("INPUT_CANDIDATE_DIGEST");
  runId("INPUT_REPORT_RUN_ID");
  artifactName("INPUT_REPORT_ARTIFACT");
  digest("INPUT_REPORT_INDEX_DIGEST");
  timestamp("INPUT_CREATED_AT");
}
if (mode === "publish") {
  runId("INPUT_RELEASE_RUN_ID");
  artifactName("INPUT_RELEASE_ARTIFACT");
  for (const name of ["INPUT_CANDIDATE_DIGEST", "INPUT_RELEASE_DIGEST", "INPUT_RELEASE_SET_DIGEST"]) digest(name);
  approval("INPUT_PUBLISH_APPROVAL");
  approval("INPUT_PROMOTION_APPROVAL");
  if (process.env.INPUT_PUBLISH_APPROVAL === process.env.INPUT_PROMOTION_APPROVAL) throw new Error("publication and promotion approvals must be distinct");
}
if (mode === "rollback") {
  runId("INPUT_RELEASE_RUN_ID");
  artifactName("INPUT_RELEASE_ARTIFACT");
  runId("INPUT_LEDGER_RUN_ID");
  artifactName("INPUT_LEDGER_ARTIFACT");
  digest("INPUT_LEDGER_DIGEST");
  runId("INPUT_MITIGATION_RUN_ID");
  artifactName("INPUT_MITIGATION_ARTIFACT");
  digest("INPUT_MITIGATION_DIGEST");
  for (const name of ["INPUT_CANDIDATE_DIGEST", "INPUT_RELEASE_DIGEST", "INPUT_RELEASE_SET_DIGEST"]) digest(name);
  approval("INPUT_ROLLBACK_APPROVAL");
}
if (mode !== "authorize") {
  const head = git("rev-parse", "HEAD");
  if (head !== commit) throw new Error("checked-out source does not match the authorized workflow commit");
  if (git("status", "--porcelain") !== "") throw new Error("workflow checkout is not clean");
}
process.stdout.write(`${JSON.stringify({ status: "passed", mode, commit })}\n`);

function required(name) { const value = process.env[name]; if (typeof value !== "string" || value.length < 1 || value.length > 1024 || /[\u0000-\u001F\u007F]/u.test(value)) throw new Error(`${name} is missing or unsafe`); return value; }
function exact(actual, expected, label) { if (actual !== expected) throw new Error(`${label} does not match protected workflow intent`); }
function digest(name) { if (!/^[0-9a-f]{64}$/u.test(required(name))) throw new Error(`${name} must be a lowercase SHA-256 digest`); }
function runId(name) { if (!/^[1-9][0-9]{0,19}$/u.test(required(name))) throw new Error(`${name} must be an exact positive workflow run ID`); }
function artifactName(name) { if (!/^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/u.test(required(name))) throw new Error(`${name} is not a bounded artifact identity`); }
function approval(name) { if (!/^[A-Za-z0-9][A-Za-z0-9._:/@+-]{7,219}$/u.test(required(name))) throw new Error(`${name} is not a bounded approval identity`); }
function workflowPath(name) { if (!/^\.github\/workflows\/[a-z0-9][a-z0-9._-]{0,127}\.ya?ml$/u.test(required(name))) throw new Error(`${name} is not an exact workflow path`); }
function timestamp(name) {
  const value = required(name);
  const milliseconds = Date.parse(value);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value) || !Number.isFinite(milliseconds) || new Date(milliseconds).toISOString() !== value) throw new Error(`${name} is not a canonical real UTC timestamp`);
}
function git(...args) { const result = spawnSync("git", args, { encoding: "utf8", timeout: 30_000 }); if (result.status !== 0) throw new Error(result.stderr || "git identity command failed"); return result.stdout.trim(); }
function isAncestor(ancestor, descendant) { const result = spawnSync("git", ["merge-base", "--is-ancestor", ancestor, descendant], { encoding: "utf8", timeout: 30_000 }); if (result.status === 0) return true; if (result.status === 1) return false; throw new Error(result.stderr || "could not verify protected commit ancestry"); }

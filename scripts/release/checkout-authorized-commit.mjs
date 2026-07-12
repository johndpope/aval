#!/usr/bin/env node
import { spawnSync } from "node:child_process";

const commit = process.env.INPUT_COMMIT;
if (typeof commit !== "string" || !/^[0-9a-f]{40}$/u.test(commit)) throw new Error("authorized checkout requires one full lowercase commit ID");
const ancestry = spawnSync("git", ["merge-base", "--is-ancestor", commit, "HEAD"], { stdio: "inherit", timeout: 30_000 });
if (ancestry.status !== 0) throw new Error("authorized commit is not an ancestor of protected checkout HEAD");
const checkout = spawnSync("git", ["checkout", "--detach", commit], { stdio: "inherit", timeout: 30_000 });
if (checkout.status !== 0) throw new Error("could not check out the authorized immutable release commit");
const actual = spawnSync("git", ["rev-parse", "HEAD"], { encoding: "utf8", timeout: 30_000 });
if (actual.status !== 0 || actual.stdout.trim() !== commit) throw new Error("authorized checkout identity mismatch");

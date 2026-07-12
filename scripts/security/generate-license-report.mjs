#!/usr/bin/env node
import { readFile, writeFile } from "node:fs/promises";

import { createLicenseReport } from "./license-model.mjs";

const outputIndex = process.argv.indexOf("--output");
const output = process.argv[outputIndex + 1];
if (outputIndex < 0 || output === undefined) throw new Error("--output is required");
const [lockBytes, policyBytes] = await Promise.all([readFile("package-lock.json"), readFile("config/release/license-policy.json")]);
const report = createLicenseReport(lockBytes, policyBytes);
await writeFile(output, `${JSON.stringify(report, null, 2)}\n`, { flag: "wx" });
process.stdout.write(`${JSON.stringify({ status: "passed", output, packages: report.packages.length, lockfileSha256: report.lockfileSha256, policySha256: report.policySha256 })}\n`);

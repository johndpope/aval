#!/usr/bin/env node
import { readFile } from "node:fs/promises";

import { createLicenseReport } from "./license-model.mjs";

const [lockBytes, policyBytes] = await Promise.all([readFile("package-lock.json"), readFile("config/release/license-policy.json")]);
const report = createLicenseReport(lockBytes, policyBytes);
process.stdout.write(`${JSON.stringify({ status: "passed", dependencies: report.packages.length, lockfileSha256: report.lockfileSha256, policySha256: report.policySha256 })}\n`);

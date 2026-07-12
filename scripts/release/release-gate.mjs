#!/usr/bin/env node
import { spawnSync } from "node:child_process";

const commands = [
  ["npm", ["run", "check:generated"]],
  ["npm", ["run", "typecheck"]],
  ["npm", ["run", "test:unit"]],
  ["npm", ["run", "test:mutation", "--", "--profile", "release"]],
  ["npm", ["run", "build"]],
  [process.execPath, ["scripts/performance/measure-m8-bundles.mjs"]],
  ["npm", ["run", "test:browser:reference"]],
  ["npm", ["run", "test:browser:production"]],
  ["npm", ["run", "fixtures:verify"]],
  ["npm", ["run", "api:check"]],
  ["npm", ["run", "docs:check"]],
  ["npm", ["run", "security:check"]],
  ["npm", ["audit", "--audit-level=high"]]
];
for (const [command, args] of commands) {
  const result = spawnSync(command, args, { stdio: "inherit", timeout: 30 * 60_000 });
  if (result.error !== undefined) throw result.error;
  if (result.status !== 0) throw new Error(`release gate failed: ${command} ${args.join(" ")}`);
}
process.stdout.write(`${JSON.stringify({ status: "passed", commands: commands.length })}\n`);

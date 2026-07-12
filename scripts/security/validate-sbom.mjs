#!/usr/bin/env node
import { readFile } from "node:fs/promises";

import { validateSpdxDocument } from "./sbom-model.mjs";

const path = process.argv[2];
if (path === undefined) throw new Error("usage: validate-sbom.mjs <document.spdx.json>");
const bytes = await readFile(path);
if (bytes.byteLength < 1 || bytes.byteLength > 64 * 1024 * 1024) throw new Error("SPDX document byte length is outside policy");
let document;
try { document = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
catch (error) { throw new Error("SPDX document is not strict UTF-8 JSON", { cause: error }); }
validateSpdxDocument(document);
process.stdout.write(`${JSON.stringify({ status: "passed", packages: document.packages.length, files: document.files.length, relationships: document.relationships.length })}\n`);

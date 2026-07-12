import { spawnSync } from "node:child_process";

export function readRegistryState(name, version, options = {}) {
  const spawn = options.spawn ?? spawnSync;
  const registry = options.registry === undefined ? undefined : exactRegistryUrl(options.registry);
  const spec = `${name}@${version}`;
  const integrity = npmView([spec, "dist.integrity"], true, spawn, registry);
  const tags = npmView([name, "dist-tags"], true, spawn, registry);
  const deprecation = integrity.missing ? null : npmView([spec, "deprecated"], false, spawn, registry).value;
  const tagRecord = tags.missing ? {} : tags.value;
  if (tagRecord === null || typeof tagRecord !== "object" || Array.isArray(tagRecord)) throw new Error(`registry returned invalid dist-tags for ${name}`);
  const tagEntries = Object.entries(tagRecord);
  if (tagEntries.length > 64) throw new Error(`registry returned too many dist-tags for ${name}`);
  const integrityValue = integrity.missing ? null : scalarOrNull(integrity.value, `${spec} integrity`);
  if (integrityValue !== null && !isCanonicalIntegrity(integrityValue)) throw new Error(`registry returned noncanonical integrity for ${spec}`);
  return Object.freeze({
    name,
    version,
    integrity: integrityValue,
    tags: Object.freeze(Object.fromEntries(tagEntries.map(([tag, value]) => {
      if (!/^[a-z][a-z0-9._-]{0,63}$/u.test(tag)) throw new Error(`registry returned invalid dist-tag name for ${name}`);
      const versionValue = scalarOrNull(value, `${name} dist-tag ${tag}`);
      if (versionValue !== null && (!/^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$/u.test(versionValue) || versionValue.length > 128)) throw new Error(`registry returned invalid dist-tag version for ${name}`);
      return [tag, versionValue];
    }))),
    deprecation: deprecation === null || deprecation === "" ? null : scalarOrNull(deprecation, `${spec} deprecation`)
  });
}

export function readStableRegistryState(name, version, options = {}) {
  const attempts = options.stabilityAttempts ?? 3;
  if (!Number.isSafeInteger(attempts) || attempts < 2 || attempts > 8) throw new RangeError("registry stability attempt count is invalid");
  let previous = readRegistryState(name, version, options);
  for (let attempt = 1; attempt < attempts; attempt += 1) {
    const current = readRegistryState(name, version, options);
    if (stableStateText(previous) === stableStateText(current)) return current;
    previous = current;
  }
  throw new Error(`registry state did not stabilize for ${name}@${version}`);
}

export function runRegistryMutation(args, options = {}) {
  if (!Array.isArray(args) || args.length < 1 || args.some((value) => typeof value !== "string" || value.length < 1 || value.length > 2048 || /[\r\n\0]/u.test(value))) throw new TypeError("registry mutation arguments are invalid");
  if (args.includes("--registry") || args.some((value) => value.startsWith("--registry="))) throw new Error("registry mutation may not override the pinned registry");
  if (args[0] === "publish" && !args.includes("--ignore-scripts")) throw new Error("privileged publication must disable lifecycle scripts");
  const registry = options.registry === undefined ? undefined : exactRegistryUrl(options.registry);
  const pinnedArgs = registry === undefined ? [...args] : [...args, "--registry", registry];
  const result = (options.spawn ?? spawnSync)("npm", pinnedArgs, {
    cwd: options.cwd,
    stdio: "inherit",
    timeout: options.timeout ?? 120_000
  });
  if (result.error !== undefined) throw result.error;
  if (result.status !== 0) throw new Error(`npm ${args.join(" ")} failed with status ${String(result.status)}`);
}

export function canonicalRegistryUrl(value) { return exactRegistryUrl(value); }

function npmView(fields, allowMissing, spawn, registry) {
  const args = ["view", ...fields, "--json"];
  if (registry !== undefined) args.push("--registry", registry);
  const result = spawn("npm", args, {
    encoding: "utf8",
    timeout: 30_000
  });
  if (result.error !== undefined) throw result.error;
  if (result.status !== 0) {
    const diagnostics = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
    if (allowMissing && isDefinitiveRegistryNotFound(diagnostics)) return Object.freeze({ missing: true, value: null });
    throw new Error(`registry lookup failed closed for ${fields[0]}: ${boundedDiagnostics(diagnostics)}`);
  }
  const output = result.stdout.trim();
  if (output === "") return Object.freeze({ missing: false, value: null });
  try {
    return Object.freeze({ missing: false, value: parseRegistryJson(output, fields[0]) });
  } catch {
    throw new Error(`registry returned malformed JSON for ${fields[0]}`);
  }
}

function exactRegistryUrl(value) {
  if (typeof value !== "string" || value.length > 512) throw new TypeError("registry URL is invalid");
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username !== "" || url.password !== "" || url.search !== "" || url.hash !== "" || !url.pathname.endsWith("/") || url.href !== value) throw new TypeError("registry URL must be credential-free canonical HTTPS");
  return url.href;
}

export function isDefinitiveRegistryNotFound(value) {
  return /(?:\bE404\b|\b404 Not Found\b|"code"\s*:\s*"E404")/u.test(value);
}

export function parseRegistryJson(output, label = "registry response") {
  if (typeof output !== "string" || output.length > 4 * 1024 * 1024) throw new Error(`${label} registry JSON is invalid or oversized`);
  try {
    return JSON.parse(output);
  } catch {
    throw new Error(`registry returned malformed JSON for ${label}`);
  }
}

function boundedDiagnostics(value) {
  return value.replace(/[\r\n]+/gu, " ").slice(0, 500) || "no diagnostics";
}

function scalarOrNull(value, name) {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string" || value.length > 1024) throw new Error(`registry returned invalid ${name}`);
  return value;
}

function stableStateText(state) {
  return JSON.stringify({
    name: state.name,
    version: state.version,
    integrity: state.integrity,
    tags: Object.fromEntries(Object.entries(state.tags).sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0)),
    deprecation: state.deprecation ?? null
  });
}

function isCanonicalIntegrity(value) {
  if (!/^sha512-[A-Za-z0-9+/]{86}==$/u.test(value)) return false;
  const encoded = value.slice(7);
  const bytes = Buffer.from(encoded, "base64");
  return bytes.byteLength === 64 && bytes.toString("base64") === encoded;
}

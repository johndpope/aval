import "@pixel-point/aval-element/auto";
import { createSourceSupportProbe } from "@pixel-point/aval-player-web";

const CODECS = Object.freeze(["av1", "vp9", "h265", "h264"]);
const CODEC_LABELS = Object.freeze({
  av1: "AV1",
  vp9: "VP9",
  h265: "H.265 / HEVC",
  h264: "H.264 / AVC"
});
const UNSUPPORTED_MESSAGE = "This codec is not supported in your browser.";
const UNAVAILABLE_MESSAGE = "Codec support could not be checked in your browser.";
const PLAYBACK_FAILURE_MESSAGE = "This codec could not be played in your browser.";
const BT709_LIMITED = Object.freeze({
  primaries: "bt709",
  transfer: "bt709",
  matrix: "bt709",
  fullRange: false
});
const RENDERED_READINESS = new Set([
  "visualReady",
  "interactiveReady",
  "staticReady"
]);
const simulatedUnsupported = new Set(
  new URL(location.href).searchParams
    .getAll("simulateUnsupported")
    .filter((codec) => CODECS.includes(codec))
);
const prefersReducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const publicBaseUrl = new URL(import.meta.env.BASE_URL, location.href);
const reportUrl = new URL("grass-rabbit/build.json", publicBaseUrl);
const hotspotUrl = new URL("interaction-hotspot.svg", publicBaseUrl);
const tabs = new Map(CODECS.map((codec) => [
  codec,
  requireElement(`[role="tab"][data-codec="${codec}"]`)
]));
const panels = new Map(CODECS.map((codec) => [
  codec,
  requireElement(`[role="tabpanel"][data-codec="${codec}"]`)
]));
const panelParts = new Map();
const support = new Map(CODECS.map((codec) => [codec, "unavailable"]));
const probeStatus = requireElement("#probe-status");

let report = null;
let activePlayerValue = null;
let activationSerial = 0;
let explicitActivationRequested = false;
let latestActivation = Promise.resolve();
let retirementTail = Promise.resolve();

for (const codec of CODECS) {
  panelParts.set(codec, createPanelShell(codec, requireMapValue(panels, codec)));
}
selectTab("av1");
bindTabs();

const setup = initialize();
const ready = setup.then(async () => {
  if (explicitActivationRequested) {
    await waitForLatestActivation();
    return;
  }
  const firstSupported = CODECS.find(
    (codec) => requireMapValue(support, codec) === "supported"
  );
  await requestActivation(firstSupported ?? "av1", false);
  await waitForLatestActivation();
});

const publicApi = Object.freeze({
  ready,
  activate(codec) {
    return requestActivation(codec, true);
  },
  supportSnapshot() {
    return Object.freeze(Object.fromEntries(CODECS.map((codec) => [
      codec,
      requireMapValue(support, codec)
    ])));
  },
  get activePlayer() {
    return activePlayerValue;
  }
});

Object.defineProperty(window, "grassRabbitCodecs", {
  value: publicApi,
  configurable: false,
  enumerable: false,
  writable: false
});

// The public promise remains rejected for callers when setup fails, while this
// attached observer prevents an unhandled rejection from becoming console noise.
void ready.catch(() => undefined);

async function initialize() {
  try {
    report = parseBuildReport(await fetchBuildReport());
    renderBuildDetails(report);
  } catch (error) {
    publishAllSupportStates();
    probeStatus.textContent = "Codec details could not be loaded.";
    probeStatus.dataset.state = "unavailable";
    for (const codec of CODECS) {
      setPanelMessage(codec, UNAVAILABLE_MESSAGE);
    }
    throw error;
  }

  await probeAllCodecs(report);
  publishAllSupportStates();
  publishProbeSummary();
}

function publishProbeSummary() {
  const supportedCount = CODECS.filter(
    (codec) => requireMapValue(support, codec) === "supported"
  ).length;
  probeStatus.textContent = supportedCount === 1
    ? "Support check complete · 1 of 4 codecs is available."
    : `Support check complete · ${String(supportedCount)} of 4 codecs are available.`;
  probeStatus.dataset.state = supportedCount > 0 ? "complete" : "unavailable";
}

async function fetchBuildReport() {
  const response = await fetch(reportUrl, { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`Codec build report request failed (${String(response.status)}).`);
  }
  return response.json();
}

async function probeAllCodecs(buildReport) {
  for (const codec of simulatedUnsupported) {
    support.set(codec, "unsupported");
  }
  const candidates = CODECS.filter((codec) => !simulatedUnsupported.has(codec));
  if (candidates.length === 0) return;

  let owner;
  try {
    owner = createSourceSupportProbe();
  } catch {
    return;
  }

  try {
    for (let index = 0; index < candidates.length; index += 1) {
      const codec = candidates[index];
      try {
        const asset = requireMapValue(buildReport.assets, codec);
        const result = await owner.probe(exactProbeConfig(asset.codecString));
        support.set(codec, result ? "supported" : "unsupported");
      } catch {
        support.set(codec, "unavailable");
        for (const remaining of candidates.slice(index + 1)) {
          support.set(remaining, "unavailable");
        }
        break;
      }
    }
  } finally {
    await owner.dispose().catch(() => undefined);
  }
}

function exactProbeConfig(codec) {
  return Object.freeze({
    codec,
    codedWidth: 1280,
    codedHeight: 720,
    displayAspectWidth: 1280,
    displayAspectHeight: 720,
    colorSpace: BT709_LIMITED
  });
}

function requestActivation(codec, explicit) {
  assertCodec(codec);
  if (explicit) explicitActivationRequested = true;
  const serial = ++activationSerial;
  selectTab(codec);
  const operation = activateAfterSetup(codec, serial);
  latestActivation = operation;
  return operation;
}

async function waitForLatestActivation() {
  let observed;
  do {
    observed = latestActivation;
    await observed;
  } while (observed !== latestActivation);
}

async function activateAfterSetup(codec, serial) {
  await setup;
  if (serial !== activationSerial) return;

  await retireActivePlayer();
  if (serial !== activationSerial) return;

  const parts = requireMapValue(panelParts, codec);
  resetPanelPresentation(parts);
  const state = requireMapValue(support, codec);
  if (state === "unsupported") {
    parts.stage.dataset.state = "unsupported";
    parts.message.textContent = UNSUPPORTED_MESSAGE;
    return;
  }
  if (state === "unavailable") {
    parts.stage.dataset.state = "unavailable";
    parts.message.textContent = UNAVAILABLE_MESSAGE;
    return;
  }

  const buildReport = report;
  if (buildReport === null) {
    parts.stage.dataset.state = "unavailable";
    parts.message.textContent = UNAVAILABLE_MESSAGE;
    return;
  }
  const asset = requireMapValue(buildReport.assets, codec);
  const player = document.createElement("aval-player");
  player.className = "rabbit-player";
  player.setAttribute("width", "640");
  player.setAttribute("height", "360");
  player.setAttribute("autoplay", "visible");
  player.setAttribute("tabindex", "0");
  player.setAttribute(
    "aria-label",
    `Interactive grass rabbit animation encoded with ${codecLabel(codec)}. Hover or focus to change its state.`
  );
  const source = document.createElement("source");
  source.src = new URL(`grass-rabbit/${asset.path}`, publicBaseUrl).href;
  source.type = asset.type;
  source.setAttribute("integrity", asset.integrity);
  player.append(source);

  const hotspot = createHotspot();
  bindPlayerPresentation(codec, player, hotspot, parts, serial);
  parts.mount.replaceChildren(player, hotspot);
  parts.message.textContent = "Preparing this codec…";
  parts.stage.dataset.state = "preparing";
  parts.stage.setAttribute("aria-busy", "true");
  activePlayerValue = player;

  try {
    const preparation = await player.prepare({ timeoutMs: 30_000 });
    if (serial !== activationSerial || activePlayerValue !== player) return;
    const failureKind = preparationFailureKind(player, preparation);
    if (failureKind !== null) {
      await finishFailedActivation(codec, player, parts, serial, failureKind);
      return;
    }
    parts.stage.dataset.state = "ready";
    parts.stage.removeAttribute("aria-busy");
    parts.message.textContent = "";
    revealPlayerWhenRendered(player, hotspot, serial);
  } catch (error) {
    if (serial !== activationSerial || activePlayerValue !== player) return;
    const failureKind = failureCode(error) === "unsupported-profile"
      ? "unsupported"
      : "playback";
    await finishFailedActivation(codec, player, parts, serial, failureKind);
  }
}

function preparationFailureKind(player, result) {
  if (!isRecord(result) || result.mode !== "static") return null;
  if (result.reason === "codec-unsupported") return "unsupported";
  const lastFailureCode = playerFailureCode(player);
  if (lastFailureCode !== null) return "playback";
  return [
    "reduced-motion",
    "visibility-suspended",
    "resource-budget",
    "decoder-queued"
  ].includes(result.reason)
    ? null
    : "playback";
}

async function finishFailedActivation(codec, player, parts, serial, kind) {
  if (serial !== activationSerial || activePlayerValue !== player) return;
  if (kind === "unsupported") {
    support.set(codec, "unsupported");
    publishSupportState(codec);
    publishProbeSummary();
    parts.stage.removeAttribute("aria-busy");
  }
  await retireActivePlayer();
  if (activePlayerValue === null || !parts.mount.contains(activePlayerValue)) {
    parts.mount.replaceChildren();
  }
  if (serial !== activationSerial) return;
  parts.stage.removeAttribute("aria-busy");
  if (kind === "unsupported") return;
  parts.stage.dataset.runtimeError = "true";
  parts.stage.dataset.state = "error";
  parts.message.textContent = PLAYBACK_FAILURE_MESSAGE;
}

function playerFailureCode(player) {
  try {
    return failureCode(player.getDiagnostics().lastFailure);
  } catch {
    return "readiness-failure";
  }
}

function failureCode(value) {
  let current = value;
  for (let depth = 0; depth < 3; depth += 1) {
    if (!isRecord(current)) return null;
    if (typeof current.code === "string") return current.code;
    const nested = current.failure;
    if (nested === current) return null;
    current = nested;
  }
  return null;
}

async function retireActivePlayer() {
  const previous = activePlayerValue;
  activePlayerValue = null;
  const priorRetirement = retirementTail;
  retirementTail = (async () => {
    await priorRetirement.catch(() => undefined);
    if (previous === null) return;
    try {
      await previous.dispose();
    } finally {
      previous.remove();
    }
  })();
  await retirementTail.catch(() => undefined);
}

function bindTabs() {
  for (const [codec, tab] of tabs) {
    tab.addEventListener("click", () => {
      void requestActivation(codec, true).catch(() => undefined);
    });
    tab.addEventListener("keydown", (event) => {
      const currentIndex = CODECS.indexOf(codec);
      let nextIndex = null;
      if (event.key === "ArrowRight") nextIndex = (currentIndex + 1) % CODECS.length;
      if (event.key === "ArrowLeft") {
        nextIndex = (currentIndex - 1 + CODECS.length) % CODECS.length;
      }
      if (event.key === "Home") nextIndex = 0;
      if (event.key === "End") nextIndex = CODECS.length - 1;
      if (nextIndex === null) return;
      event.preventDefault();
      const nextCodec = CODECS[nextIndex];
      const nextTab = requireMapValue(tabs, nextCodec);
      setRovingTabStop(nextCodec);
      nextTab.focus();
      nextTab.scrollIntoView({ block: "nearest", inline: "nearest" });
    });
  }
}

function setRovingTabStop(codec) {
  for (const family of CODECS) {
    requireMapValue(tabs, family).tabIndex = family === codec ? 0 : -1;
  }
}

function selectTab(codec) {
  for (const family of CODECS) {
    const selected = family === codec;
    const tab = requireMapValue(tabs, family);
    const panel = requireMapValue(panels, family);
    tab.setAttribute("aria-selected", selected ? "true" : "false");
    tab.tabIndex = selected ? 0 : -1;
    panel.hidden = !selected;
    panel.toggleAttribute("inert", !selected);
  }
}

function createPanelShell(codec, panel) {
  const label = codecLabel(codec);
  const layout = document.createElement("div");
  layout.className = "panel-layout";

  const preview = document.createElement("div");
  preview.className = "preview-column";
  const titleRow = document.createElement("div");
  titleRow.className = "preview-heading";
  const heading = document.createElement("h3");
  heading.textContent = `${label} at 1280 × 720`;
  const supportBadge = document.createElement("span");
  supportBadge.className = "support-badge";
  supportBadge.dataset.supportBadge = "";
  supportBadge.dataset.state = "unavailable";
  supportBadge.textContent = "Checking";
  titleRow.append(heading, supportBadge);

  const stage = document.createElement("div");
  stage.className = "player-stage";
  stage.dataset.playerStage = "";
  stage.dataset.state = "checking";
  const mount = document.createElement("div");
  mount.className = "player-mount";
  mount.dataset.playerMount = "";
  const message = document.createElement("p");
  message.className = "player-message";
  message.dataset.playerMessage = "";
  message.setAttribute("role", "status");
  message.textContent = "Checking exact browser support…";
  stage.append(mount, message);

  const stateRow = document.createElement("div");
  stateRow.className = "state-row";
  const stateBadge = document.createElement("p");
  stateBadge.className = "state-badge";
  stateBadge.dataset.stateBadge = "";
  stateBadge.textContent = "loading";
  stateRow.append(stateBadge);
  preview.append(titleRow, stage, stateRow);

  const details = document.createElement("aside");
  details.className = "encoding-card";
  details.setAttribute("aria-label", `${label} encoding details`);
  const facts = document.createElement("dl");
  facts.className = "asset-facts";
  facts.append(
    descriptionPair("Asset", "—", "asset-name"),
    descriptionPair("File size", "—", "asset-bytes"),
    descriptionPair("Codec string", "—", "codec-string")
  );
  const compileHeading = document.createElement("h4");
  compileHeading.textContent = "Compiler command";
  const compileCommand = document.createElement("pre");
  compileCommand.className = "code-block command-block";
  compileCommand.textContent = "avl compile motion.json --out public/grass-rabbit --force";
  const encodingHeading = document.createElement("h4");
  encodingHeading.textContent = "Exact project encoding";
  const encoding = document.createElement("pre");
  encoding.className = "code-block";
  encoding.dataset.encoding = "";
  encoding.textContent = "Loading build report…";
  const commandHeading = document.createElement("h4");
  commandHeading.textContent = "Per-unit equivalent";
  const command = document.createElement("pre");
  command.className = "code-block command-block";
  command.dataset.ffmpeg = "";
  command.textContent = "Loading build report…";
  details.append(
    facts,
    compileHeading,
    compileCommand,
    encodingHeading,
    encoding,
    commandHeading,
    command
  );

  layout.append(preview, details);
  panel.replaceChildren(layout);
  return Object.freeze({
    panel,
    stage,
    mount,
    message,
    stateBadge,
    supportBadge,
    assetName: requireElement("[data-field='asset-name']", facts),
    assetBytes: requireElement("[data-field='asset-bytes']", facts),
    codecString: requireElement("[data-field='codec-string']", facts),
    encoding,
    command
  });
}

function descriptionPair(term, value, field) {
  const wrapper = document.createElement("div");
  const dt = document.createElement("dt");
  dt.textContent = term;
  const dd = document.createElement("dd");
  dd.dataset.field = field;
  dd.textContent = value;
  wrapper.append(dt, dd);
  return wrapper;
}

function renderBuildDetails(buildReport) {
  for (const codec of CODECS) {
    const parts = requireMapValue(panelParts, codec);
    const asset = requireMapValue(buildReport.assets, codec);
    const encoding = requireMapValue(buildReport.encodings, codec);
    parts.assetName.textContent = asset.path;
    parts.assetBytes.textContent = `${formatMebibytes(asset.bytes)} MiB · ${formatInteger(asset.bytes)} bytes`;
    parts.assetBytes.dataset.bytes = String(asset.bytes);
    parts.codecString.textContent = asset.codecString;
    parts.encoding.textContent = JSON.stringify(encoding, null, 2);
    parts.command.textContent = ffmpegEquivalent(encoding);
  }
}

function publishAllSupportStates() {
  for (const codec of CODECS) publishSupportState(codec);
}

function publishSupportState(codec) {
  const state = requireMapValue(support, codec);
  const tab = requireMapValue(tabs, codec);
  const parts = requireMapValue(panelParts, codec);
  tab.dataset.support = state;
  requireElement("[data-tab-support]", tab).textContent = supportLabel(state);
  parts.supportBadge.dataset.state = state;
  parts.supportBadge.textContent = supportLabel(state);
  if (state === "unsupported") {
    setPanelMessage(codec, UNSUPPORTED_MESSAGE, "unsupported");
  }
  if (state === "unavailable") setPanelMessage(codec, UNAVAILABLE_MESSAGE);
  if (state === "supported") {
    parts.stage.dataset.state = "idle";
    parts.message.textContent = "Select this codec to load its standalone AVAL source.";
  }
}

function supportLabel(state) {
  if (state === "supported") return "Supported";
  if (state === "unsupported") return "Unsupported";
  return "Unavailable";
}

function resetPanelPresentation(parts) {
  parts.mount.replaceChildren();
  parts.message.textContent = "";
  parts.stateBadge.textContent = "loading";
  parts.stateBadge.removeAttribute("data-visible");
  parts.stage.removeAttribute("aria-busy");
  delete parts.stage.dataset.runtimeError;
}

function setPanelMessage(codec, value, state = "unavailable") {
  const parts = requireMapValue(panelParts, codec);
  parts.stage.dataset.state = state;
  parts.message.textContent = value;
}

function createHotspot() {
  const hotspot = document.createElement("span");
  hotspot.className = "interaction-hotspot";
  hotspot.setAttribute("aria-hidden", "true");
  const image = document.createElement("img");
  image.src = hotspotUrl.href;
  image.alt = "";
  image.draggable = false;
  hotspot.append(image);
  return hotspot;
}

function bindPlayerPresentation(codec, player, hotspot, parts, serial) {
  const isCurrent = () => serial === activationSerial && activePlayerValue === player;
  const reveal = () => revealPlayerWhenRendered(player, hotspot, serial);
  player.addEventListener("readinesschange", reveal);
  player.addEventListener("readinesschange", () => {
    if (!isCurrent()) return;
    if (player.readiness === "interactiveReady") {
      requestAnimationFrame(() => trackInitialPresentation(player, parts, serial));
    } else if (player.readiness === "staticReady") {
      setStateLabel(parts.stateBadge, player.visualState);
    }
  });
  player.addEventListener("visualstatechange", (event) => {
    if (!isCurrent()) return;
    setStateLabel(parts.stateBadge, event.detail.to);
  });
  player.addEventListener("error", (event) => {
    if (!isCurrent() || !isRecord(event.detail) || event.detail.fatal !== true) {
      return;
    }
    const kind = failureCode(event.detail) === "unsupported-profile"
      ? "unsupported"
      : "playback";
    void finishFailedActivation(codec, player, parts, serial, kind)
      .catch(() => undefined);
  });

  const dismiss = () => dismissHotspot(hotspot, parts.stateBadge);
  const armPointer = () => player.addEventListener("pointerenter", dismiss, { once: true });
  player.addEventListener("focusin", dismiss, { once: true });
  if (player.matches(":hover")) {
    player.addEventListener("pointerleave", armPointer, { once: true });
  } else {
    armPointer();
  }
}

function revealPlayerWhenRendered(player, hotspot, serial) {
  if (
    serial !== activationSerial ||
    activePlayerValue !== player ||
    !RENDERED_READINESS.has(player.readiness)
  ) return;
  requestAnimationFrame(() => {
    if (serial !== activationSerial || activePlayerValue !== player) return;
    player.dataset.rendered = "";
    hotspot.classList.add("is-rendered");
  });
}

function trackInitialPresentation(player, parts, serial) {
  if (serial !== activationSerial || activePlayerValue !== player) return;
  const trace = player.getDiagnostics({ trace: true }).runtimeTrace ?? [];
  const presentation = trace.at(-1)?.graph?.presentation ?? null;
  if (presentation?.kind === "intro") {
    setStateLabel(parts.stateBadge, "intro");
    requestAnimationFrame(() => trackInitialPresentation(player, parts, serial));
    return;
  }
  setStateLabel(parts.stateBadge, presentation?.state ?? player.visualState);
}

function setStateLabel(badge, state) {
  if (typeof state !== "string" || badge.textContent?.trim() === state) return;
  badge.textContent = state;
}

function dismissHotspot(hotspot, stateBadge) {
  if (hotspot.classList.contains("is-dismissed")) return;
  const style = getComputedStyle(hotspot);
  const visible = style.display !== "none" &&
    style.visibility === "visible" &&
    Number.parseFloat(style.opacity) > 0;
  if (visible && !prefersReducedMotion) {
    const revealAfterFade = (event) => {
      if (event.target !== hotspot || event.propertyName !== "opacity") return;
      hotspot.removeEventListener("transitionend", revealAfterFade);
      stateBadge.dataset.visible = "";
    };
    hotspot.addEventListener("transitionend", revealAfterFade);
  } else {
    stateBadge.dataset.visible = "";
  }
  hotspot.classList.add("is-dismissed");
}

function ffmpegEquivalent(encoding) {
  const rendition = encoding.renditions[0];
  const scale = `scale=${String(rendition.width)}:${String(rendition.height)}`;
  const args = ["ffmpeg -i input.mp4"];
  if (encoding.codec === "av1") {
    args.push(
      "-c:v libaom-av1",
      `-crf ${String(rendition.crf)}`,
      "-b:v 0",
      `-pix_fmt ${encoding.bitDepth === 10 ? "yuv420p10le" : "yuv420p"}`,
      `-vf ${scale}`,
      `-cpu-used ${String(encoding.cpuUsed)}`,
      `-tiles ${String(encoding.tiles.columns)}x${String(encoding.tiles.rows)}`,
      `-row-mt ${encoding.rowMt ? "1" : "0"}`,
      `-threads ${String(encoding.threads)}`,
      "-an",
      "-f ivf pipe:1"
    );
  } else if (encoding.codec === "vp9") {
    args.push(
      "-c:v libvpx-vp9",
      `-crf ${String(rendition.crf)}`,
      "-b:v 0",
      `-vf ${scale}`,
      `-deadline ${encoding.deadline}`,
      `-cpu-used ${String(encoding.cpuUsed)}`,
      `-threads ${String(encoding.threads)}`,
      "-an",
      "-f ivf pipe:1"
    );
  } else if (encoding.codec === "h265") {
    args.push(
      "-c:v libx265",
      `-crf ${String(rendition.crf)}`,
      `-vf ${scale}`,
      `-preset ${encoding.preset}`,
      `-threads ${String(encoding.threads)}`,
      "-an",
      "-f hevc pipe:1"
    );
  } else {
    args.push(
      "-c:v libx264",
      `-crf ${String(rendition.crf)}`,
      `-vf ${scale}`,
      `-preset ${encoding.preset}`,
      "-an",
      "-f h264 pipe:1"
    );
  }
  return args.join(" \\\n  ");
}

function parseBuildReport(value) {
  if (!isRecord(value) || value.reportVersion !== "1.0") {
    throw new TypeError("Grass rabbit build report is not AVAL report 1.0.");
  }
  if (!Array.isArray(value.assets) || !Array.isArray(value.encodings)) {
    throw new TypeError("Grass rabbit build report is missing codec assets.");
  }
  const assets = new Map();
  for (const raw of value.assets) {
    if (!isRecord(raw) || !CODECS.includes(raw.codec)) {
      throw new TypeError("Grass rabbit build report contains an invalid asset.");
    }
    const codec = raw.codec;
    const expectedType = `application/vnd.aval; codecs="${String(raw.codecString)}"`;
    if (
      assets.has(codec) ||
      raw.path !== `${codec}.avl` ||
      typeof raw.codecString !== "string" ||
      raw.codecString.length === 0 ||
      raw.type !== expectedType ||
      typeof raw.integrity !== "string" ||
      !/^sha256-[A-Za-z0-9+/]{43}=$/u.test(raw.integrity) ||
      !Number.isSafeInteger(raw.bytes) ||
      raw.bytes < 1
    ) {
      throw new TypeError(`Grass rabbit ${codec} asset metadata is invalid.`);
    }
    assets.set(codec, Object.freeze({
      codec,
      path: raw.path,
      codecString: raw.codecString,
      type: raw.type,
      integrity: raw.integrity,
      bytes: raw.bytes
    }));
  }

  const encodings = new Map();
  for (const raw of value.encodings) {
    if (
      !isRecord(raw) ||
      !CODECS.includes(raw.codec) ||
      encodings.has(raw.codec) ||
      !Array.isArray(raw.renditions) ||
      raw.renditions.length !== 1 ||
      !isRecord(raw.renditions[0]) ||
      raw.renditions[0].width !== 1280 ||
      raw.renditions[0].height !== 720 ||
      !Number.isFinite(raw.renditions[0].crf)
    ) {
      throw new TypeError("Grass rabbit encoding metadata is invalid.");
    }
    encodings.set(raw.codec, Object.freeze(raw));
  }
  if (assets.size !== CODECS.length || encodings.size !== CODECS.length) {
    throw new TypeError("Grass rabbit build report must contain all four codecs.");
  }
  return Object.freeze({ assets, encodings });
}

function formatInteger(value) {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 }).format(value);
}

function formatMebibytes(value) {
  return new Intl.NumberFormat("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  }).format(value / (1024 * 1024));
}

function codecLabel(codec) {
  const label = CODEC_LABELS[codec];
  if (label === undefined) throw new Error(`Missing codec label: ${String(codec)}.`);
  return label;
}

function assertCodec(value) {
  if (!CODECS.includes(value)) {
    throw new TypeError("Codec must be one of av1, vp9, h265, or h264.");
  }
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireMapValue(map, key) {
  const value = map.get(key);
  if (value === undefined) throw new Error(`Missing codec value: ${String(key)}.`);
  return value;
}

function requireElement(selector, root = document) {
  const element = root.querySelector(selector);
  if (element === null) throw new Error(`Missing codec example element: ${selector}.`);
  return element;
}

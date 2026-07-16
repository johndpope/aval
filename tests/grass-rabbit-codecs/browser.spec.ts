import {
  expect,
  test,
  type JSHandle,
  type Page
} from "@playwright/test";

const CODECS = Object.freeze(["av1", "vp9", "h265", "h264"] as const);
type Codec = typeof CODECS[number];
type SupportState = "supported" | "unsupported" | "unavailable";

const CODEC_LABELS = Object.freeze({
  av1: "AV1",
  vp9: "VP9",
  h265: "H.265 / HEVC",
  h264: "H.264 / AVC"
} as const satisfies Readonly<Record<Codec, string>>);

const CODEC_PATTERNS = Object.freeze({
  av1: /^av01\./u,
  vp9: /^vp09\./u,
  h265: /^hvc1\./u,
  h264: /^avc1\./u
} as const satisfies Readonly<Record<Codec, RegExp>>);

const SUPPORT_MESSAGES = Object.freeze({
  unsupported: "This codec is not supported in your browser.",
  unavailable: "Codec support could not be checked in your browser."
} as const satisfies Readonly<Record<Exclude<SupportState, "supported">, string>>);

const COMPILE_COMMAND =
  "avl compile motion.json --out public/grass-rabbit --force";

const EXPECTED_ENCODINGS = Object.freeze({
  av1: Object.freeze({
    crf: 48,
    policy: Object.freeze({
      bitDepth: 10,
      cpuUsed: 0,
      tiles: Object.freeze({ columns: 4, rows: 2 }),
      rowMt: true,
      threads: 32
    }),
    command: Object.freeze([
      "-c:v libaom-av1",
      "-b:v 0",
      "-pix_fmt yuv420p10le",
      "-cpu-used 0",
      "-tiles 4x2",
      "-row-mt 1",
      "-threads 32",
      "-f ivf pipe:1"
    ])
  }),
  vp9: Object.freeze({
    crf: 44,
    policy: Object.freeze({ deadline: "best", cpuUsed: 0, threads: 8 }),
    command: Object.freeze([
      "-c:v libvpx-vp9",
      "-b:v 0",
      "-deadline best",
      "-cpu-used 0",
      "-threads 8",
      "-f ivf pipe:1"
    ])
  }),
  h265: Object.freeze({
    crf: 34,
    policy: Object.freeze({ preset: "veryslow", threads: 8 }),
    command: Object.freeze([
      "-c:v libx265",
      "-preset veryslow",
      "-threads 8",
      "-f hevc pipe:1"
    ])
  }),
  h264: Object.freeze({
    crf: 30,
    policy: Object.freeze({ preset: "veryslow" }),
    command: Object.freeze([
      "-c:v libx264",
      "-preset veryslow",
      "-f h264 pipe:1"
    ])
  })
} as const);

interface BuildAsset {
  readonly codec: Codec;
  readonly path: string;
  readonly bytes: number;
  readonly codecString: string;
}

interface BuildEncoding {
  readonly codec: Codec;
  readonly renditions: readonly Readonly<{
    readonly id: string;
    readonly width: number;
    readonly height: number;
    readonly crf: number;
  }>[];
  readonly [key: string]: unknown;
}

interface BuildReport {
  readonly reportVersion: string;
  readonly assets: readonly Readonly<BuildAsset>[];
  readonly encodings: readonly Readonly<BuildEncoding>[];
}

interface CleanupDiagnostics {
  readonly completed: boolean;
  readonly failureCount: number;
  readonly participantLogicalBytes: number;
  readonly participantActiveLeaseCount: number;
  readonly workerCount: number;
  readonly openFrames: number;
  readonly pagePhysicalBytes: number;
  readonly pageParticipantCount: number;
}

interface ElementOwnershipDiagnostics {
  readonly listenerCount: number;
  readonly observerCount: number;
  readonly brokerSubscriptionCount: number;
  readonly timerCount: number;
  readonly pendingCommandCount: number;
  readonly failedReleaseCount: number;
  readonly retainedRetryCount: number;
  readonly releaseFailureCount: number;
  readonly completed: boolean;
}

interface TerminalCleanupDiagnostics {
  readonly completed: boolean;
  readonly sourceCleanupCompleted: boolean;
  readonly elementOwnership: Readonly<ElementOwnershipDiagnostics>;
}

interface RuntimeTraceRecord {
  readonly index: number;
  readonly graph?: Readonly<{
    readonly presentation?: Readonly<{
      readonly kind?: string;
      readonly state?: string;
      readonly unitId?: string;
      readonly frameIndex?: number;
    }> | null;
  }> | null;
  readonly media?: Readonly<{
    readonly kind?: string;
    readonly frame?: Readonly<{
      readonly unit?: string;
      readonly localFrame?: number;
    }>;
  }> | null;
}

interface PlayerDiagnostics {
  readonly sourceGeneration: number;
  readonly requestedState: string | null;
  readonly visualState: string | null;
  readonly isTransitioning: boolean;
  readonly lastFailure: unknown;
  readonly counters: Readonly<{ readonly underflow: number }>;
  readonly cleanup: Readonly<CleanupDiagnostics> | null;
  readonly terminalCleanup: Readonly<TerminalCleanupDiagnostics> | null;
  readonly runtime: Readonly<{ readonly selectedCodec: string | null }>;
  readonly runtimeTrace?: readonly Readonly<RuntimeTraceRecord>[];
}

interface GrassRabbitPlayer extends HTMLElement {
  readonly readiness: string;
  readonly requestedState: string | null;
  readonly visualState: string | null;
  readonly isTransitioning: boolean;
  dispose(): Promise<unknown>;
  getDiagnostics(options?: Readonly<{ trace?: boolean }>): Readonly<PlayerDiagnostics>;
}

interface GrassRabbitCodecsApi {
  readonly ready: Promise<void>;
  readonly activePlayer: GrassRabbitPlayer | null;
  activate(codec: Codec): Promise<void>;
  supportSnapshot(): Readonly<Record<Codec, SupportState>>;
}

declare global {
  interface Window {
    readonly grassRabbitCodecs: GrassRabbitCodecsApi;
  }
}

interface BrowserFailures {
  readonly consoleErrors: string[];
  readonly pageErrors: string[];
}

interface PreviousPlayer {
  readonly handle: JSHandle<GrassRabbitPlayer | null>;
  readonly codec: Codec | null;
}

test("renders exact report-backed build details for every codec", async ({
  page
}) => {
  await page.goto("/", { waitUntil: "domcontentloaded" });
  const report = await page.evaluate(async (): Promise<BuildReport> => {
    const response = await fetch("/grass-rabbit/build.json", { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`build report request failed (${String(response.status)})`);
    }
    return response.json() as Promise<BuildReport>;
  });
  expect(report.reportVersion).toBe("1.0");
  expect(report.assets.map(({ codec }) => codec)).toEqual(CODECS);
  expect(report.encodings.map(({ codec }) => codec)).toEqual(CODECS);
  const assets = new Map(report.assets.map((asset) => [asset.codec, asset]));
  const encodings = new Map(report.encodings.map((encoding) => [
    encoding.codec,
    encoding
  ]));

  for (const codec of CODECS) {
    const panel = codecPanel(page, codec);
    const details = panel.locator(".encoding-card");
    const asset = requireMapValue(assets, codec);
    const encoding = requireMapValue(encodings, codec);
    const expected = EXPECTED_ENCODINGS[codec];

    await expect(details).toHaveAttribute(
      "aria-label",
      `${CODEC_LABELS[codec]} encoding details`
    );
    expect(asset.path).toBe(`${codec}.avl`);
    await expect(details.locator('[data-field="asset-name"]'))
      .toHaveText(asset.path);
    const byteCount = details.locator('[data-field="asset-bytes"]');
    await expect(byteCount).toHaveAttribute("data-bytes", String(asset.bytes));
    await expect(byteCount).toContainText(`${formatInteger(asset.bytes)} bytes`);
    await expect(details.locator('[data-field="codec-string"]'))
      .toHaveText(asset.codecString);

    const encodingNode = details.locator("[data-encoding]");
    await expect(encodingNode).not.toHaveText("Loading build report…");
    const renderedEncoding = JSON.parse(
      await encodingNode.textContent() ?? "null"
    ) as unknown;
    expect(renderedEncoding).toEqual(encoding);
    expect(encoding).toMatchObject({
      codec,
      ...expected.policy,
      renditions: [{ width: 1280, height: 720, crf: expected.crf }]
    });

    await expect(details.locator("h4").filter({
      hasText: "Compiler command"
    })).toHaveCount(1);
    await expect(details.getByText(COMPILE_COMMAND, { exact: true }))
      .toHaveCount(1);

    const ffmpeg = details.locator("[data-ffmpeg]");
    await expect(ffmpeg).not.toHaveText("Loading build report…");
    expect(await ffmpeg.evaluate((node) =>
      node.previousElementSibling?.textContent?.trim() ?? null
    )).toBe("Per-unit equivalent");
    const command = await ffmpeg.textContent() ?? "";
    expect(command).toContain("ffmpeg -i input.mp4");
    expect(command).toContain(`-crf ${String(expected.crf)}`);
    expect(command).toContain("-vf scale=1280:720");
    expect(command).toContain("-an");
    for (const fragment of expected.command) expect(command).toContain(fragment);
  }

  await expect(page.locator(".build-note").getByText(COMPILE_COMMAND, {
    exact: true
  })).toHaveCount(1);
});

test("ready waits for the final pre-setup codec activation", async ({ page }) => {
  test.setTimeout(60_000);
  const failures = captureBrowserFailures(page);
  let releaseReport!: () => void;
  let reportRequested = false;
  const reportGate = new Promise<void>((resolve) => {
    releaseReport = resolve;
  });
  await page.route("**/grass-rabbit/build.json", async (route) => {
    reportRequested = true;
    await reportGate;
    await route.continue();
  });
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await expect.poll(() => reportRequested).toBe(true);
  await expect.poll(() => page.evaluate(() =>
    window.grassRabbitCodecs !== undefined
  )).toBe(true);

  const outcomePromise = page.evaluate(async () => {
    const api = window.grassRabbitCodecs;
    void api.activate("vp9").catch(() => undefined);
    void api.activate("h264").catch(() => undefined);
    await api.ready;
    const active = api.activePlayer;
    const selected = document.querySelector<HTMLElement>(
      '[role="tab"][aria-selected="true"]'
    )?.dataset.codec ?? null;
    const visible = [...document.querySelectorAll<HTMLElement>(
      '[role="tabpanel"][data-codec]'
    )].find((panel) => !panel.hidden)?.dataset.codec ?? null;
    return {
      selected,
      visible,
      support: api.supportSnapshot().h264,
      activeCodec: active?.closest<HTMLElement>(
        '[role="tabpanel"][data-codec]'
      )?.dataset.codec ?? null,
      activeReadiness: active?.readiness ?? null,
      vp9PlayerCount: document.querySelectorAll(
        '[role="tabpanel"][data-codec="vp9"] aval-player'
      ).length,
      h264PlayerCount: document.querySelectorAll(
        '[role="tabpanel"][data-codec="h264"] aval-player'
      ).length,
      h264Message: document.querySelector<HTMLElement>(
        '[role="tabpanel"][data-codec="h264"] [data-player-message]'
      )?.textContent?.trim() ?? null
    };
  });

  try {
    await expect.poll(() => codecTab(page, "h264").getAttribute("aria-selected"))
      .toBe("true");
  } finally {
    releaseReport();
  }
  const outcome = await outcomePromise;
  expect(outcome).toMatchObject({
    selected: "h264",
    visible: "h264",
    vp9PlayerCount: 0
  });
  if (outcome.support === "supported") {
    expect(outcome).toMatchObject({
      activeCodec: "h264",
      activeReadiness: "interactiveReady",
      h264PlayerCount: 1
    });
  } else {
    expect(outcome).toMatchObject({
      activeCodec: null,
      activeReadiness: null,
      h264PlayerCount: 0,
      h264Message: SUPPORT_MESSAGES[outcome.support]
    });
  }
  expectNoBrowserFailures(failures);
});

test("implements a manual-activation, roving-tabindex codec selector", async ({
  page
}) => {
  const failures = captureBrowserFailures(page);
  await openExample(page);

  const support = await supportSnapshot(page);
  const tablist = page.locator('[role="tablist"]');
  const tabs = tablist.locator('[role="tab"][data-codec]');
  const panels = page.locator('[role="tabpanel"][data-codec]');

  await expect(tablist).toHaveCount(1);
  await expect(tablist).toHaveAccessibleName(/codec/iu);
  await expect(tabs).toHaveCount(CODECS.length);
  await expect(panels).toHaveCount(CODECS.length);
  expect(await tabs.evaluateAll((nodes) => nodes.map((node) =>
    (node as HTMLElement).dataset.codec
  ))).toEqual(CODECS);
  expect(await panels.evaluateAll((nodes) => nodes.map((node) =>
    (node as HTMLElement).dataset.codec
  ))).toEqual(CODECS);

  for (const codec of CODECS) {
    const tab = codecTab(page, codec);
    const panel = codecPanel(page, codec);
    await expect(tab).toHaveAccessibleName(CODEC_LABELS[codec]);
    await expect(tab).toHaveAttribute("aria-controls", await requireId(panel));
    await expect(panel).toHaveAttribute("aria-labelledby", await requireId(tab));

    if (support[codec] === "supported") continue;
    await expect(panel.locator("[data-player-stage]")).toHaveAttribute(
      "data-state",
      support[codec]
    );
    await expect(panel.locator("aval-player")).toHaveCount(0);
    await expect(panel.getByText(SUPPORT_MESSAGES[support[codec]], { exact: true }))
      .toHaveCount(1);
  }

  const initialCodec = await selectedCodec(page);
  const initialIndex = CODECS.indexOf(initialCodec);
  await expectSelectedPanel(page, initialCodec);
  const initialTab = codecTab(page, initialCodec);
  await initialTab.focus();
  await expect(initialTab).toBeFocused();
  const activePlayerBeforeNavigation = await page.evaluateHandle(() =>
    window.grassRabbitCodecs.activePlayer
  );

  const rightCodec = CODECS[(initialIndex + 1) % CODECS.length]!;
  await page.keyboard.press("ArrowRight");
  await expect(codecTab(page, rightCodec)).toBeFocused();
  await expectSelectedPanel(page, initialCodec, rightCodec);
  expect(await page.evaluate(
    (before) => window.grassRabbitCodecs.activePlayer === before,
    activePlayerBeforeNavigation
  )).toBe(true);

  await page.keyboard.press("ArrowLeft");
  await expect(initialTab).toBeFocused();
  await expectSelectedPanel(page, initialCodec);

  await page.keyboard.press("End");
  await expect(codecTab(page, CODECS.at(-1)!)).toBeFocused();
  await expectSelectedPanel(page, initialCodec, CODECS.at(-1)!);

  await page.keyboard.press("Home");
  await expect(codecTab(page, CODECS[0])).toBeFocused();
  await expectSelectedPanel(page, initialCodec, CODECS[0]);

  const enterCodec = initialCodec === CODECS[0] ? CODECS[1] : CODECS[0];
  if (enterCodec !== CODECS[0]) {
    await page.keyboard.press("ArrowRight");
    await expect(codecTab(page, enterCodec)).toBeFocused();
    await expectSelectedPanel(page, initialCodec, enterCodec);
  }
  await page.keyboard.press("Enter");
  await expectSelectedPanel(page, enterCodec);
  await expect(codecTab(page, enterCodec)).toBeFocused();

  const spaceCodec = CODECS[(CODECS.indexOf(enterCodec) + 1) % CODECS.length]!;
  await page.keyboard.press("ArrowRight");
  await expect(codecTab(page, spaceCodec)).toBeFocused();
  await expectSelectedPanel(page, enterCodec, spaceCodec);
  await page.keyboard.press("Space");
  await expectSelectedPanel(page, spaceCodec);
  await expect(codecTab(page, spaceCodec)).toBeFocused();

  await activePlayerBeforeNavigation.dispose();
  for (const codec of CODECS) {
    if (support[codec] === "supported") continue;
    await page.evaluate(async (requested) => {
      await window.grassRabbitCodecs.activate(requested);
    }, codec);
    await expectSelectedPanel(page, codec);
    await expect.poll(() => page.evaluate(() =>
      window.grassRabbitCodecs.activePlayer === null
    )).toBe(true);
    await expect(codecPanel(page, codec).locator("aval-player")).toHaveCount(0);
  }
  expectNoBrowserFailures(failures);
});

test("owns the unsupported-codec state without creating a runtime player", async ({
  page
}) => {
  const failures = captureBrowserFailures(page);
  await page.goto("/?simulateUnsupported=h265", {
    waitUntil: "domcontentloaded"
  });
  await page.evaluate(() => window.grassRabbitCodecs.ready);

  expect(await supportSnapshot(page)).toMatchObject({ h265: "unsupported" });
  await page.evaluate(async () => {
    await window.grassRabbitCodecs.activate("h265");
  });

  await expectSelectedPanel(page, "h265");
  const panel = codecPanel(page, "h265");
  await expect(panel.locator("[data-player-stage]")).toHaveAttribute(
    "data-state",
    "unsupported"
  );
  await expect(panel.getByText(SUPPORT_MESSAGES.unsupported, { exact: true }))
    .toHaveCount(1);
  await expect(panel.locator("aval-player")).toHaveCount(0);
  expect(await page.evaluate(() =>
    window.grassRabbitCodecs.activePlayer === null
  )).toBe(true);
  expectNoBrowserFailures(failures);
});

test("reclassifies a positive probe when runtime preparation proves the codec unsupported", async ({
  page
}) => {
  const failures = captureBrowserFailures(page);
  const releaseReport = await gateBuildReport(page);
  await page.goto(
    "/?simulateUnsupported=av1&simulateUnsupported=vp9&simulateUnsupported=h265",
    { waitUntil: "domcontentloaded" }
  );
  await installStaticPreparationOutcome(page, {
    reason: "codec-unsupported",
    failure: null
  });
  releaseReport();
  await page.evaluate(() => window.grassRabbitCodecs.ready);

  expect(await supportSnapshot(page)).toMatchObject({ h264: "unsupported" });
  await expectSelectedPanel(page, "h264");
  const panel = codecPanel(page, "h264");
  await expect(codecTab(page, "h264")).toHaveAttribute(
    "data-support",
    "unsupported"
  );
  await expect(panel.locator("[data-support-badge]")).toHaveText("Unsupported");
  await expect(panel.locator("[data-player-stage]")).toHaveAttribute(
    "data-state",
    "unsupported"
  );
  await expect(panel.getByText(SUPPORT_MESSAGES.unsupported, { exact: true }))
    .toHaveCount(1);
  await expect(panel.locator("aval-player")).toHaveCount(0);
  expect(await page.evaluate(() =>
    window.grassRabbitCodecs.activePlayer === null
  )).toBe(true);
  await expect(page.locator("#probe-status")).toContainText(
    "0 of 4 codecs are available"
  );
  expectNoBrowserFailures(failures);
});

test("shows an example-owned error when a positive probe still cannot play", async ({
  page
}) => {
  const failures = captureBrowserFailures(page);
  const releaseReport = await gateBuildReport(page);
  await page.goto(
    "/?simulateUnsupported=av1&simulateUnsupported=vp9&simulateUnsupported=h265",
    { waitUntil: "domcontentloaded" }
  );
  await installStaticPreparationOutcome(page, {
    reason: "visibility-suspended",
    failure: Object.freeze({
      code: "readiness-failure",
      message: "AVAL operation failed (readiness-failure)",
      operation: "motion-policy-enter-full"
    })
  });
  releaseReport();
  await page.evaluate(() => window.grassRabbitCodecs.ready);

  expect(await supportSnapshot(page)).toMatchObject({ h264: "supported" });
  await expectSelectedPanel(page, "h264");
  const panel = codecPanel(page, "h264");
  await expect(codecTab(page, "h264")).toHaveAttribute(
    "data-support",
    "supported"
  );
  await expect(panel.locator("[data-player-stage]")).toHaveAttribute(
    "data-state",
    "error"
  );
  await expect(panel.getByText(
    "This codec could not be played in your browser.",
    { exact: true }
  )).toHaveCount(1);
  await expect(panel.getByText(SUPPORT_MESSAGES.unsupported, { exact: true }))
    .toHaveCount(0);
  await expect(panel.locator("aval-player")).toHaveCount(0);
  expect(await page.evaluate(() =>
    window.grassRabbitCodecs.activePlayer === null
  )).toBe(true);
  expectNoBrowserFailures(failures);
});

test("ignores nonfatal diagnostics and persists fatal unsupported playback across tab retirement", async ({
  page
}) => {
  const failures = captureBrowserFailures(page);
  await openExample(page);
  const support = await supportSnapshot(page);
  const supported = CODECS.filter((codec) => support[codec] === "supported");
  test.skip(supported.length < 2, "this browser exposes fewer than two codecs");
  const failedCodec = supported[0]!;
  const nextCodec = supported[1]!;

  await page.evaluate(async (codec) => {
    await window.grassRabbitCodecs.activate(codec);
  }, failedCodec);
  await expectActiveCodecPlayer(page, failedCodec);
  await expect.poll(() => activePlayerSnapshot(page), { timeout: 45_000 })
    .toMatchObject({ readiness: "interactiveReady", lastFailure: null });

  await page.evaluate(() => {
    const player = window.grassRabbitCodecs.activePlayer;
    if (player === null) throw new Error("active player is unavailable");
    player.dispatchEvent(new CustomEvent("error", {
      detail: Object.freeze({
        generation: 1,
        failure: Object.freeze({
          code: "worker-decode-failure",
          message: "nonfatal candidate diagnostic",
          operation: "test-nonfatal"
        }),
        fatal: false
      })
    }));
  });
  await expect(codecPanel(page, failedCodec).locator("[data-player-stage]"))
    .toHaveAttribute("data-state", "ready");
  await expect(codecPanel(page, failedCodec).locator("[data-player-message]"))
    .toHaveText("");
  await expectActiveCodecPlayer(page, failedCodec);

  const releaseDispose = await page.evaluateHandle(() => {
    const player = window.grassRabbitCodecs.activePlayer;
    if (player === null) throw new Error("active player is unavailable");
    const originalDispose = player.dispose.bind(player);
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    Object.defineProperty(player, "dispose", {
      configurable: true,
      value: async () => {
        await gate;
        return originalDispose();
      }
    });
    return release;
  });

  await page.evaluate(() => {
    const player = window.grassRabbitCodecs.activePlayer;
    if (player === null) throw new Error("active player is unavailable");
    player.dispatchEvent(new CustomEvent("error", {
      detail: Object.freeze({
        generation: 1,
        failure: Object.freeze({
          code: "unsupported-profile",
          message: "fatal unsupported profile",
          operation: "test-fatal"
        }),
        fatal: true
      })
    }));
  });
  await page.evaluate((codec) => {
    void window.grassRabbitCodecs.activate(codec).catch(() => undefined);
  }, nextCodec);

  await expectSelectedPanel(page, nextCodec);
  await expect.poll(() => supportSnapshot(page)).toMatchObject({
    [failedCodec]: "unsupported"
  });
  await expect(codecTab(page, failedCodec)).toHaveAttribute(
    "data-support",
    "unsupported"
  );

  await page.evaluate((release) => release(), releaseDispose);
  await releaseDispose.dispose();
  await expectActiveCodecPlayer(page, nextCodec);
  await expect.poll(() => activePlayerSnapshot(page), { timeout: 45_000 })
    .toMatchObject({ readiness: "interactiveReady", lastFailure: null });
  expectNoBrowserFailures(failures);
});

test("plays the complete rabbit interaction on every supported codec", async ({
  page
}) => {
  test.setTimeout(5 * 60_000);
  const failures = captureBrowserFailures(page);
  await openExample(page);
  const support = await supportSnapshot(page);
  const supported = CODECS.filter((codec) => support[codec] === "supported");
  let cleanupProofs = 0;

  for (const codec of supported) {
    await page.mouse.move(1, 1);
    const previous = await capturePreviousPlayer(page);
    await page.evaluate(async (requested) => {
      await window.grassRabbitCodecs.activate(requested);
    }, codec);
    if (await expectPreviousPlayerCleanup(page, previous, codec)) {
      cleanupProofs += 1;
    }

    await expectActiveCodecPlayer(page, codec);
    await expect.poll(() => activePlayerSnapshot(page), { timeout: 45_000 })
      .toMatchObject({
        readiness: "interactiveReady",
        selectedCodec: expect.stringMatching(CODEC_PATTERNS[codec]),
        lastFailure: null,
        underflow: 0
      });
    await expect.poll(() => traceContainsUnit(page, "intro"), { timeout: 15_000 })
      .toBe(true);
    await expectVisualState(page, "idle");

    const player = codecPanel(page, codec).locator("aval-player");
    await player.hover();
    await expectVisualState(page, "entering");
    await expectVisualState(page, "hover");
    await expect.poll(() => activePlayerSnapshot(page)).toMatchObject({
      requestedState: "hover",
      visualState: "hover",
      isTransitioning: false
    });

    await page.mouse.move(1, 1);
    await expectVisualState(page, "exiting");
    await expectVisualState(page, "idle");
    await expect.poll(() => activePlayerSnapshot(page)).toMatchObject({
      requestedState: "idle",
      visualState: "idle",
      isTransitioning: false,
      selectedCodec: expect.stringMatching(CODEC_PATTERNS[codec]),
      lastFailure: null,
      underflow: 0
    });

    const units = await activeTraceUnits(page);
    expectOrderedSubsequence(units, [
      "intro",
      "idle-loop",
      "hover-in",
      "hover-loop",
      "hover-out",
      "idle-loop"
    ]);
    expectNoBrowserFailures(failures);
  }

  if (supported.length > 0 && cleanupProofs === 0) {
    const inactiveCodec = CODECS.find((codec) => support[codec] !== "supported");
    expect(inactiveCodec).toBeDefined();
    const previous = await capturePreviousPlayer(page);
    await page.evaluate(async (requested) => {
      await window.grassRabbitCodecs.activate(requested);
    }, inactiveCodec!);
    expect(await expectPreviousPlayerCleanup(page, previous, inactiveCodec!)).toBe(true);
    cleanupProofs += 1;
  }

  if (supported.length > 0) expect(cleanupProofs).toBeGreaterThan(0);
  expectNoBrowserFailures(failures);
});

test("finishes hover-in before hover-out when engagement ends early", async ({
  page
}) => {
  test.setTimeout(2 * 60_000);
  const failures = captureBrowserFailures(page);
  await openExample(page);
  const support = await supportSnapshot(page);
  const codec = CODECS.find((candidate) => support[candidate] === "supported");
  test.skip(codec === undefined, "this browser exposes no supported codec fixture");

  await page.evaluate(async (requested) => {
    await window.grassRabbitCodecs.activate(requested);
  }, codec!);
  await expectActiveCodecPlayer(page, codec!);
  await expect.poll(() => activePlayerSnapshot(page), { timeout: 45_000 })
    .toMatchObject({ readiness: "interactiveReady", lastFailure: null, underflow: 0 });
  await expectVisualState(page, "idle");
  await page.mouse.move(1, 1);

  const traceStart = await page.evaluate(() => {
    const trace = window.grassRabbitCodecs.activePlayer
      ?.getDiagnostics({ trace: true }).runtimeTrace ?? [];
    return trace.at(-1)?.index ?? -1;
  });
  await codecPanel(page, codec!).locator("aval-player").hover();
  await expect.poll(() => page.evaluate(() => {
    const trace = window.grassRabbitCodecs.activePlayer
      ?.getDiagnostics({ trace: true }).runtimeTrace ?? [];
    const presentation = trace.at(-1)?.graph?.presentation;
    return presentation?.unitId === "hover-in" &&
      typeof presentation.frameIndex === "number" &&
      presentation.frameIndex >= 8 && presentation.frameIndex < 50;
  }), { timeout: 15_000 }).toBe(true);

  await page.mouse.move(1, 1);
  await expect.poll(() => activePlayerSnapshot(page)).toMatchObject({
    requestedState: "exiting"
  });
  await expectVisualState(page, "idle");

  const routeFrames = await page.evaluate((startIndex) => {
    const trace = window.grassRabbitCodecs.activePlayer
      ?.getDiagnostics({ trace: true }).runtimeTrace ?? [];
    return trace.flatMap((record) => {
      if (record.index <= startIndex) return [];
      const media = record.media;
      if (
        media?.kind !== "frame" ||
        typeof media.frame?.unit !== "string" ||
        typeof media.frame.localFrame !== "number" ||
        !["hover-in", "hover-loop", "hover-out"].includes(media.frame.unit)
      ) return [];
      return [{ unit: media.frame.unit, frame: media.frame.localFrame }];
    });
  }, traceStart);
  expect(routeFrames.length).toBeLessThanOrEqual(128);
  const framesFor = (unit: string): number[] => routeFrames
    .filter((record) => record.unit === unit)
    .map((record) => record.frame);
  expect(framesFor("hover-in")).toEqual(
    Array.from({ length: 67 }, (_, frame) => frame)
  );
  expect(framesFor("hover-loop")).toEqual([]);
  expect(framesFor("hover-out")).toEqual(
    Array.from({ length: 48 }, (_, frame) => frame)
  );
  await expect.poll(() => activePlayerSnapshot(page)).toMatchObject({
    requestedState: "idle",
    visualState: "idle",
    isTransitioning: false,
    lastFailure: null,
    underflow: 0
  });
  expectNoBrowserFailures(failures);
});

function codecTab(page: Page, codec: Codec) {
  return page.locator(`[role="tab"][data-codec="${codec}"]`);
}

function codecPanel(page: Page, codec: Codec) {
  return page.locator(`[role="tabpanel"][data-codec="${codec}"]`);
}

async function requireId(locator: ReturnType<Page["locator"]>): Promise<string> {
  const id = await locator.getAttribute("id");
  expect(id).toMatch(/\S/u);
  return id!;
}

async function openExample(page: Page): Promise<void> {
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await page.evaluate(async () => {
    if (window.grassRabbitCodecs === undefined) {
      throw new Error("grassRabbitCodecs example API is unavailable");
    }
    await window.grassRabbitCodecs.ready;
  });
}

async function supportSnapshot(
  page: Page
): Promise<Readonly<Record<Codec, SupportState>>> {
  const snapshot = await page.evaluate(() =>
    window.grassRabbitCodecs.supportSnapshot()
  );
  expect(Object.keys(snapshot).sort()).toEqual([...CODECS].sort());
  for (const codec of CODECS) {
    expect(["supported", "unsupported", "unavailable"])
      .toContain(snapshot[codec]);
  }
  return snapshot;
}

async function selectedCodec(page: Page): Promise<Codec> {
  const selected = page.locator('[role="tab"][aria-selected="true"]');
  await expect(selected).toHaveCount(1);
  const value = await selected.getAttribute("data-codec");
  expect(CODECS).toContain(value);
  return value as Codec;
}

async function expectSelectedPanel(
  page: Page,
  selected: Codec,
  tabbable: Codec = selected
): Promise<void> {
  for (const codec of CODECS) {
    const isSelected = codec === selected;
    await expect(codecTab(page, codec)).toHaveAttribute(
      "aria-selected",
      String(isSelected)
    );
    await expect(codecTab(page, codec)).toHaveAttribute(
      "tabindex",
      codec === tabbable ? "0" : "-1"
    );
    await expect.poll(() => codecPanel(page, codec).evaluate((panel) => (
      panel as HTMLElement
    ).hidden)).toBe(!isSelected);
  }
}

function captureBrowserFailures(page: Page): BrowserFailures {
  const failures: BrowserFailures = { consoleErrors: [], pageErrors: [] };
  page.on("console", (message) => {
    if (message.type() === "error") failures.consoleErrors.push(message.text());
  });
  page.on("pageerror", (error) => failures.pageErrors.push(error.message));
  return failures;
}

async function gateBuildReport(page: Page): Promise<() => void> {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route("**/grass-rabbit/build.json", async (route) => {
    await gate;
    await route.continue();
  });
  return release;
}

async function installStaticPreparationOutcome(
  page: Page,
  input: Readonly<{
    reason: string;
    failure: Readonly<{
      code: string;
      message: string;
      operation: string;
    }> | null;
  }>
): Promise<void> {
  await page.evaluate(async ({ reason, failure }) => {
    await customElements.whenDefined("aval-player");
    const constructor = customElements.get("aval-player");
    if (constructor === undefined) throw new Error("aval-player is undefined");
    const prototype = constructor.prototype;
    const originalDiagnostics = prototype.getDiagnostics as (
      options?: Readonly<{ trace?: boolean }>
    ) => Readonly<Record<string, unknown>>;
    Object.defineProperty(prototype, "prepare", {
      configurable: true,
      value: async () => Object.freeze({
        mode: "static",
        reason,
        report: Object.freeze({
          readiness: "staticReady",
          selectedRendition: null,
          candidates: Object.freeze([])
        })
      })
    });
    if (failure === null) return;
    Object.defineProperty(prototype, "getDiagnostics", {
      configurable: true,
      value(this: HTMLElement, options?: Readonly<{ trace?: boolean }>) {
        return Object.freeze({
          ...originalDiagnostics.call(this, options),
          lastFailure: failure
        });
      }
    });
  }, input);
}

function expectNoBrowserFailures(failures: BrowserFailures): void {
  expect(failures.consoleErrors).toEqual([]);
  expect(failures.pageErrors).toEqual([]);
}

async function capturePreviousPlayer(page: Page): Promise<PreviousPlayer> {
  const handle = await page.evaluateHandle(() => window.grassRabbitCodecs.activePlayer);
  const snapshot = await page.evaluate((player) => {
    if (player === null) return null;
    const codec = player.closest<HTMLElement>('[role="tabpanel"][data-codec]')
      ?.dataset.codec ?? null;
    return {
      codec
    };
  }, handle);
  return {
    handle,
    codec: snapshot?.codec as Codec | null ?? null
  };
}

async function expectPreviousPlayerCleanup(
  page: Page,
  previous: PreviousPlayer,
  activatedCodec: Codec
): Promise<boolean> {
  const relationship = await page.evaluate((player) => ({
    existed: player !== null,
    stillActive: player !== null && window.grassRabbitCodecs.activePlayer === player
  }), previous.handle);
  if (!relationship.existed) {
    await previous.handle.dispose();
    return false;
  }
  if (relationship.stillActive && previous.codec === activatedCodec) {
    await previous.handle.dispose();
    return false;
  }
  expect(relationship.stillActive).toBe(false);

  await expect.poll(() => page.evaluate((player) => {
    if (player === null) return null;
    const diagnostics = player.getDiagnostics();
    return {
      cleanup: diagnostics.cleanup,
      terminalCleanup: diagnostics.terminalCleanup
    };
  }, previous.handle), { timeout: 30_000 }).toMatchObject({
    cleanup: {
      completed: true,
      failureCount: 0,
      participantLogicalBytes: 0,
      participantActiveLeaseCount: 0,
      workerCount: 0,
      openFrames: 0,
      pagePhysicalBytes: 0,
      pageParticipantCount: 0
    },
    terminalCleanup: {
      completed: true,
      sourceCleanupCompleted: true,
      elementOwnership: {
        listenerCount: 0,
        observerCount: 0,
        brokerSubscriptionCount: 0,
        timerCount: 0,
        pendingCommandCount: 0,
        failedReleaseCount: 0,
        retainedRetryCount: 0,
        releaseFailureCount: 0,
        completed: true
      }
    }
  });
  await previous.handle.dispose();
  return true;
}

async function expectActiveCodecPlayer(page: Page, codec: Codec): Promise<void> {
  await expect(codecPanel(page, codec).locator("aval-player")).toHaveCount(1);
  await expect.poll(() => page.evaluate((requested) => {
    const player = window.grassRabbitCodecs.activePlayer;
    return player?.closest<HTMLElement>('[role="tabpanel"][data-codec]')
      ?.dataset.codec === requested;
  }, codec)).toBe(true);
}

async function activePlayerSnapshot(page: Page): Promise<Readonly<{
  readiness: string | null;
  requestedState: string | null;
  visualState: string | null;
  isTransitioning: boolean | null;
  selectedCodec: string | null;
  lastFailure: unknown;
  underflow: number | null;
}>> {
  return page.evaluate(() => {
    const player = window.grassRabbitCodecs.activePlayer;
    if (player === null) return {
      readiness: null,
      requestedState: null,
      visualState: null,
      isTransitioning: null,
      selectedCodec: null,
      lastFailure: null,
      underflow: null
    };
    const diagnostics = player.getDiagnostics();
    return {
      readiness: player.readiness,
      requestedState: player.requestedState,
      visualState: player.visualState,
      isTransitioning: player.isTransitioning,
      selectedCodec: diagnostics.runtime.selectedCodec,
      lastFailure: diagnostics.lastFailure,
      underflow: diagnostics.counters.underflow
    };
  });
}

async function expectVisualState(page: Page, state: string): Promise<void> {
  await expect.poll(() => page.evaluate(() =>
    window.grassRabbitCodecs.activePlayer?.visualState ?? null
  ), { timeout: 30_000 }).toBe(state);
}

async function traceContainsUnit(page: Page, unit: string): Promise<boolean> {
  return page.evaluate((expectedUnit) => {
    const trace = window.grassRabbitCodecs.activePlayer
      ?.getDiagnostics({ trace: true }).runtimeTrace ?? [];
    return trace.some((record) =>
      record.graph?.presentation?.unitId === expectedUnit
    );
  }, unit);
}

async function activeTraceUnits(page: Page): Promise<string[]> {
  return page.evaluate(() => {
    const trace = window.grassRabbitCodecs.activePlayer
      ?.getDiagnostics({ trace: true }).runtimeTrace ?? [];
    const units: string[] = [];
    for (const record of trace) {
      const unit = record.graph?.presentation?.unitId;
      if (typeof unit === "string" && units.at(-1) !== unit) units.push(unit);
    }
    return units;
  });
}

function expectOrderedSubsequence(
  actual: readonly string[],
  expected: readonly string[]
): void {
  let cursor = 0;
  for (const value of actual) {
    if (value === expected[cursor]) cursor += 1;
    if (cursor === expected.length) break;
  }
  expect(cursor, `expected ordered units ${expected.join(" -> ")}; got ${actual.join(" -> ")}`)
    .toBe(expected.length);
}

function requireMapValue<K, V>(map: ReadonlyMap<K, V>, key: K): V {
  const value = map.get(key);
  expect(value).toBeDefined();
  return value!;
}

function formatInteger(value: number): string {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 })
    .format(value);
}

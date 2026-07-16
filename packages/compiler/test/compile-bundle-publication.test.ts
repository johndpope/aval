import {
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  symlink,
  writeFile
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, describe, expect, it } from "vitest";

import {
  publishCompileBundleDirectory,
  type CompileBundlePublicationInput
} from "../src/commands/compile-bundle-publication.js";

const encoder = new TextEncoder();

describe("codec bundle directory publication", () => {
  const roots: string[] = [];

  afterAll(async () => {
    await Promise.all(roots.map((root) => rm(root, {
      recursive: true,
      force: true
    })));
  });

  it("publishes exactly the ordered unique codec assets and one build report", async () => {
    const root = await temporaryRoot(roots);
    const target = join(root, "motion");
    const av1 = encoder.encode("av1 asset");
    const h264 = encoder.encode("h264 asset");
    const report = encoder.encode('{"reportVersion":"1.0"}\n');

    await publishCompileBundleDirectory(target, {
      assets: [
        { codec: "av1", bytes: av1 },
        { codec: "h264", bytes: h264 }
      ],
      buildReportBytes: report
    });

    expect((await readdir(target)).sort()).toEqual([
      "av1.avl",
      "build.json",
      "h264.avl"
    ]);
    expect(new Uint8Array(await readFile(join(target, "av1.avl")))).toEqual(av1);
    expect(new Uint8Array(await readFile(join(target, "h264.avl")))).toEqual(h264);
    expect(new Uint8Array(await readFile(join(target, "build.json")))).toEqual(report);
    expect(await publicationWorkspaces(root)).toEqual([]);
  });

  it("rejects duplicate codecs before creating any filesystem state", async () => {
    const root = await temporaryRoot(roots);
    const target = join(root, "motion");

    await expect(publishCompileBundleDirectory(target, {
      assets: [
        { codec: "vp9", bytes: encoder.encode("first") },
        { codec: "vp9", bytes: encoder.encode("second") }
      ],
      buildReportBytes: encoder.encode("{}")
    })).rejects.toMatchObject({ code: "INPUT_INVALID" });

    expect(await readdir(root)).toEqual([]);
  });

  it("refuses collisions without force and every non-directory target with force", async () => {
    const root = await temporaryRoot(roots);
    const directoryTarget = join(root, "existing");
    await mkdir(directoryTarget);
    await writeFile(join(directoryTarget, "keep.txt"), "previous");

    await expect(publish(directoryTarget)).rejects.toMatchObject({
      code: "IO_FAILED",
      message: expect.stringContaining("already exists")
    });
    expect(await readFile(join(directoryTarget, "keep.txt"), "utf8"))
      .toBe("previous");

    const fileTarget = join(root, "hostile-file");
    await writeFile(fileTarget, "do not replace");
    await expect(publish(fileTarget, true)).rejects.toMatchObject({
      code: "IO_FAILED",
      message: expect.stringContaining("real directory")
    });
    expect(await readFile(fileTarget, "utf8")).toBe("do not replace");

    const linkTarget = join(root, "hostile-link");
    await symlink(directoryTarget, linkTarget, "dir");
    await expect(publish(linkTarget, true)).rejects.toMatchObject({
      code: "IO_FAILED",
      message: expect.stringContaining("real directory")
    });
    expect(await readFile(join(linkTarget, "keep.txt"), "utf8")).toBe("previous");
    expect(await publicationWorkspaces(root)).toEqual([]);
  });

  it("force-replaces the directory as one unit and never follows old symlinks", async () => {
    const root = await temporaryRoot(roots);
    const target = join(root, "motion");
    const outside = join(root, "outside.txt");
    await writeFile(outside, "outside survives");
    await mkdir(target);
    await writeFile(join(target, "old.avl"), "old bundle");
    await symlink(outside, join(target, "outside-link"));

    await publish(target, true);

    expect((await readdir(target)).sort()).toEqual(["build.json", "vp9.avl"]);
    expect(await readFile(join(target, "vp9.avl"), "utf8")).toBe("new vp9");
    expect(await readFile(outside, "utf8")).toBe("outside survives");
    expect(await publicationWorkspaces(root)).toEqual([]);
  });

  it("restores a forced bundle when cancellation wins after installation", async () => {
    const root = await temporaryRoot(roots);
    const target = join(root, "motion");
    await mkdir(target);
    await writeFile(join(target, "old.avl"), "old bundle");
    const controller = new AbortController();

    await expect(publishCompileBundleDirectory(target, bundle(), {
      force: true,
      signal: controller.signal
    }, {
      checkpoint: (phase) => {
        if (phase === "after-stage-installed") {
          controller.abort("cancel after install");
        }
      }
    })).rejects.toMatchObject({ code: "CANCELLED" });

    expect(await readdir(target)).toEqual(["old.avl"]);
    expect(await readFile(join(target, "old.avl"), "utf8")).toBe("old bundle");
    expect(await publicationWorkspaces(root)).toEqual([]);
  });

  it("rolls back a forced bundle when a commit checkpoint fails", async () => {
    const root = await temporaryRoot(roots);
    const target = join(root, "motion");
    await mkdir(target);
    await writeFile(join(target, "old.avl"), "old bundle");

    await expect(publishCompileBundleDirectory(target, bundle(), {
      force: true
    }, {
      checkpoint: (phase) => {
        if (phase === "after-parent-synced") {
          throw new Error("injected failure before irreversible cleanup");
        }
      }
    })).rejects.toMatchObject({ code: "IO_FAILED" });

    expect(await readdir(target)).toEqual(["old.avl"]);
    expect(await readFile(join(target, "old.avl"), "utf8")).toBe("old bundle");
    expect(await publicationWorkspaces(root)).toEqual([]);
  });

  it("does not replace a directory raced into an initially absent target", async () => {
    const root = await temporaryRoot(roots);
    const target = join(root, "motion");

    await expect(publishCompileBundleDirectory(target, bundle(), {}, {
      checkpoint: async (phase) => {
        if (phase === "after-stage-verified") {
          await mkdir(target);
          await writeFile(join(target, "raced.txt"), "raced directory");
        }
      }
    })).rejects.toMatchObject({ code: "IO_FAILED" });

    expect(await readFile(join(target, "raced.txt"), "utf8"))
      .toBe("raced directory");
    expect(await publicationWorkspaces(root)).toEqual([]);
  });

  it("detects a forced-target identity race without deleting either contender", async () => {
    const root = await temporaryRoot(roots);
    const target = join(root, "motion");
    const movedOriginal = join(root, "moved-original");
    await mkdir(target);
    await writeFile(join(target, "old.avl"), "old bundle");

    await expect(publishCompileBundleDirectory(target, bundle(), {
      force: true
    }, {
      checkpoint: async (phase) => {
        if (phase === "after-stage-verified") {
          await rename(target, movedOriginal);
          await mkdir(target);
          await writeFile(join(target, "raced.txt"), "new namespace owner");
        }
      }
    })).rejects.toMatchObject({ code: "IO_FAILED" });

    expect(await readFile(join(movedOriginal, "old.avl"), "utf8"))
      .toBe("old bundle");
    expect(await readFile(join(target, "raced.txt"), "utf8"))
      .toBe("new namespace owner");
    expect(await publicationWorkspaces(root)).toEqual([]);
  });

  it("leaves a proven backup recoverable when a hostile race prevents rollback", async () => {
    if (process.platform === "win32") return;
    const root = await temporaryRoot(roots);
    const target = join(root, "motion");
    await mkdir(target);
    await writeFile(join(target, "old.avl"), "old bundle");
    let raced = false;

    await expect(publishCompileBundleDirectory(target, bundle(), {
      force: true
    }, {
      checkpoint: async (phase) => {
        if (phase === "before-stage-install" && !raced) {
          raced = true;
          await rename(target, join(root, "displaced-reservation"));
          await mkdir(target);
          await writeFile(join(target, "raced.txt"), "hostile winner");
        }
      }
    })).rejects.toMatchObject({
      code: "IO_FAILED",
      message: expect.stringContaining("could not be restored safely")
    });

    expect(await readFile(join(target, "raced.txt"), "utf8"))
      .toBe("hostile winner");
    const workspaces = await publicationWorkspaces(root);
    expect(workspaces).toHaveLength(1);
    expect(await readFile(join(root, workspaces[0]!, "previous", "old.avl"), "utf8"))
      .toBe("old bundle");
  });
});

function bundle(): Readonly<CompileBundlePublicationInput> {
  return Object.freeze({
    assets: Object.freeze([Object.freeze({
      codec: "vp9" as const,
      bytes: encoder.encode("new vp9")
    })]),
    buildReportBytes: encoder.encode('{"reportVersion":"1.0"}\n')
  });
}

async function publish(target: string, force = false): Promise<void> {
  await publishCompileBundleDirectory(target, bundle(), { force });
}

async function temporaryRoot(roots: string[]): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "aval-bundle-publication-"));
  roots.push(root);
  return root;
}

async function publicationWorkspaces(root: string): Promise<readonly string[]> {
  return (await readdir(root)).filter((name) =>
    name.includes(".bundle-publish-")
  );
}

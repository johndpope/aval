import { spawn } from "node:child_process";

interface OpenerProcess {
  once(event: "error", listener: (error: Error) => void): unknown;
  unref(): void;
}

type OpenerSpawn = (command: string, arguments_: readonly string[]) => OpenerProcess;

export function openDevServer(url: string): void {
  launchDevServerOpener(url, process.platform, (command, arguments_) => spawn(command, [...arguments_], {
    detached: true,
    stdio: "ignore",
    shell: false
  }));
}

/** @internal Test seam for best-effort platform opener behavior. */
export function launchDevServerOpener(url: string, platform: NodeJS.Platform, spawnProcess: OpenerSpawn): void {
  assertOpaqueLoopbackDevUrl(url);
  const command = platform === "darwin"
    ? ["open", [url]] as const
    : platform === "win32"
      ? ["cmd", ["/c", "start", "", url]] as const
      : ["xdg-open", [url]] as const;
  try {
    const child = spawnProcess(command[0], command[1]);
    child.once("error", () => undefined);
    child.unref();
  } catch {
    // Opening the optional browser must never terminate an otherwise healthy dev session.
  }
}

export function assertOpaqueLoopbackDevUrl(value: string): URL {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new TypeError("dev URL is invalid");
  }
  if (
    url.protocol !== "http:" ||
    (url.hostname !== "127.0.0.1" && url.hostname !== "[::1]") ||
    !/^[0-9]+$/u.test(url.port) || Number(url.port) < 1 || Number(url.port) > 65_535 ||
    url.username !== "" || url.password !== "" || url.search !== "" || url.hash !== "" ||
    !/^\/[A-Za-z0-9_-]{43}\/$/u.test(url.pathname)
  ) throw new TypeError("only a complete opaque loopback dev URL may be opened");
  return url;
}

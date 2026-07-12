import type { CertificationStatus } from "./status.js";

export interface NamedProfileIndexInput {
  readonly profileId: string;
  readonly platformClass: string;
  readonly browserProduct: string;
  readonly refreshMilliHz: number;
  readonly refresh120Available: boolean;
  readonly animationSupported: boolean;
  readonly runtimeScheduling: CertificationStatus;
  readonly staticFallback: CertificationStatus;
}

export interface NamedProfileMatrixPolicy {
  readonly requiredPlatformClasses: readonly string[];
  readonly requiredBrowsersByPlatform: Readonly<Record<string, readonly string[]>>;
  readonly requiredRefreshMilliHz: readonly number[];
  readonly conditionalRefreshMilliHz: number;
}

export interface NamedProfileMatrixResult {
  readonly status: "passed" | "failed" | "inconclusive" | "not-run";
  readonly failures: readonly string[];
  readonly missingSlots: readonly string[];
}

/** Grades the entire declared matrix; one convenient passing profile is insufficient. */
export function evaluateNamedProfileMatrix(
  profiles: readonly NamedProfileIndexInput[],
  policy: NamedProfileMatrixPolicy
): NamedProfileMatrixResult {
  validatePolicy(policy);
  if (profiles.length === 0) return Object.freeze({ status: "not-run", failures: Object.freeze([]), missingSlots: Object.freeze([]) });
  const failures: string[] = [];
  const missingSlots: string[] = [];
  const slots = new Map<string, NamedProfileIndexInput>();
  const allowedPlatforms = new Set(policy.requiredPlatformClasses);
  const allowedRefresh = new Set([...policy.requiredRefreshMilliHz, policy.conditionalRefreshMilliHz]);
  const availabilityByPlatform = new Map<string, boolean>();
  for (const profile of profiles) {
    if (!allowedPlatforms.has(profile.platformClass)) failures.push(`unknown-platform:${profile.profileId}`);
    const browsers = policy.requiredBrowsersByPlatform[profile.platformClass] ?? [];
    if (!browsers.includes(profile.browserProduct)) failures.push(`unknown-browser:${profile.profileId}`);
    if (!allowedRefresh.has(profile.refreshMilliHz)) failures.push(`unknown-refresh:${profile.profileId}:${String(profile.refreshMilliHz)}`);
    if (profile.refreshMilliHz === policy.conditionalRefreshMilliHz && !profile.refresh120Available) failures.push(`conditional-refresh-without-availability:${profile.profileId}`);
    const recordedAvailability = availabilityByPlatform.get(profile.platformClass);
    if (recordedAvailability !== undefined && recordedAvailability !== profile.refresh120Available) failures.push(`incoherent-conditional-refresh:${profile.platformClass}`);
    else availabilityByPlatform.set(profile.platformClass, profile.refresh120Available);
    const slot = slotId(profile.platformClass, profile.browserProduct, profile.refreshMilliHz);
    if (slots.has(slot)) failures.push(`duplicate-slot:${slot}`);
    else slots.set(slot, profile);
    if (profile.staticFallback !== "passed") failures.push(`static-fallback:${profile.profileId}:${profile.staticFallback}`);
    if (profile.animationSupported) {
      if (profile.runtimeScheduling !== "passed") failures.push(`supported-runtime:${profile.profileId}:${profile.runtimeScheduling}`);
    } else if (profile.runtimeScheduling !== "unsupported") {
      failures.push(`unsupported-runtime:${profile.profileId}:${profile.runtimeScheduling}`);
    }
  }

  for (const platform of policy.requiredPlatformClasses) {
    const browsers = policy.requiredBrowsersByPlatform[platform]!;
    const requiredRefresh = [...policy.requiredRefreshMilliHz];
    if (availabilityByPlatform.get(platform) === true) {
      requiredRefresh.push(policy.conditionalRefreshMilliHz);
    }
    for (const browser of browsers) for (const refresh of new Set(requiredRefresh)) {
      const slot = slotId(platform, browser, refresh);
      if (!slots.has(slot)) missingSlots.push(slot);
    }
    if (!profiles.some((profile) => profile.platformClass === platform && profile.animationSupported && profile.runtimeScheduling === "passed")) {
      failures.push(`no-supported-passing-runtime:${platform}`);
    }
  }
  const status = failures.length > 0 ? "failed" : missingSlots.length > 0 ? "inconclusive" : "passed";
  return Object.freeze({ status, failures: Object.freeze(failures), missingSlots: Object.freeze(missingSlots) });
}

function validatePolicy(policy: NamedProfileMatrixPolicy): void {
  if (!Array.isArray(policy.requiredPlatformClasses) || policy.requiredPlatformClasses.length === 0 || new Set(policy.requiredPlatformClasses).size !== policy.requiredPlatformClasses.length) throw new TypeError("named profile platform policy is invalid");
  if (!Array.isArray(policy.requiredRefreshMilliHz) || policy.requiredRefreshMilliHz.length === 0) throw new TypeError("named profile refresh policy is empty");
  for (const refresh of [...policy.requiredRefreshMilliHz, policy.conditionalRefreshMilliHz]) if (!Number.isSafeInteger(refresh) || refresh <= 0) throw new RangeError("named profile refresh policy is invalid");
  for (const platform of policy.requiredPlatformClasses) {
    const browsers = policy.requiredBrowsersByPlatform[platform];
    if (!Array.isArray(browsers) || browsers.length === 0 || new Set(browsers).size !== browsers.length) throw new TypeError(`named browser policy is invalid: ${platform}`);
  }
  const unknown = Object.keys(policy.requiredBrowsersByPlatform).find((platform) => !policy.requiredPlatformClasses.includes(platform));
  if (unknown !== undefined) throw new TypeError(`named browser policy has unknown platform: ${unknown}`);
}

function slotId(platform: string, browser: string, refreshMilliHz: number): string {
  return `${platform}/${browser}/${String(refreshMilliHz)}`;
}

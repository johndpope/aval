import { SHA256_PATTERN, type RuntimeCertificationReport } from "./model.js";

export function renderRuntimeReportMarkdown(report: RuntimeCertificationReport, canonicalJsonDigest: string): string {
  if (!SHA256_PATTERN.test(canonicalJsonDigest)) throw new TypeError("canonical report digest is invalid");
  const scenarioRows = report.scenarios.map((scenario) =>
    `| ${escapeCell(scenario.id)} | ${scenario.repetition} | ${scenario.status} | ${scenario.boundaryCount} | ${scenario.formatUnderflows} |`
  );
  return [
    `# Runtime scheduling report: ${report.reportId}`,
    "",
    `Status: **${report.status}**`,
    "",
    `Canonical JSON SHA-256: \`${canonicalJsonDigest}\``,
    `Candidate manifest SHA-256: \`${report.candidateManifestDigest}\``,
    "",
    `Exact browser: ${escapeCell(report.environment.browser.product)} ${escapeCell(report.environment.browser.version)} (${escapeCell(report.environment.browser.build)})`,
    `Exact OS: ${escapeCell(report.environment.os.product)} ${escapeCell(report.environment.os.version)} (${escapeCell(report.environment.os.build)})`,
    "",
    "| Scenario | Repetition | Status | Boundaries | Format underflows |",
    "| --- | ---: | --- | ---: | ---: |",
    ...scenarioRows,
    "",
    "This report certifies only the browser-side runtime scheduling criteria for the exact profile and candidate above. It is not observed-display or physical scan-out evidence.",
    ""
  ].join("\n");
}

function escapeCell(value: string): string {
  return value.replaceAll("|", "\\|").replace(/[\r\n]+/gu, " ");
}

import { SHA256_PATTERN, type DisplayCertificationReport } from "./model.js";

export function renderDisplayReportMarkdown(report: DisplayCertificationReport, canonicalJsonDigest: string): string {
  if (!SHA256_PATTERN.test(canonicalJsonDigest)) throw new TypeError("canonical report digest is invalid");
  return [
    `# Observed-display report: ${report.reportId}`,
    "",
    `Status: **${report.status}**`,
    "",
    `Canonical JSON SHA-256: \`${canonicalJsonDigest}\``,
    `Referenced passed runtime report: \`${report.runtimeReportId}\` (\`${report.runtimeReportDigest}\`)`,
    `Independent method: ${report.method}`,
    `Capture/trace samples: ${String(report.observationCount)} across ${String(report.refreshCount)} refreshes`,
    "",
    "This optional report is separate from runtime scheduling. An inconclusive result is never promoted to passed.",
    ""
  ].join("\n");
}

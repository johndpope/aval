import type { ServerResponse } from "node:http";

export function writeText(
  response: ServerResponse,
  method: string,
  contentType: string,
  body: string
): void {
  const bytes = new TextEncoder().encode(body);
  response.statusCode = 200;
  response.setHeader("Content-Type", contentType);
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("Content-Length", bytes.byteLength);
  if (method === "HEAD") response.end();
  else response.end(bytes);
}

export function writeError(
  response: ServerResponse,
  method: string,
  status: number,
  code: string
): void {
  const body = Buffer.from(JSON.stringify({ error: code }));
  response.statusCode = status;
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("Content-Length", body.byteLength);
  if (method === "HEAD") response.end();
  else response.end(body);
}

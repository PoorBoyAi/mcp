#!/usr/bin/env node
import { createInterface } from "node:readline";

// Live site is poorboyai.pages.dev (poorboyai.com DNS is not flipped yet —
// revisit after the domain rescue). The hosted MCP endpoint is live there.
const DEFAULT_ENDPOINT = "https://poorboyai.pages.dev/api/mcp";
const REQUEST_TIMEOUT_MS = 15_000;
const MAX_MESSAGE_BYTES = 1_048_576;

const apiKey = process.env.POORBOYAI_API_KEY?.trim();
if (!apiKey) {
  process.stderr.write("[PoorBoyAI MCP] POORBOYAI_API_KEY is required.\n");
  process.exit(1);
}

// The override exists for deterministic local testing and private deployments.
// Credentials are always sent in the Authorization header, never in the URL.
const endpoint = process.env.POORBOYAI_MCP_ENDPOINT?.trim() || DEFAULT_ENDPOINT;
let endpointUrl: URL;
try {
  endpointUrl = new URL(endpoint);
  const isLocalTest = endpointUrl.hostname === "127.0.0.1" || endpointUrl.hostname === "localhost";
  if (endpointUrl.protocol !== "https:" && !isLocalTest) throw new Error("HTTPS required");
  if (endpointUrl.username || endpointUrl.password || endpointUrl.search) throw new Error("credentials/query not allowed");
} catch {
  process.stderr.write("[PoorBoyAI MCP] Invalid MCP endpoint; HTTPS is required.\n");
  process.exit(1);
}

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
let chain = Promise.resolve();

async function proxy(line: string): Promise<void> {
  if (!line.trim()) return;
  if (Buffer.byteLength(line, "utf8") > MAX_MESSAGE_BYTES) {
    process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Request exceeds 1 MiB limit." } })}\n`);
    return;
  }
  let request: unknown;
  try {
    request = JSON.parse(line);
  } catch {
    process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error." } })}\n`);
    return;
  }
  const id = request && typeof request === "object" && "id" in request
    ? (request as { id?: unknown }).id ?? null
    : null;
  try {
    const response = await fetch(endpointUrl, {
      method: "POST",
      headers: {
        "authorization": `Bearer ${apiKey}`,
        "content-type": "application/json",
        "accept": "application/json",
      },
      body: line,
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    const body = await response.text();
    if (Buffer.byteLength(body, "utf8") > MAX_MESSAGE_BYTES) throw new Error("Upstream response exceeds 1 MiB limit");
    if (!response.ok) {
      let message = `Hosted MCP returned HTTP ${response.status}.`;
      try {
        const parsed = JSON.parse(body) as { error?: { message?: string } | string };
        if (typeof parsed.error === "string") message = parsed.error;
        else if (parsed.error?.message) message = parsed.error.message;
      } catch { /* keep bounded status message */ }
      process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32000, message } })}\n`);
      return;
    }
    JSON.parse(body); // Never emit malformed upstream content onto MCP stdio.
    process.stdout.write(`${body}\n`);
  } catch (error) {
    const message = error instanceof Error && error.name === "TimeoutError"
      ? "Hosted MCP request timed out."
      : "Hosted MCP is unavailable.";
    process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32000, message } })}\n`);
  }
}

input.on("line", line => {
  chain = chain.then(() => proxy(line));
});
input.on("close", () => {
  void chain.finally(() => process.exit(0));
});
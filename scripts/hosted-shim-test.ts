import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const entry = path.join(root, "dist/index.js");

async function run(env: Record<string, string>, messages: unknown[]) {
  const child = spawn(process.execPath, [entry], { env: { PATH: process.env.PATH ?? "", ...env }, stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
  child.stdout.on("data", value => { stdout += value; });
  child.stderr.on("data", value => { stderr += value; });
  for (const message of messages) child.stdin.write(`${JSON.stringify(message)}\n`);
  child.stdin.end();
  const [code] = await once(child, "close") as [number];
  return { code, stderr, output: stdout.trim() ? stdout.trim().split("\n").map(line => JSON.parse(line)) : [] };
}

const missing = await run({}, []);
assert.equal(missing.code, 1);
assert.match(missing.stderr, /POORBOYAI_API_KEY is required/);

const received: Array<{ auth: string | undefined; body: any }> = [];
const server = http.createServer((req, res) => {
  let body = "";
  req.setEncoding("utf8"); req.on("data", chunk => { body += chunk; });
  req.on("end", () => {
    const parsed = JSON.parse(body);
    received.push({ auth: req.headers.authorization, body: parsed });
    if (parsed.method === "fail") { res.writeHead(503); res.end(JSON.stringify({ error: "temporary failure" })); return; }
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ jsonrpc: "2.0", id: parsed.id, result: parsed.method === "tools/list" ? { tools: [{ name: "token_price" }] } : { protocolVersion: "2025-06-18" } }));
  });
});
server.listen(0, "127.0.0.1"); await once(server, "listening");
const address = server.address(); if (!address || typeof address === "string") throw new Error("No test address");
const env = { POORBOYAI_API_KEY: "pbai_test_secret", POORBOYAI_MCP_ENDPOINT: `http://127.0.0.1:${address.port}/mcp` };
const result = await run(env, [
  { jsonrpc: "2.0", id: 7, method: "initialize", params: {} },
  { jsonrpc: "2.0", id: "tools", method: "tools/list", params: {} },
  { jsonrpc: "2.0", id: 9, method: "fail", params: {} },
]);
server.close();
assert.equal(result.code, 0);
assert.equal(received.length, 3);
assert.ok(received.every(item => item.auth === "Bearer pbai_test_secret"));
assert.equal(result.output[0].id, 7);
assert.equal(result.output[1].id, "tools");
assert.deepEqual(result.output[1].result.tools, [{ name: "token_price" }]);
assert.equal(result.output[2].id, 9);
assert.equal(result.output[2].error.message, "temporary failure");
assert.doesNotMatch(result.stderr, /pbai_test_secret/);
console.log("Hosted MCP stdio proxy tests passed.");
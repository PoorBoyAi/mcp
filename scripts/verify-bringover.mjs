// Bring-over verification harness for @poorboyai/mcp (standalone home).
// Run: node scripts/verify-bringover.mjs
// Asserts the bring-over is complete, the dead domains are gone, the package
// builds + tests green, no secret value is in the tree, and the bot tree is
// untouched. Exits non-zero on any FAIL. Network checks SKIP (not fail) when
// the network is unavailable.
import { execSync, execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BOT = path.resolve(process.env.HOME ?? "~", "workspace/poorboyai-serverless-build/PoorBoyAI_bot");
let passed = 0, failed = 0, skipped = 0;

function pass(name) { passed++; console.log(`✅ ${name}`); }
function fail(name, detail = "") { failed++; console.log(`❌ ${name}${detail ? ` — ${detail}` : ""}`); }
function skip(name, why) { skipped++; console.log(`⏭️  ${name} — skipped (${why})`); }
function check(name, cond, detail = "") { cond ? pass(name) : fail(name, detail); }

function read(rel) { return fs.readFileSync(path.join(ROOT, rel), "utf8"); }
function exists(rel) { return fs.existsSync(path.join(ROOT, rel)); }
function sh(cmd, opts = {}) {
  try { return { ok: true, out: execSync(cmd, { encoding: "utf8", timeout: 120_000, ...opts }) }; }
  catch (e) { return { ok: false, out: String(e.stdout ?? "") + String(e.stderr ?? ""), code: e.status }; }
}

// 1. Files present
for (const f of ["package.json", "tsconfig.json", "README.md", ".gitignore",
  "src/index.ts", "scripts/hosted-shim-test.ts", "scripts/release-mcp.sh",
  "scripts/release-mcp.test.sh", ".github/workflows/mcp-ci.yml",
  ".github/workflows/mcp-publish.yml"]) {
  check(`file present: ${f}`, exists(f));
}

// 2. package.json identity + dead-link routing
const pkg = JSON.parse(read("package.json"));
check("package name is @poorboyai/mcp", pkg.name === "@poorboyai/mcp", pkg.name);
check("package version is 1.2.0", pkg.version === "1.2.0", pkg.version);
check("homepage is poorboyai.pages.dev", pkg.homepage === "https://poorboyai.pages.dev", pkg.homepage);
check("repository field omitted (repo does not exist)", pkg.repository === undefined);
check("test helper path is standalone (no ../../)", !JSON.stringify(pkg.scripts).includes("../.."));

// 3. No dead URLs anywhere in the tree (code/config/docs/workflows/scripts)
const treeFiles = [];
(function walk(dir) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    if (["node_modules", "dist", ".git"].includes(ent.name)) continue;
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p);
    else if (/\.(json|ts|md|yml|sh|js)$/.test(ent.name)) treeFiles.push(p);
  }
})(ROOT);
const deadUrlHits = [];
for (const f of treeFiles) {
  const text = fs.readFileSync(f, "utf8");
  if (text.includes("https://poorboyai.com") || text.includes("github.com/poorboyai")) {
    deadUrlHits.push(path.relative(ROOT, f));
  }
}
check("no dead https://poorboyai.com or github.com/poorboyai URLs in tree", deadUrlHits.length === 0, deadUrlHits.join(", "));
const shim = read("src/index.ts");
check("shim default endpoint is pages.dev", shim.includes('DEFAULT_ENDPOINT = "https://poorboyai.pages.dev/api/mcp"'));
check("shim has no live poorboyai.com endpoint", !shim.includes('https://poorboyai.com/api/mcp'));

// 4. Build output exists and points at the live endpoint
check("dist/index.js exists (build ran)", exists("dist/index.js"));
if (exists("dist/index.js")) {
  check("built output uses pages.dev endpoint", read("dist/index.js").includes("poorboyai.pages.dev/api/mcp"));
}

// 5. No secret values in the tree (CI secret *names* like secrets.NPM_TOKEN are fine)
const secretHits = [];
for (const f of treeFiles) {
  const text = fs.readFileSync(f, "utf8");
  if (/npm_[A-Za-z0-9]{20,}/.test(text) || /pbai_[A-Za-z0-9]{16,}/.test(text)) secretHits.push(path.relative(ROOT, f));
}
check("no npm_/pbai_ secret values in tree", secretHits.length === 0, secretHits.join(", "));
check("publish workflow uses CI secret name only",
  read(".github/workflows/mcp-publish.yml").includes("secrets.NPM_TOKEN"));

// 6. Full package test suite green
const t = sh("pnpm run test", { cwd: ROOT });
check("pnpm run test passes (release-helper 19 + build + shim)", t.ok && /19 passed, 0 failed/.test(t.out) && /Hosted MCP stdio proxy tests passed/.test(t.out),
  t.ok ? t.out.slice(-200) : `exit ${t.code}`);

// 7. Bot tree untouched
const md5 = sh(`md5sum ${BOT}/tgcloud/lib/tick.js ${BOT}/tgcloud/lib/market.js ${BOT}/tgcloud/endpoints/getDashboard.js`);
check("N3 md5s exact (tick efafb4da…, market 81ffdf01…, dashboard f403e7b7…)",
  md5.ok && md5.out.includes("efafb4daa0a98409ef0798cf69b7e8f7") && md5.out.includes("81ffdf013c147e99093756744e4d2aa3") && md5.out.includes("f403e7b780644e8d8527db3ac6bd79a1"));
const mods = sh(`find ${BOT}/tgcloud -name "*.js" | wc -l`);
check("bot module count still 100", mods.ok && mods.out.trim() === "100", mods.out.trim());
const st = sh(`python3 ${BOT}/tgc.py status`, { cwd: BOT });
check("tgc.py status: rev 559, working directory clean",
  st.ok && /Local revision: 559/.test(st.out) && /Working directory clean/.test(st.out));

// 8. npm registry: local version matches published latest (read-only)
const reg = sh("curl -s -m 15 https://registry.npmjs.org/@poorboyai/mcp/latest");
if (!reg.ok || !reg.out.trim().startsWith("{")) skip("registry latest matches local 1.2.0", "network unavailable");
else {
  try {
    const latest = JSON.parse(reg.out).version;
    check("registry latest matches local 1.2.0", latest === "1.2.0", `registry says ${latest}`);
  } catch { skip("registry latest matches local 1.2.0", "unparseable registry response"); }
}

console.log(`\nResults: ${passed} passed, ${failed} failed, ${skipped} skipped`);
process.exit(failed ? 1 : 0);

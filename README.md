# @poorboyai/mcp

The MCP client for [PoorBoyAI](https://poorboyai.pages.dev) — it lets apps and
agents talk to PB through the hosted MCP server. This package is a working
stdio-to-HTTPS launcher for the authenticated hosted service. It does not sell
a separate MCP plan. API and MCP use the same `pbai_` key from Dashboard
Settings.

The package intentionally exports no tool registry or local server API.

## Install

```bash
npx -y @poorboyai/mcp
```

Requires Node 18 or newer.

## Quick start

Get an API key from [Dashboard Settings](https://poorboyai.pages.dev/dashboard/)
(the $29 PB Plan includes 10 API/MCP keys; the 7-day free trial includes
none), then configure a stdio connection in Claude, Cursor, or another
MCP-compatible client:

```json
{
  "mcpServers": {
    "poorboyai": {
      "command": "npx",
      "args": ["-y", "@poorboyai/mcp"],
      "env": {
        "POORBOYAI_API_KEY": "pbai_your_key_here"
      }
    }
  }
}
```

Or run it directly:

```bash
POORBOYAI_API_KEY=pbai_your_key_here npx -y @poorboyai/mcp
```

The launcher sends the key in the `Authorization` header only — never in a URL
or a log. By default it talks to `https://poorboyai.pages.dev/api/mcp`.
`POORBOYAI_MCP_ENDPOINT` overrides the endpoint (HTTPS required, except for
local testing on `localhost`).

## Tools

The hosted server exposes its allowlist through authenticated MCP
`tools/list`. The seven tools in MCP v1 are:

| Tool | What it does |
| --- | --- |
| `account` | Your PB account, plan, and usage |
| `token_info` | Details for a token |
| `token_holders` | Top holders of a token |
| `token_price` | Live price for a token |
| `ask_pb` | Ask PB a question |
| `campaign_history` | Your past campaigns (read-only) |
| `airdrop_draft` | Draft an airdrop (creates a draft only — never sends) |

Wallet, transfer, airdrop sending, and boost launching are not part of MCP v1.
Image, video, and quote tools are not exposed until their shared Studio wallet
reservation contract is available.

## Requirements

- A PoorBoyAI account
- An active PB Plan ($29/mo) subscription and `POORBOYAI_API_KEY` from
  Dashboard Settings

## Releasing

From the repository root, release a stable version with one command:

```bash
./scripts/release-mcp.sh 1.2.3
```

The helper requires a clean working tree and a configured `origin` remote. It
updates this package's version, creates the commit
`chore: release @poorboyai/mcp v1.2.3`, creates the annotated `mcp-v1.2.3` tag,
and atomically pushes the current branch and tag. The publish workflow then
builds, smoke-tests, and publishes that exact tagged version to npm.

If the atomic push is rejected, resolve the Git issue and rerun the same
command. The helper recognizes the matching local release commit and tag and
safely retries the push without creating a second release commit.

The live npm version is 1.2.0; the first GitHub release will be 1.2.1.

## Links

- [PoorBoyAI](https://poorboyai.pages.dev)
- [PoorBoyAI Dashboard](https://poorboyai.pages.dev/dashboard/)
- [Get an API Key](https://poorboyai.pages.dev/dashboard/)
- [Telegram Bot](https://t.me/PoorBoyAI_bot)

## License

MIT — see [LICENSE](LICENSE).

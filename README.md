# MCP Proxy Server — Railway Edition

> **Fork of [ptbsare/mcp-proxy-server](https://github.com/ptbsare/mcp-proxy-server)** adapted for one-click deployment on [Railway](https://railway.app).  
> Currently configured with a **crypto-centric** tool stack. The MCP servers in `scripts/start.sh` can be swapped out for any other tools you need.

---

## What This Is

A self-hosted MCP (Model Context Protocol) hub that aggregates multiple backend MCP servers behind a single SSE/HTTP endpoint. Run it on Railway and point any MCP-compatible AI client (Claude, Cursor, Windsurf, etc.) at the single public URL to get access to all your tools at once.

---

## 🔌 Connected MCP Servers

The following Python packages are installed at container start-up by `scripts/start.sh`. They provide the current crypto-centric tool set:

| Package | Pinned Version | Purpose |
|---------|---------------|---------|
| `pip` | 24.2 | Package manager (pinned for reproducible deploys) |
| `mcp[cli]` | 1.4.1 | Core MCP Python SDK + CLI runner |
| `httpx` | 0.27.0 | HTTP client used by MCP tools |
| `pandas` | 2.2.2 | Data analysis — price feeds, on-chain data tables |
| `python-dotenv` | 1.0.1 | Load tool secrets from `.env` files |
| `tabulate` | 0.9.0 | Render data as human-readable tables |

> **Swapping tools:** Edit `scripts/start.sh` to install different pip or npm packages, then redeploy.  
> Add the resulting MCP server processes to `config/mcp_server.json` to expose them through the proxy.

---

## 🚀 Deploy on Railway

### One-click deploy

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/new/template)

### Manual steps

1. Fork this repository.
2. In Railway, create a new project → **Deploy from GitHub repo** → select your fork.
3. Railway auto-detects `deploy/Dockerfile` and builds the image.
4. Under **Variables**, set at minimum:

   | Variable | Recommended value |
   |----------|------------------|
   | `ENABLE_ADMIN_UI` | `true` |
   | `ADMIN_USERNAME` | your admin username |
   | `ADMIN_PASSWORD` | a strong password |
   | `ALLOWED_KEYS` | a comma-separated list of API keys for clients |
   | `SESSION_SECRET` | output of `openssl rand -hex 32` |

5. Railway assigns a public HTTPS URL. Your MCP endpoint is `https://<your-railway-url>/sse` (or `/mcp` for Streamable HTTP).

---

## ✨ Key Features

- **Web Admin UI** — manage all connected servers and their tools in a browser (`ENABLE_ADMIN_UI=true`).
- **Granular tool control** — enable/disable individual tools, override names and descriptions.
- **Flexible auth** — secure endpoints with API keys (`X-Api-Key` / `?key=`) or Bearer tokens.
- **Multiple transport types** — connects to Stdio, SSE, and Streamable HTTP backend servers.
- **Exposes unified endpoints** — `/sse` (SSE) and `/mcp` (Streamable HTTP) for clients.
- **Automatic retries** — exponential-backoff retries for SSE, HTTP, and Stdio tool calls.
- **Web terminal** — shell access inside the Admin UI (use with caution).

---

## Configuration

### `config/mcp_server.json`

Defines which backend MCP servers the proxy connects to and exposes. Copy the example:

```bash
cp config/mcp_server.json.example config/mcp_server.json
```

Example:

```json
{
  "mcpServers": {
    "my-crypto-server": {
      "type": "stdio",
      "name": "Crypto Data Tools",
      "active": true,
      "command": "python3",
      "args": ["-m", "my_crypto_mcp"],
      "env": {
        "API_KEY": "your_api_key"
      }
    },
    "remote-sse-server": {
      "type": "sse",
      "name": "Remote SSE Server",
      "active": true,
      "url": "https://example.com/sse",
      "apiKey": "remote_key"
    }
  }
}
```

**Key fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes | `"stdio"`, `"sse"`, or `"http"` |
| `active` | No (default `true`) | Set `false` to disable without removing |
| `command` | Stdio only | Command to run |
| `args` | Stdio only | Array of arguments |
| `env` | Stdio only | Extra environment variables for the process |
| `url` | SSE/HTTP only | Full URL of the backend endpoint |
| `apiKey` | SSE/HTTP only | Sent as `X-Api-Key` header to the backend |
| `bearerToken` | SSE/HTTP only | Sent as `Authorization: Bearer` to the backend |

### `config/tool_config.json`

Override tool properties (managed via Admin UI or edited manually):

```json
{
  "tools": {
    "my-crypto-server__get_price": {
      "enabled": true,
      "displayName": "Get Token Price",
      "description": "Fetches the current price for a given token."
    }
  }
}
```

Keys use the format `<server_key><separator><tool_name>` where separator defaults to `__` (controlled by `SERVER_TOOLNAME_SEPERATOR`).

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3663` | Proxy listen port (Railway sets this automatically via `$PORT`) |
| `ENABLE_ADMIN_UI` | `false` | Enable the web admin panel |
| `ADMIN_USERNAME` | `admin` | Admin UI username |
| `ADMIN_PASSWORD` | `password` | Admin UI password — **change this!** |
| `ALLOWED_KEYS` | *(none)* | Comma-separated client API keys |
| `ALLOWED_TOKENS` | *(none)* | Comma-separated client Bearer tokens |
| `SESSION_SECRET` | *(auto-generated)* | Cookie signing secret |
| `TOOLS_FOLDER` | `/tools` | Base dir for Admin UI server installs |
| `LOGGING` | `info` | Log level: `error`, `warn`, `info`, `debug` |
| `SERVER_TOOLNAME_SEPERATOR` | `__` | Separator between server key and tool name |
| `RETRY_SSE_TOOL_CALL` | `true` | Retry SSE tool calls on failure |
| `RETRY_HTTP_TOOL_CALL` | `true` | Retry HTTP tool calls on connection error |
| `RETRY_STDIO_TOOL_CALL` | `true` | Retry Stdio tool calls (restarts process) |

---

## Connecting a Client

### Claude Desktop (SSE)

```json
{
  "mcpServers": {
    "mcp-hub": {
      "type": "sse",
      "url": "https://<your-railway-url>/sse?key=<your_allowed_key>"
    }
  }
}
```

### Claude Desktop (Streamable HTTP)

```json
{
  "mcpServers": {
    "mcp-hub": {
      "type": "http",
      "url": "https://<your-railway-url>/mcp",
      "requestInit": {
        "headers": { "X-Api-Key": "<your_allowed_key>" }
      }
    }
  }
}
```

---

## Local Development

```bash
npm install
npm run build

# Run as Stdio MCP server
npm run dev

# Run as SSE server with Admin UI
ENABLE_ADMIN_UI=true npm run dev:sse
```

Build locally with Docker:

```bash
docker build -t mcp-proxy-server -f deploy/Dockerfile .
docker run -p 3663:3663 -e ENABLE_ADMIN_UI=true mcp-proxy-server
```

---

## Reference

- Upstream proxy: [ptbsare/mcp-proxy-server](https://github.com/ptbsare/mcp-proxy-server)
- Original inspiration: [adamwattis/mcp-proxy-server](https://github.com/adamwattis/mcp-proxy-server)
- [Model Context Protocol specification](https://modelcontextprotocol.io)

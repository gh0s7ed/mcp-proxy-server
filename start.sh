#!/usr/bin/env bash
set -euo pipefail

: "${GATEWAY_API_KEY:?Set GATEWAY_API_KEY in Railway Variables}"
: "${THEGRAPH_ACCESS_TOKEN:?Set THEGRAPH_ACCESS_TOKEN (Token API JWT) in Railway Variables}"
: "${COINGECKO_DEMO_API_KEY:?Set COINGECKO_DEMO_API_KEY in Railway Variables}"
: "${ALCHEMY_API_KEY:?Set ALCHEMY_API_KEY in Railway Variables}"
: "${DUNE_API_KEY:?Set DUNE_API_KEY in Railway Variables}"

ROOT_DIR="$(pwd)"
TOOLS_DIR="${TOOLS_DIR:-$ROOT_DIR/tools}"
DEFILLAMA_MCP_PORT="${DEFILLAMA_MCP_PORT:-18080}"

mkdir -p "$TOOLS_DIR" config

# --- Install Python deps needed for kukapay dune + demcp defillama (safe to run repeatedly) ---
python3 -m pip install --no-cache-dir --break-system-packages -U pip >/dev/null
python3 -m pip install --no-cache-dir --break-system-packages 
  "mcp[cli]>=1.4.1" httpx pandas python-dotenv >/dev/null

# --- Install uv (used by kukapay/dune-analytics-mcp) ---
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
  # uv installer places binaries in ~/.local/bin
  export PATH="$HOME/.local/bin:$PATH"
fi

# --- Fetch/prepare kukapay/dune-analytics-mcp (CSV query runner) ---
if [ ! -d "$TOOLS_DIR/dune-analytics-mcp" ]; then
  git clone --depth=1 https://github.com/kukapay/dune-analytics-mcp "$TOOLS_DIR/dune-analytics-mcp" >/dev/null
fi

# --- Fetch/prepare ekailabs/dune-mcp-server (preset metrics, EigenLayer, DEX, etc.) ---
if [ ! -d "$TOOLS_DIR/dune-mcp-server" ]; then
  git clone --depth=1 https://github.com/ekailabs/dune-mcp-server "$TOOLS_DIR/dune-mcp-server" >/dev/null
fi
( cd "$TOOLS_DIR/dune-mcp-server" && bun install >/dev/null )

# --- Start demcp defillama MCP as local SSE backend on a non-conflicting port ---
# demcp hardcodes 127.0.0.1:8080, patch it to use DEFILLAMA_MCP_PORT.
curl -fsSL https://raw.githubusercontent.com/demcp/demcp-defillama-mcp/master/defillama.py -o "$TOOLS_DIR/defillama.py"
python3 - <<PY
import pathlib, re
p = pathlib.Path(r"${TOOLS_DIR}/defillama.py")
s = p.read_text()
# replace FastMCP(... port=8080) with env-driven port
s = re.sub(r"port=8080", 'port=int(__import__("os").getenv("DEFILLAMA_MCP_PORT","18080"))', s)
# ensure it binds to all interfaces (important in some container runtimes)
s = re.sub(r'host="127\.0\.0\.1"', 'host="0.0.0.0"', s)
p.write_text(s)
PY

DEFILLAMA_MCP_PORT="${DEFILLAMA_MCP_PORT}" python3 "$TOOLS_DIR/defillama.py" >/dev/null 2>&1 &
DEFILLAMA_PID=$!

# Ensure the background SSE server actually booted before starting the Node hub.
# (Avoids silently continuing and later returning 502s from the proxy.)
sleep 3
if ! curl -fsS "http://127.0.0.1:${DEFILLAMA_MCP_PORT}/sse" >/dev/null 2>&1; then
  echo "DefiLlama MCP failed to start (PID=${DEFILLAMA_PID}) on port ${DEFILLAMA_MCP_PORT}" >&2
  # best-effort: show if process is still alive
  if ! kill -0 "${DEFILLAMA_PID}" >/dev/null 2>&1; then
    echo "DefiLlama MCP process is not running." >&2
  fi
  exit 1
fi

# --- MCP server registry ---
cat > config/mcp_server.json <<EOF
{
  "mcpServers": {
    "coingecko_demo": {
      "type": "stdio",
      "name": "CoinGecko Demo MCP",
      "active": true,
      "command": "npx",
      "args": ["-y", "@coingecko/coingecko-mcp"],
      "env": {
        "COINGECKO_ENVIRONMENT": "demo",
        "COINGECKO_DEMO_API_KEY": "${COINGECKO_DEMO_API_KEY}"
      }
    },

    "subgraph": {
      "type": "sse",
      "name": "The Graph Subgraphs MCP",
      "active": true,
      "url": "https://subgraphs.mcp.thegraph.com/sse",
      "bearerToken": "${GATEWAY_API_KEY}"
    },

    "token_api": {
      "type": "stdio",
      "name": "The Graph Token API MCP",
      "active": true,
      "command": "npx",
      "args": ["-y", "@pinax/mcp", "--remote-url", "https://token-api.mcp.thegraph.com/"],
      "env": {
        "ACCESS_TOKEN": "${THEGRAPH_ACCESS_TOKEN}"
      }
    },

    "alchemy": {
      "type": "stdio",
      "name": "Alchemy MCP",
      "active": true,
      "command": "npx",
      "args": ["-y", "@alchemy/mcp-server"],
      "env": {
        "ALCHEMY_API_KEY": "${ALCHEMY_API_KEY}",
        "AGENT_WALLET_SERVER": "https://disabled.local"
      }
    },

    "dune_custom": {
      "type": "stdio",
      "name": "Dune Custom Queries (CSV) MCP",
      "active": true,
      "command": "uv",
      "args": ["run", "--directory", "${TOOLS_DIR}/dune-analytics-mcp", "python", "main.py"],
      "env": {
        "DUNE_API_KEY": "${DUNE_API_KEY}"
      }
    },

    "dune_preset": {
      "type": "stdio",
      "name": "Dune Preset Metrics MCP",
      "active": true,
      "command": "bun",
      "args": ["${TOOLS_DIR}/dune-mcp-server/src/index.ts", "stdio"],
      "env": {
        "DUNE_API_KEY": "${DUNE_API_KEY}"
      }
    },

    "defillama": {
      "type": "sse",
      "name": "DefiLlama MCP (prices, protocol tvl, pool chart)",
      "active": true,
      "url": "http://127.0.0.1:${DEFILLAMA_MCP_PORT}/sse"
    }
  }
}
EOF

# --- Tool allowlist/denylist (only keep what you said you actually want) ---
cat > config/tool_config.json <<EOF
{
  "tools": {
    "defillama__get_token_prices": { "enabled": true },
    "defillama__get_protocol_tvl": { "enabled": true },
    "defillama__get_pool_tvl": { "enabled": true },

    "defillama__get_protocols": { "enabled": false },
    "defillama__get_chain_tvl": { "enabled": false },
    "defillama__get_pools": { "enabled": false },

    "dune_custom__run_query": { "enabled": true },
    "dune_custom__get_latest_result": { "enabled": true },

    "dune_preset__get_eigenlayer_avs_metrics": { "enabled": true },
    "dune_preset__get_eigenlayer_operator_metrics": { "enabled": true },
    "dune_preset__get_dex_pair_metrics": { "enabled": true },
    "dune_preset__get_token_pairs_liquidity": { "enabled": true },
    "dune_preset__get_svm_token_balances": { "enabled": false }
  }
}
EOF

npm run build
exec node build/sse.js

#!/usr/bin/env bash
set -euo pipefail

: "${GATEWAY_API_KEY:?Set GATEWAY_API_KEY in Railway Variables}"
: "${COINGECKO_DEMO_API_KEY:?Set COINGECKO_DEMO_API_KEY in Railway Variables}"
: "${THEGRAPH_ACCESS_TOKEN:?Set THEGRAPH_ACCESS_TOKEN (JWT) in Railway Variables}"

mkdir -p config

cat > config/mcp_server.json <<EOF
{
  "mcpServers": {
    "subgraph": {
      "type": "sse",
      "name": "The Graph Subgraphs MCP",
      "active": true,
      "url": "https://subgraphs.mcp.thegraph.com/sse",
      "bearerToken": "${GATEWAY_API_KEY}"
    },
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
    }
  }
}
EOF

# ensure build exists (creates build/sse.js per tsconfig outDir=./build)
npm run build

exec node build/sse.js

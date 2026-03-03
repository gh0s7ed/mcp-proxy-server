#!/usr/bin/env bash
set -euo pipefail

: "${GATEWAY_API_KEY:?Set GATEWAY_API_KEY in Railway Variables}"
: "${THEGRAPH_ACCESS_TOKEN:?Set THEGRAPH_ACCESS_TOKEN (Token API JWT) in Railway Variables}"
: "${COINGECKO_DEMO_API_KEY:?Set COINGECKO_DEMO_API_KEY in Railway Variables}"
: "${ALCHEMY_API_KEY:?Set ALCHEMY_API_KEY in Railway Variables}"
: "${DUNE_API_KEY:?Set DUNE_API_KEY in Railway Variables}"
: "${ETHERSCAN_API_KEY:?Set ETHERSCAN_API_KEY in Railway Variables}"
: "${GOPLUS_API_KEY:?Set GOPLUS_API_KEY in Railway Variables}"
: "${GOPLUS_API_SECRET:?Set GOPLUS_API_SECRET in Railway Variables}"
: "${WHALE_ALERT_API_KEY:?Set WHALE_ALERT_API_KEY in Railway Variables}"
: "${DUNE_SIM_API_KEY:?Set DUNE_SIM_API_KEY in Railway Variables}"

ROOT_DIR="$(pwd)"
TOOLS_DIR="${TOOLS_DIR:-$ROOT_DIR/tools}"
DEFILLAMA_MCP_PORT="${DEFILLAMA_MCP_PORT:-18080}"

mkdir -p "$TOOLS_DIR" config

# --- Install Python deps needed for kukapay dune, demcp defillama, wallet-inspector (safe to run repeatedly) ---
python3 -m pip install --no-cache-dir --break-system-packages -U pip >/dev/null
python3 -m pip install --no-cache-dir --break-system-packages "mcp[cli]>=1.4.1" httpx pandas python-dotenv tabulate >/dev/null

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

# --- Install Bun (used by ekailabs/dune-mcp-server) ---
if ! command -v bun >/dev/null 2>&1; then
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$PATH"
fi

# --- Fetch/prepare ekailabs/dune-mcp-server (preset metrics, EigenLayer, DEX, etc.) ---
if [ ! -d "$TOOLS_DIR/dune-mcp-server" ]; then
  git clone --depth=1 https://github.com/ekailabs/dune-mcp-server "$TOOLS_DIR/dune-mcp-server" >/dev/null
fi
cd "$TOOLS_DIR/dune-mcp-server"
bun install --no-save
cd "$ROOT_DIR"

# --- Fetch/prepare kukapay/whale-tracker-mcp ---
if [ ! -d "$TOOLS_DIR/whale-tracker-mcp" ]; then
  git clone --depth=1 https://github.com/kukapay/whale-tracker-mcp "$TOOLS_DIR/whale-tracker-mcp" >/dev/null
fi

# --- Fetch/prepare kukapay/wallet-inspector-mcp ---
if [ ! -d "$TOOLS_DIR/wallet-inspector-mcp" ]; then
  git clone --depth=1 https://github.com/kukapay/wallet-inspector-mcp "$TOOLS_DIR/wallet-inspector-mcp" >/dev/null
fi

# --- Fetch/prepare foodaka/aave-v3-mcp ---
if [ ! -d "$TOOLS_DIR/aave-v3-mcp" ]; then
  git clone --depth=1 https://github.com/foodaka/aave-v3-mcp "$TOOLS_DIR/aave-v3-mcp" >/dev/null
fi

# --- Fetch/prepare dennisonbertram/mcp-etherscan-server ---
if [ ! -d "$TOOLS_DIR/mcp-etherscan-server" ]; then
  git clone --depth=1 https://github.com/dennisonbertram/mcp-etherscan-server "$TOOLS_DIR/mcp-etherscan-server" >/dev/null
fi
cd "$TOOLS_DIR/mcp-etherscan-server"
npm install >/dev/null
npm run build >/dev/null
cd "$ROOT_DIR"

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
echo "Waiting for DefiLlama FastMCP to bind to port ${DEFILLAMA_MCP_PORT}..."
timeout 10 bash -c "until printf '' 2>>/dev/null >>/dev/tcp/127.0.0.1/${DEFILLAMA_MCP_PORT}; do sleep 1; done" || {
  echo "DefiLlama MCP failed to start (PID=${DEFILLAMA_PID}) on port ${DEFILLAMA_MCP_PORT}" >&2
  if ! kill -0 "${DEFILLAMA_PID}" >/dev/null 2>&1; then
    echo "DefiLlama MCP process is not running." >&2
  fi
  exit 1
}
echo "DefiLlama MCP is live on port ${DEFILLAMA_MCP_PORT}!"

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

    "etherscan": {
      "type": "stdio",
      "name": "Etherscan MCP (V2, multi-chain)",
      "active": true,
      "command": "node",
      "args": ["${TOOLS_DIR}/mcp-etherscan-server/build/index.js"],
      "env": {
        "ETHERSCAN_API_KEY": "${ETHERSCAN_API_KEY}"
      }
    },

    "goplus": {
      "type": "stdio",
      "name": "GoPlus Security MCP",
      "active": true,
      "command": "npx",
      "args": [
        "-y",
        "goplus-mcp@latest",
        "--key",
        "${GOPLUS_API_KEY}",
        "--secret",
        "${GOPLUS_API_SECRET}"
      ]
    },

    "whale_tracker": {
      "type": "stdio",
      "name": "Whale Tracker MCP (Whale Alert)",
      "active": true,
      "command": "python3",
      "args": ["${TOOLS_DIR}/whale-tracker-mcp/whale_tracker.py"],
      "env": {
        "WHALE_ALERT_API_KEY": "${WHALE_ALERT_API_KEY}"
      }
    },

    "wallet_inspector": {
      "type": "stdio",
      "name": "Wallet Inspector MCP",
      "active": true,
      "command": "uv",
      "args": ["--directory", "${TOOLS_DIR}/wallet-inspector-mcp", "run", "main.py"],
      "env": {
        "DUNE_SIM_API_KEY": "${DUNE_SIM_API_KEY}"
      }
    },

    "aave_v3": {
      "type": "stdio",
      "name": "Aave V3 MCP",
      "active": true,
      "command": "python3",
      "args": ["${TOOLS_DIR}/aave-v3-mcp/aave_mcp_server.py"]
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
cat > config/tool_config.json <<'EOF'
{
  "tools": {
    "defillama__get_pool_tvl": {
      "enabled": true,
      "exposedDescription": "PRIMARY yield hunting tool. Returns live APY and TVL for DeFi pools across Curve, Aave, Convex, Lido, Uniswap. Use first when searching for yield. Prioritize TVL above $5M."
    },
    "defillama__get_token_prices": {
      "enabled": true,
      "exposedDescription": "Real-time token prices across all chains. Use when calculating recursive borrowing LTV ratios, liquidation thresholds, or comparing yield in USD terms."
    },
    "defillama__get_protocol_tvl": {
      "enabled": true,
      "exposedDescription": "Returns total TVL for a DeFi protocol. Use to assess protocol safety and size before recommending it for yield deployment."
    },
    "defillama__get_chain_tvl": {
      "enabled": true,
      "exposedDescription": "Returns TVL for a specific chain. Use to compare chain size and liquidity concentration before selecting where to deploy capital."
    },

    "token_api__getV1EvmPools": {
      "enabled": true,
      "exposedDescription": "Returns DEX pool metadata including tokens, fees, and protocol. Use to find Curve, Uniswap V3, or Balancer LP pool addresses for further analysis."
    },
    "token_api__getV1EvmPoolsOhlc": {
      "enabled": true,
      "exposedDescription": "OHLCV price history for a specific DEX pool. Use to assess whether a pool has consistent volume (sustainable fee yield) or is declining."
    },
    "token_api__getV1EvmSwaps": {
      "enabled": true,
      "exposedDescription": "Returns recent swap events for a pool. High swap volume often implies higher fee APY for LPs. Use to validate active trading before recommending."
    },
    "token_api__getV1EvmDexes": {
      "enabled": true,
      "exposedDescription": "Lists all supported DEXs on a given chain. Use to discover which protocols are active on Arbitrum, Base, Optimism, etc."
    },
    "token_api__getV1EvmBalances": {
      "enabled": true,
      "exposedDescription": "Returns ERC-20 token balances for a wallet. Use to check current positions before recommending reallocation."
    },

    "dune_custom__run_query": {
      "enabled": true,
      "exposedDescription": "Executes a custom Dune Analytics SQL query by ID. Use for advanced on-chain data: Curve gauge APYs, Aave borrow rates, veCRV boost data, or any protocol-specific metric not available elsewhere."
    },
    "dune_custom__get_latest_result": {
      "enabled": true,
      "exposedDescription": "Fetches the cached result of a previously run Dune query. Faster than re-running. Use when a query has been run recently and fresh data is not critical."
    },
    "dune_preset__get_dex_pair_metrics": {
      "enabled": true,
      "exposedDescription": "Volume and liquidity metrics for DEX token pairs. Use to compare trading activity between pairs when evaluating LP yield opportunities."
    },
    "dune_preset__get_token_pairs_liquidity": {
      "enabled": true,
      "exposedDescription": "Liquidity depth for token pairs. Use to assess slippage risk in recursive borrowing strategies or large position entries."
    },
    "dune_preset__get_eigenlayer_avs_metrics": {
      "enabled": true,
      "exposedDescription": "EigenLayer AVS metrics. Use to evaluate AVS size, growth, and activity before considering restaking exposure."
    },
    "dune_preset__get_eigenlayer_operator_metrics": {
      "enabled": true,
      "exposedDescription": "EigenLayer operator metrics. Use to compare operator performance and concentration risk when evaluating restaking exposure."
    },

    "subgraph__execute_query_by_deployment_id": {
      "enabled": true,
      "exposedDescription": "Execute a GraphQL query against a specific deployment ID (0x...). Use when you know the exact deployment you want to query and need deterministic results."
    },
    "subgraph__execute_query_by_ipfs_hash": {
      "enabled": true,
      "exposedDescription": "Execute a GraphQL query against a specific IPFS hash (Qm...). Use when you have the IPFS hash for a deployment and want to query that exact immutable version."
    },
    "subgraph__execute_query_by_subgraph_id": {
      "enabled": true,
      "exposedDescription": "Execute a GraphQL query against the latest deployment for a subgraph ID. Use when you want 'current' data without manually tracking deployment IDs."
    },
    "subgraph__get_deployment_30day_query_counts": {
      "enabled": true,
      "exposedDescription": "Get aggregate query counts over the last 30 days for multiple deployments, sorted descending. Use to validate adoption / usage before relying on a subgraph."
    },
    "subgraph__get_schema_by_deployment_id": {
      "enabled": true,
      "exposedDescription": "Fetch the GraphQL schema for a deployment by deployment ID (0x...). Use before writing queries to ensure field names/types match."
    },
    "subgraph__get_schema_by_ipfs_hash": {
      "enabled": true,
      "exposedDescription": "Fetch the GraphQL schema for a deployment by IPFS hash (Qm...). Use before writing queries when you are targeting an immutable IPFS-pinned deployment."
    },
    "subgraph__get_schema_by_subgraph_id": {
      "enabled": true,
      "exposedDescription": "Fetch the GraphQL schema for the current version of a subgraph by subgraph ID. Use before writing queries against 'latest' deployments."
    },
    "subgraph__get_top_subgraph_deployments": {
      "enabled": true,
      "exposedDescription": "Get the top 3 subgraph deployments for a contract address + chain, ordered by query fees. For chain use 'mainnet' for Ethereum mainnet (never 'ethereum'). Use to discover the best subgraph to query for an address."
    },
    "subgraph__search_subgraphs_by_keyword": {
      "enabled": true,
      "exposedDescription": "Search for subgraphs by keyword in display name ordered by signal. Use to discover candidate subgraphs, then fetch schema and query the best match."
    },

    "etherscan__check-balance": {
      "enabled": true,
      "exposedDescription": "Get native token balance for an address on any supported Etherscan V2 chain."
    },
    "etherscan__get-transactions": {
      "enabled": true,
      "exposedDescription": "Fetch recent normal transactions for an address (timestamps, value, from/to)."
    },
    "etherscan__get-token-transfers": {
      "enabled": true,
      "exposedDescription": "Fetch ERC20 token transfer history for an address."
    },
    "etherscan__get-token-portfolio": {
      "enabled": true,
      "exposedDescription": "Get all token balances for an address (portfolio view)."
    },
    "etherscan__get-token-info": {
      "enabled": true,
      "exposedDescription": "Get token metadata and details for a token contract address."
    },
    "etherscan__get-token-holders": {
      "enabled": true,
      "exposedDescription": "Get top holders for a token contract (concentration and distribution checks)."
    },
    "etherscan__get-contract-abi": {
      "enabled": true,
      "exposedDescription": "Fetch a verified contract ABI for decoding/interacting safely."
    },
    "etherscan__get-contract-source": {
      "enabled": true,
      "exposedDescription": "Fetch verified source code and metadata for a contract (quick sanity check)."
    },
    "etherscan__get-contract-creation": {
      "enabled": true,
      "exposedDescription": "Find contract creator + creation transaction (provenance checks)."
    },
    "etherscan__get-gas-prices": {
      "enabled": true,
      "exposedDescription": "Get current gas price tiers in Gwei for the selected network."
    },
    "etherscan__get-ens-name": {
      "enabled": true,
      "exposedDescription": "Resolve an address to ENS (if available)."
    },
    "etherscan__get-logs": {
      "enabled": true,
      "exposedDescription": "Query event logs with topic filtering (for contract activity / signals)."
    },
    "etherscan__list-networks": {
      "enabled": true,
      "exposedDescription": "List supported chain IDs/networks available via Etherscan V2."
    },
    "etherscan__get-block-details": {
      "enabled": true,
      "exposedDescription": "Fetch block details (hash, gas, tx count) for troubleshooting/analysis."
    },

    "goplus__token_security": {
      "enabled": true,
      "exposedDescription": "Token security analysis (honeypot flags, liquidity, holder concentration) for EVM chains."
    },
    "goplus__malicious_address": {
      "enabled": true,
      "exposedDescription": "Check if an address is malicious or associated with scams across supported chains."
    },
    "goplus__phishing_website": {
      "enabled": true,
      "exposedDescription": "Check whether a URL is a known phishing/malicious site."
    },
    "goplus__nft_security": {
      "enabled": true,
      "exposedDescription": "NFT contract security analysis (optional token ID)."
    },
    "goplus__approval_security": {
      "enabled": true,
      "exposedDescription": "Analyze token approvals for a wallet and flag risky allowances."
    },
    "goplus__solana_token_security": {
      "enabled": true,
      "exposedDescription": "Solana token security checks (mint authority, freeze, mutability)."
    },
    "goplus__sui_token_security": {
      "enabled": true,
      "exposedDescription": "Sui token security checks (upgradeability and capability ownership)."
    },

    "whale_tracker__get_recent_transactions": {
      "enabled": true,
      "exposedDescription": "Fetch recent whale transactions with optional filters (chain, min USD value, limit)."
    },
    "whale_tracker__get_transaction_details": {
      "enabled": true,
      "exposedDescription": "Fetch detailed whale transaction info by Whale Alert transaction ID."
    },

    "wallet_inspector__get_wallet_balance": {
      "enabled": true,
      "exposedDescription": "Cross-chain wallet balances (EVM + Solana) formatted for quick review."
    },
    "wallet_inspector__get_wallet_activity": {
      "enabled": true,
      "exposedDescription": "EVM wallet activity feed (types, assets, USD value) for behavior analysis."
    },
    "wallet_inspector__get_wallet_transactions": {
      "enabled": true,
      "exposedDescription": "Wallet transaction history (EVM + Solana) with an optional limit."
    },

    "aave_v3__get_supported_chains": {
      "enabled": true,
      "exposedDescription": "List Aave V3 supported chains and IDs."
    },
    "aave_v3__get_markets": {
      "enabled": true,
      "exposedDescription": "Fetch Aave markets across chains with TVL/liquidity and top asset APYs."
    },
    "aave_v3__get_market_details": {
      "enabled": true,
      "exposedDescription": "Deep market details for a specific Aave pool (reserves, caps, risk params)."
    },
    "aave_v3__get_user_positions": {
      "enabled": true,
      "exposedDescription": "User supply/borrow positions across chains with totals and position breakdown."
    },
    "aave_v3__get_user_market_state": {
      "enabled": true,
      "exposedDescription": "User health factor and liquidation risk for a specific Aave market."
    },
    "aave_v3__get_user_transaction_history": {
      "enabled": true,
      "exposedDescription": "User transaction history for Aave activity analysis."
    },
    "aave_v3__get_reserve_details": {
      "enabled": true,
      "exposedDescription": "Reserve details for an asset (APY, caps, collateral params, risk)."
    },
    "aave_v3__get_apy_history": {
      "enabled": true,
      "exposedDescription": "Historical APY for supply or borrow for an asset/market."
    },
    "aave_v3__prepare_supply_transaction": {
      "enabled": true,
      "exposedDescription": "Prepare a supply/deposit tx payload (no signing, just tx data)."
    },
    "aave_v3__prepare_borrow_transaction": {
      "enabled": true,
      "exposedDescription": "Prepare a borrow tx payload (no signing, just tx data)."
    },
    "aave_v3__prepare_repay_transaction": {
      "enabled": true,
      "exposedDescription": "Prepare a repay tx payload (no signing, just tx data)."
    },
    "aave_v3__prepare_withdraw_transaction": {
      "enabled": true,
      "exposedDescription": "Prepare a withdraw tx payload (no signing, just tx data)."
    },
    "aave_v3__get_vaults": {
      "enabled": true,
      "exposedDescription": "List Aave yield vault strategies."
    },
    "aave_v3__get_vault_details": {
      "enabled": true,
      "exposedDescription": "Detailed vault info for evaluating yield strategies."
    },
    "aave_v3__get_gho_balance": {
      "enabled": true,
      "exposedDescription": "Get sGHO (staked GHO) balance."
    },

    "defillama__get_protocols": {
      "enabled": false
    },
    "defillama__get_pools": {
      "enabled": false
    },
    "dune_preset__get_svm_token_balances": {
      "enabled": false
    },
    "token_api__getV1EvmBalancesHistorical": {
      "enabled": false
    },
    "token_api__getV1EvmBalancesHistoricalNative": {
      "enabled": false
    },
    "token_api__getV1EvmBalancesNative": {
      "enabled": false
    },
    "token_api__getV1EvmNftCollections": {
      "enabled": false
    },
    "token_api__getV1EvmNftHolders": {
      "enabled": false
    },
    "token_api__getV1EvmNftItems": {
      "enabled": false
    },
    "token_api__getV1EvmNftSales": {
      "enabled": false
    },
    "token_api__getV1EvmNftTransfers": {
      "enabled": false
    },
    "token_api__getV1EvmNftOwnerships": {
      "enabled": false
    },
    "token_api__getV1EvmTokens": {
      "enabled": false
    },
    "token_api__getV1EvmHolders": {
      "enabled": false
    },
    "token_api__getV1EvmHoldersNative": {
      "enabled": false
    },
    "token_api__getV1TvmPools": {
      "enabled": false
    },
    "token_api__getV1TvmSwaps": {
      "enabled": false
    },
    "token_api__getV1TvmTokens": {
      "enabled": false
    },
    "token_api__getV1SvmOwner": {
      "enabled": false
    },

    "etherscan__get-internal-transactions": { "enabled": false },
    "etherscan__get-mined-blocks": { "enabled": false },
    "etherscan__get-beacon-withdrawals": { "enabled": false },

    "etherscan__verify-contract": { "enabled": false },
    "etherscan__check-verification": { "enabled": false },
    "etherscan__verify-proxy": { "enabled": false },
    "etherscan__get-verified-contracts": { "enabled": false },

    "etherscan__get-block-reward": { "enabled": false },
    "etherscan__get-network-stats": { "enabled": false },
    "etherscan__get-daily-stats": { "enabled": false }
  }
}
EOF

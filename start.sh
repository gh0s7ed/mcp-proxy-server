# Check for THEGRAPH_ACCESS_TOKEN environment variable
if [ -z "$THEGRAPH_ACCESS_TOKEN" ]; then
  echo "Error: THEGRAPH_ACCESS_TOKEN is not set."
  exit 1
fi

# Existing mcpServers entries...
# ...
mcpServers:
  token_api:
    command: npx -y @pinax/mcp --remote-url https://token-api.mcp.thegraph.com/
    env:
      ACCESS_TOKEN: ${THEGRAPH_ACCESS_TOKEN}
# ...
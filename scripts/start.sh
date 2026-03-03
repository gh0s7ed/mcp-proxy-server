# Pin versions for reproducible deploys (avoid breakage from upstream releases)
PY_PIP_VERSION="24.2"
PY_MCP_VERSION="1.4.1"
PY_HTTPX_VERSION="0.27.0"
PY_PANDAS_VERSION="2.2.2"
PY_DOTENV_VERSION="1.0.1"
PY_TABULATE_VERSION="0.9.0"

python3 -m pip install --no-cache-dir --break-system-packages "pip==${PY_PIP_VERSION}" >/dev/null
python3 -m pip install --no-cache-dir --break-system-packages \
  "mcp[cli]==${PY_MCP_VERSION}" \
  "httpx==${PY_HTTPX_VERSION}" \
  "pandas==${PY_PANDAS_VERSION}" \
  "python-dotenv==${PY_DOTENV_VERSION}" \
  "tabulate==${PY_TABULATE_VERSION}" \
  >/dev/null

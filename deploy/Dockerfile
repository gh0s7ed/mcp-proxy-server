ARG BUILD_FROM=nikolaik/python-nodejs:python3.12-nodejs22

FROM $BUILD_FROM AS base
WORKDIR /mcp-proxy-server

# Arguments for pre-installed packages.
# These allow users to inject packages at build time.
ARG PRE_INSTALLED_PIP_PACKAGES_ARG=""
ARG PRE_INSTALLED_NPM_PACKAGES_ARG=""
ARG PRE_INSTALLED_INIT_COMMAND_ARG=""

# --- OS Level Setup ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    build-essential \
    python3-dev \
    libffi-dev \
    libssl-dev \
    curl \
    unzip \
    ca-certificates \
    bash \
    ffmpeg \
    git \
    vim \
    dnsutils \
    iputils-ping \
    tini \
    gnupg \
    golang \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g pnpm bun

RUN if [ -n "$PRE_INSTALLED_PIP_PACKAGES_ARG" ]; then \
      echo "Installing pre-defined PIP packages: $PRE_INSTALLED_PIP_PACKAGES_ARG" && \
      pip install --break-system-packages --no-cache-dir $PRE_INSTALLED_PIP_PACKAGES_ARG; \
    else \
      echo "Skipping pre-defined PIP packages installation."; \
    fi

RUN if [ -n "$PRE_INSTALLED_NPM_PACKAGES_ARG" ]; then \
      echo "Installing pre-defined NPM packages: $PRE_INSTALLED_NPM_PACKAGES_ARG" && \
      npm install -g $PRE_INSTALLED_NPM_PACKAGES_ARG; \
    else \
      echo "Skipping pre-defined NPM packages installation."; \
    fi

RUN if [ -n "$PRE_INSTALLED_INIT_COMMAND_ARG" ]; then \
      echo "Running pre-defined init command: $PRE_INSTALLED_INIT_COMMAND_ARG" && \
      eval $PRE_INSTALLED_INIT_COMMAND_ARG; \
    else \
      echo "Skipping pre-defined init command."; \
    fi

COPY . .

RUN npm install
RUN npm run build

# --- Environment Variables ---
# Port for the SSE server (and Admin UI if enabled)
ENV PORT=3663

# Optional: Allowed API keys for SSE endpoint (comma-separated)
# ENV MCP_PROXY_SSE_ALLOWED_KEYS=""
# Optional: Enable Admin Web UI (set to "true" to enable)
ENV ENABLE_ADMIN_UI=false

# Optional: Admin UI Credentials (required if ENABLE_ADMIN_UI=true)
# It's recommended to set these via `docker run -e` instead of hardcoding here
ENV ADMIN_USERNAME=admin
ENV ADMIN_PASSWORD=password

# Optional: Default folder for Stdio server installations via Admin UI
ENV TOOLS_FOLDER=/tools

# --- Expose Port ---
EXPOSE 3663

# --- Entrypoint & Command ---
ENTRYPOINT ["tini", "--"]
CMD ["bash", "scripts/start.sh"]
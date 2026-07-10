#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# vast-hermes-bootstrap.sh
# Vast.ai instance'ında komple bootstrap:
#   gh CLI + auth  →  Hermes kurulum  →  Gateway açılışı
#
# KULLANIM:
#   export GITHUB_TOKEN="ghp_..."
#   export OPENCODE_GO_API_KEY="sk-..."
#   bash <(curl -fsSL https://raw.githubusercontent.com/ddawnlll/vast-hermes-bootstrap/main/bootstrap.sh)
# ============================================================

# === CONFIG ===
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
HERMES_PROVIDER="${HERMES_PROVIDER:-opencode-go}"
HERMES_MODEL="${HERMES_MODEL:-deepseek-v4-flash}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

: "${OPENCODE_GO_API_KEY:?OPENCODE_GO_API_KEY not set}"

log()  { echo -e "[\e[34m*\e[0m] $*"; }
ok()   { echo -e "[\e[32m\xe2\x9c\x93\e[0m] $*"; }
fail() { echo -e "[\e[31m!\e[0m] $*"; }

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:$PATH"

# ============================================================
# 1. SYSTEM DEPS
# ============================================================
log "System dependencies..."
sudo -S -p '' apt-get update -qq 2>/dev/null || true
sudo -S -p '' apt-get install -y -qq curl git jq 2>/dev/null || true

# ============================================================
# 2. GH CLI + AUTH
# ============================================================
log "GitHub CLI setup..."
if ! command -v gh &>/dev/null; then
    log "Installing gh CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
        sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
        sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo -S -p '' apt-get update -qq && sudo -S -p '' apt-get install -y -qq gh 2>/dev/null || {
        log "Falling back to gh binary download..."
        GH_VERSION=$(curl -sL https://api.github.com/repos/cli/cli/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
        curl -sL "https://github.com/cli/cli/releases/download/${GH_VERSION}/gh_${GH_VERSION#v}_linux_amd64.tar.gz" -o /tmp/gh.tar.gz
        tar xzf /tmp/gh.tar.gz -C /tmp/
        sudo -S -p '' mv /tmp/gh_*/bin/gh /usr/local/bin/
        rm -rf /tmp/gh_* /tmp/gh.tar.gz
    }
fi

if [ -n "$GITHUB_TOKEN" ]; then
    echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null || true
    ok "gh auth: $(gh auth status --show-token 2>&1 | grep -oP 'account \K\S+' || echo 'done')"
else
    log "GITHUB_TOKEN not set — skipping gh auth"
fi

# ============================================================
# 3. HERMES
# ============================================================
if ! command -v hermes &>/dev/null; then
    log "Installing Hermes Agent..."
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
    export PATH="$HOME/.local/bin:$PATH"
    mkdir -p "$HOME/.local/bin"
    grep -q '\.local/bin' "$HOME/.bashrc" 2>/dev/null \
        || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    grep -q '\.local/bin' "$HOME/.bash_profile" 2>/dev/null \
        || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bash_profile"
fi

ok "Hermes $(hermes --version 2>/dev/null || echo 'installed')"

# ============================================================
# 4. CREDENTIALS
# ============================================================
log "Configuring credentials..."
mkdir -p "$HERMES_HOME"

cat > "$HERMES_HOME/.env" << EOF
OPENCODE_GO_API_KEY=${OPENCODE_GO_API_KEY}
EOF

if [ -n "$GITHUB_TOKEN" ]; then
    echo "GITHUB_TOKEN=${GITHUB_TOKEN}" >> "$HERMES_HOME/.env"
fi
chmod 600 "$HERMES_HOME/.env"
ok ".env created ($(wc -l < "$HERMES_HOME/.env") entries)"

# ============================================================
# 5. CONFIGURE
# ============================================================
log "Configuring model & provider..."
hermes config set model.provider "$HERMES_PROVIDER" 2>/dev/null || true
hermes config set model.default "$HERMES_MODEL" 2>/dev/null || true
ok "Provider=$HERMES_PROVIDER Model=$HERMES_MODEL"

# ============================================================
# 6. SANITY
# ============================================================
log "Sanity check..."
hermes doctor --fix 2>/dev/null | tail -3 || true

# ============================================================
# 7. GATEWAY
# ============================================================
log "Starting Hermes Gateway..."
pkill -f "hermes gateway" 2>/dev/null || true
sleep 1

nohup hermes gateway run > "$HERMES_HOME/gateway.log" 2>&1 &
GATEWAY_PID=$!

sleep 4
if kill -0 "$GATEWAY_PID" 2>/dev/null; then
    ok "Gateway RUNNING (PID: $GATEWAY_PID)"
    echo ""
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │  HERMES GATEWAY LIVE                        │"
    echo "  │  PID: $GATEWAY_PID                          │"
    echo "  │  Logs: ~/.hermes/gateway.log                │"
    echo "  │  Monitor: tail -f ~/.hermes/gateway.log     │"
    echo "  └─────────────────────────────────────────────┘"
else
    fail "Gateway failed!"
    tail -10 "$HERMES_HOME/gateway.log" 2>/dev/null || true
    exit 1
fi

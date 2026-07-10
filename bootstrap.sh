#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# vast-hermes-bootstrap.sh
# Vast.ai instance'ında komple bootstrap:
#   gh CLI + auth  →  Hermes kurulum  →  Gateway açılışı
#
# KULLANIM:
#
#   export GITHUB_TOKEN="ghp_..."
#   export OPENCODE_GO_API_KEY="sk-..."
#   export TELEGRAM_BOT_TOKEN="..."
#   bash scripts/vast-hermes-bootstrap.sh
#
#   VEYA Vast.ai On-Start: environment variable'ları gir, script'i yapıştır
# ============================================================

# === CONFIG (env override) ===
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
HERMES_PROVIDER="${HERMES_PROVIDER:-opencode-go}"
HERMES_MODEL="${HERMES_MODEL:-deepseek-v4-flash}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

# Required
: "${OPENCODE_GO_API_KEY:?OPENCODE_GO_API_KEY not set}"

# Optional gateway
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"

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
# 2. GH CLI kurulum + auth
# ============================================================
log "GitHub CLI setup..."
if ! command -v gh &>/dev/null; then
    log "Installing gh CLI..."
    # Official GitHub install method (Linux)
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
        sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
        sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo -S -p '' apt-get update -qq && sudo -S -p '' apt-get install -y -qq gh 2>/dev/null || {
        # Fallback: direct download
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
    log "GITHUB_TOKEN not set — skipping gh auth (manual: gh auth login)"
fi

# ============================================================
# 3. HERMES KURULUMU
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

HERMES_VER=$(hermes --version 2>/dev/null || echo "installed")
ok "Hermes $HERMES_VER"

# ============================================================
# 4. CREDENTIALS (.env)
# ============================================================
log "Configuring credentials..."
mkdir -p "$HERMES_HOME"

cat > "$HERMES_HOME/.env" << EOF
OPENCODE_GO_API_KEY=${OPENCODE_GO_API_KEY}
EOF

if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}" >> "$HERMES_HOME/.env"
fi
if [ -n "$DISCORD_BOT_TOKEN" ]; then
    echo "DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}" >> "$HERMES_HOME/.env"
fi
if [ -n "$GITHUB_TOKEN" ]; then
    echo "GITHUB_TOKEN=${GITHUB_TOKEN}" >> "$HERMES_HOME/.env"
fi
chmod 600 "$HERMES_HOME/.env"
ok ".env created ($(wc -l < "$HERMES_HOME/.env") entries)"

# ============================================================
# 5. CONFIGURE HERMES
# ============================================================
log "Configuring model & provider..."
hermes config set model.provider "$HERMES_PROVIDER" 2>/dev/null || true
hermes config set model.default "$HERMES_MODEL" 2>/dev/null || true

if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    hermes config set gateway.platforms.telegram.enabled true 2>/dev/null || true
    ok "Telegram gateway enabled"
fi
if [ -n "$DISCORD_BOT_TOKEN" ]; then
    hermes config set gateway.platforms.discord.enabled true 2>/dev/null || true
    ok "Discord gateway enabled"
fi

ok "Provider=$HERMES_PROVIDER  Model=$HERMES_MODEL"

# ============================================================
# 6. SANITY CHECK
# ============================================================
log "Sanity check..."
hermes doctor --fix 2>/dev/null | tail -3 || true

# ============================================================
# 7. GATEWAY START
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

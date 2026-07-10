#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# vast-hermes-bootstrap.sh
# Vast.ai instance'ında Hermes Agent kurulumu + Gateway açılışı
#
# KULLANIM:
#
#   SSH ile Vast.ai instance'ına bağlan, API key'leri export et:
#
#     export OPENCODE_GO_API_KEY="sk-..."
#     export TELEGRAM_BOT_TOKEN="..."
#     bash scripts/vast-hermes-bootstrap.sh
#
#   TEK SATIR (gist'ten indir):
#
#     bash <(curl -fsSL https://raw.githubusercontent.com/ddawnlll/vast-hermes-bootstrap/main/bootstrap.sh)
#
#   VAST.AI ON-START SCRIPT:
#     - Template > On-Start > bu scripti yapıştır
#     - Environment Variables kısmına OPENCODE_GO_API_KEY etc.
# ============================================================

HERMES_PROVIDER="${HERMES_PROVIDER:-opencode-go}"
HERMES_MODEL="${HERMES_MODEL:-deepseek-v4-flash}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

# Required
: "${OPENCODE_GO_API_KEY:?OPENCODE_GO_API_KEY not set}"

# Optional
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"

log()  { echo -e "[\e[34m*\e[0m] $*"; }
ok()   { echo -e "[\e[32m\xe2\x9c\x93\e[0m] $*"; }
fail() { echo -e "[\e[31m!\e[0m] $*"; }

# ---- 0. PATH fix ----
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:$PATH"

# ---- 1. System deps ----
log "System dependencies..."
sudo -S -p '' apt-get update -qq 2>/dev/null && sudo -S -p '' apt-get install -y -qq curl git jq 2>/dev/null || true

# ---- 2. Install Hermes ----
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

# ---- 3. Setup .env ----
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
chmod 600 "$HERMES_HOME/.env"
ok ".env created ($(wc -l < "$HERMES_HOME/.env") entries)"

# ---- 4. Configure Hermes ----
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

# ---- 5. Quick sanity ----
log "Sanity check..."
hermes doctor --fix 2>/dev/null | tail -3 || true

# ---- 6. Start Gateway ----
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
    echo "  │  Hermes Gateway is live!                    │"
    echo "  │  PID: $GATEWAY_PID                          │"
    echo "  │  Logs: ~/.hermes/gateway.log                │"
    echo "  │  Monitor: tail -f ~/.hermes/gateway.log     │"
    echo "  └─────────────────────────────────────────────┘"
else
    fail "Gateway failed to start!"
    tail -10 "$HERMES_HOME/gateway.log" 2>/dev/null || true
    exit 1
fi

#!/usr/bin/env bash
# AgroLedger AI helper on a rented Linux server (Ubuntu/Debian), using YOUR OWN Claude login.
# It runs all the time and restarts by itself. Other accounts can use it only after you allow them
# in Telegram (approve only your own accounts: it uses your personal Claude subscription).
#
#   curl -fsSL https://agroledger-app.github.io/helper/server-setup.sh -o setup.sh && sudo bash setup.sh
#
# You need the token from "claude setup-token" (run it on your own computer). It is asked for
# once, hidden, and kept only on this server in /etc/agroledger/token.env (readable by root only).
# Run the same command again any time to update or to see the link again.
set -euo pipefail

APP=https://agroledger-app.github.io
HOME_DIR=/home/agroledger
step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }

[ "$(id -u)" = 0 ] || { echo "Please run with sudo:  sudo bash setup.sh"; exit 1; }
command -v apt-get >/dev/null || { echo "This script needs Ubuntu or Debian."; exit 1; }

step "Installing what the helper needs (a few minutes the first time)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq curl ca-certificates >/dev/null
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
if ! command -v cloudflared >/dev/null; then
  arch=$(dpkg --print-architecture)
  curl -fsSL -o /tmp/cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
  dpkg -i /tmp/cloudflared.deb >/dev/null
  rm -f /tmp/cloudflared.deb
fi
npm install -g --silent @anthropic-ai/claude-code >/dev/null
echo "Node $(node -v) · $(claude --version) · $(cloudflared --version 2>&1 | head -1)"

step "Preparing the helper"
id agroledger >/dev/null 2>&1 || useradd -m -s /bin/bash agroledger
install -d -o agroledger -g agroledger -m 700 "$HOME_DIR/app"
curl -fsSL "$APP/helper/agroledger-helper.mjs" -o "$HOME_DIR/app/agroledger-helper.mjs"
chown agroledger:agroledger "$HOME_DIR/app/agroledger-helper.mjs"

if [ ! -s /etc/agroledger/token.env ]; then
  step "Your Claude token"
  echo "On your own computer run:  claude setup-token"
  echo "Approve in the browser, copy the token it prints, and paste it here (it stays hidden)."
  TOKEN=""
  while [ -z "$TOKEN" ]; do read -rsp "Token: " TOKEN </dev/tty; echo; done
  install -d -m 700 /etc/agroledger
  umask 077
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nDISABLE_AUTOUPDATER=1\n' "$TOKEN" > /etc/agroledger/token.env
  chmod 600 /etc/agroledger/token.env
  unset TOKEN
fi

step "Starting it as a service (it starts again after a restart)"
cat > /etc/systemd/system/agroledger-helper.service <<EOF
[Unit]
Description=AgroLedger AI helper
After=network-online.target
Wants=network-online.target

[Service]
User=agroledger
WorkingDirectory=$HOME_DIR/app
EnvironmentFile=/etc/agroledger/token.env
ExecStart=/usr/bin/env node $HOME_DIR/app/agroledger-helper.mjs
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
# Claude Code itself is updated once a week
cat > /etc/cron.weekly/agroledger-claude-update <<'EOF'
#!/bin/sh
npm install -g --silent @anthropic-ai/claude-code >/dev/null 2>&1 && systemctl restart agroledger-helper
EOF
chmod 755 /etc/cron.weekly/agroledger-claude-update
systemctl daemon-reload
systemctl enable agroledger-helper >/dev/null 2>&1
systemctl restart agroledger-helper

step "Waiting for the secure address (up to 2 minutes)"
LINK=""
for _ in $(seq 1 60); do
  LINK=$(journalctl -u agroledger-helper -n 400 --no-pager 2>/dev/null | grep -o "$APP/#/connect/[A-Za-z0-9_-]*" | tail -1 || true)
  [ -n "$LINK" ] && break
  sleep 2
done
if [ -n "$LINK" ]; then
  printf '\n\033[1m✅ Ready.\033[0m Open this link once on each of your devices (keep it private):\n\n  %s\n\n' "$LINK"
  echo "Your devices find the new address by themselves after the server restarts."
else
  echo "Not ready yet. See what the helper says with:  journalctl -u agroledger-helper -n 50 --no-pager"
fi

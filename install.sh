#!/usr/bin/env bash
set -euo pipefail

TOKEN=""
API_BASE=""
INSTALL_DIR="/opt/dashboard-agent"
SERVICE_NAME="dashboard-agent"

usage() {
  echo "Usage: $0 --token=TOKEN --api=API_BASE_URL"
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --token=*) TOKEN="${arg#*=}" ;;
    --api=*) API_BASE="${arg#*=}" ;;
    *) usage ;;
  esac
done

if [[ -z "$TOKEN" || -z "$API_BASE" ]]; then
  usage
fi

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

API_BASE="${API_BASE%/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/agent.sh" "$INSTALL_DIR/agent.sh"
chmod +x "$INSTALL_DIR/agent.sh"

cat > "$INSTALL_DIR/config.env" <<EOF
DASHBOARD_AGENT_TOKEN=$TOKEN
DASHBOARD_API_BASE=$API_BASE
DASHBOARD_INTERVAL=30
EOF
chmod 600 "$INSTALL_DIR/config.env"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Dashboard Server Monitoring Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$INSTALL_DIR/config.env
ExecStart=$INSTALL_DIR/agent.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "Dashboard agent installed and started."
systemctl status "$SERVICE_NAME" --no-pager || true

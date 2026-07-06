#!/usr/bin/env bash
set -euo pipefail

TOKEN=""
INSTALL_DIR="/opt/dashboard-agent"
SERVICE_NAME="dashboard-agent"
API_BASE=""

for arg in "$@"; do
  case "$arg" in
    --token=*) TOKEN="${arg#*=}" ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

if [[ -f "$INSTALL_DIR/config.env" ]]; then
  # shellcheck disable=SC1091
  source "$INSTALL_DIR/config.env"
  API_BASE="${DASHBOARD_API_BASE:-}"
  if [[ -z "$TOKEN" ]]; then
    TOKEN="${DASHBOARD_AGENT_TOKEN:-}"
  fi
fi

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
  systemctl stop "$SERVICE_NAME"
fi
if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
  systemctl disable "$SERVICE_NAME"
fi

rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
rm -rf "$INSTALL_DIR"

if [[ -n "$TOKEN" && -n "$API_BASE" ]]; then
  curl -fsS -X POST "${API_BASE%/}/api/agents/heartbeat" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"hostname":"uninstalled"}' >/dev/null 2>&1 || true
fi

echo "Dashboard agent removed."

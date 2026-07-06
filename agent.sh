#!/usr/bin/env bash
set -euo pipefail

: "${DASHBOARD_AGENT_TOKEN:?Missing DASHBOARD_AGENT_TOKEN}"
: "${DASHBOARD_API_BASE:?Missing DASHBOARD_API_BASE}"
INTERVAL="${DASHBOARD_INTERVAL:-30}"

API_BASE="${DASHBOARD_API_BASE%/}"
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

read_cpu_percent() {
  local idle1 total1 idle2 total2
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  idle1=$((idle + iowait))
  total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
  sleep 1
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  idle2=$((idle + iowait))
  total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
  local total_diff idle_diff
  total_diff=$((total2 - total1))
  idle_diff=$((idle2 - idle1))
  if [[ $total_diff -le 0 ]]; then
    echo "0"
    return
  fi
  awk -v t="$total_diff" -v i="$idle_diff" 'BEGIN { printf "%.2f", (1 - i / t) * 100 }'
}

read_mem_mb() {
  local total avail
  total=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  avail=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
  local used=$((total - avail))
  echo "$used $total"
}

read_disk_percent() {
  df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

read_load_avg() {
  awk '{print $1}' /proc/loadavg
}

post_metrics() {
  local cpu used total disk load
  cpu="$(read_cpu_percent)"
  read -r used total < <(read_mem_mb)
  disk="$(read_disk_percent)"
  load="$(read_load_avg)"

  curl -fsS -X POST "${API_BASE}/api/agents/metrics" \
    -H "Authorization: Bearer ${DASHBOARD_AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"cpuPercent\":${cpu},\"memUsedMb\":${used},\"memTotalMb\":${total},\"diskUsedPercent\":${disk},\"loadAvg\":${load},\"hostname\":\"${HOSTNAME}\"}" \
    >/dev/null
}

post_heartbeat() {
  curl -fsS -X POST "${API_BASE}/api/agents/heartbeat" \
    -H "Authorization: Bearer ${DASHBOARD_AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"hostname\":\"${HOSTNAME}\"}" \
    >/dev/null
}

while true; do
  if post_metrics; then
    :
  else
    post_heartbeat || true
  fi
  sleep "$INTERVAL"
done

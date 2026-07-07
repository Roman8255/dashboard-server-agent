#!/usr/bin/env bash
set -euo pipefail

: "${DASHBOARD_AGENT_TOKEN:?Missing DASHBOARD_AGENT_TOKEN}"
: "${DASHBOARD_API_BASE:?Missing DASHBOARD_API_BASE}"
INTERVAL="${DASHBOARD_INTERVAL:-30}"
SAMPLE_COUNT="${DASHBOARD_SAMPLE_COUNT:-6}"
SAMPLE_GAP="${DASHBOARD_SAMPLE_GAP:-5}"

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

avg_max() {
  awk '{
    for (i = 1; i <= NF; i++) {
      sum += $i
      if (i == 1 || $i > max) max = $i
    }
    if (NF == 0) {
      print "0 0"
      exit
    }
    printf "%.2f %.2f\n", sum / NF, max
  }'
}

collect_window_metrics() {
  local -a cpu_samples=()
  local -a mem_used_samples=()
  local -a mem_pct_samples=()
  local -a disk_samples=()
  local -a load_samples=()
  local cpu used total mem_pct disk load
  local mem_total_mb=0

  for ((i = 1; i <= SAMPLE_COUNT; i++)); do
    cpu="$(read_cpu_percent)"
    cpu_samples+=("$cpu")

    read -r used total < <(read_mem_mb)
    mem_used_samples+=("$used")
    mem_total_mb="$total"
    mem_pct="$(awk -v u="$used" -v t="$total" 'BEGIN { if (t > 0) printf "%.2f", u / t * 100; else print "0" }')"
    mem_pct_samples+=("$mem_pct")

    disk="$(read_disk_percent)"
    disk_samples+=("$disk")

    load="$(read_load_avg)"
    load_samples+=("$load")

    if [[ $i -lt $SAMPLE_COUNT ]]; then
      sleep "$SAMPLE_GAP"
    fi
  done

  read -r cpu_avg cpu_max < <(avg_max "${cpu_samples[@]}")
  read -r mem_used_avg _ < <(avg_max "${mem_used_samples[@]}")
  read -r _ mem_pct_max < <(avg_max "${mem_pct_samples[@]}")
  read -r disk_avg disk_max < <(avg_max "${disk_samples[@]}")
  read -r load_avg load_max < <(avg_max "${load_samples[@]}")

  CPU_AVG="$cpu_avg"
  CPU_MAX="$cpu_max"
  MEM_USED_AVG="$mem_used_avg"
  MEM_TOTAL_MB="$mem_total_mb"
  MEM_PCT_MAX="$mem_pct_max"
  DISK_AVG="$disk_avg"
  DISK_MAX="$disk_max"
  LOAD_AVG="$load_avg"
  LOAD_MAX="$load_max"
}

post_metrics() {
  collect_window_metrics

  curl -fsS -X POST "${API_BASE}/api/agents/metrics" \
    -H "Authorization: Bearer ${DASHBOARD_AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"cpuPercent\":${CPU_AVG},\"cpuPercentMax\":${CPU_MAX},\"memUsedMb\":${MEM_USED_AVG},\"memTotalMb\":${MEM_TOTAL_MB},\"memUsedPercentMax\":${MEM_PCT_MAX},\"diskUsedPercent\":${DISK_AVG},\"diskUsedPercentMax\":${DISK_MAX},\"loadAvg\":${LOAD_AVG},\"loadAvgMax\":${LOAD_MAX},\"hostname\":\"${HOSTNAME}\"}" \
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
    sleep "$INTERVAL"
  fi
done

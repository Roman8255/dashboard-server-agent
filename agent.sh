#!/usr/bin/env bash
set -euo pipefail

: "${DASHBOARD_AGENT_TOKEN:?Missing DASHBOARD_AGENT_TOKEN}"
: "${DASHBOARD_API_BASE:?Missing DASHBOARD_API_BASE}"
INTERVAL="${DASHBOARD_INTERVAL:-30}"
SAMPLE_COUNT="${DASHBOARD_SAMPLE_COUNT:-6}"
SAMPLE_GAP="${DASHBOARD_SAMPLE_GAP:-5}"

API_BASE="${DASHBOARD_API_BASE%/}"
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"

if [[ ! -r /proc/stat ]]; then
  echo "dashboard-agent requires Linux (/proc/stat not found)" >&2
  exit 1
fi

read_cpu_stats() {
  awk '/^cpu / {
    idle = $5 + $6
    total = 0
    for (i = 2; i <= NF; i++) total += $i
    print idle, total
  }' /proc/stat
}

read_cpu_percent() {
  local idle1 total1 idle2 total2
  read -r idle1 total1 < <(read_cpu_stats)
  sleep 1
  read -r idle2 total2 < <(read_cpu_stats)
  if [[ "$total2" -le "$total1" ]]; then
    echo "0"
    return
  fi
  awk -v t1="$total1" -v i1="$idle1" -v t2="$total2" -v i2="$idle2" \
    'BEGIN { total = t2 - t1; idle = i2 - i1; if (total <= 0) print 0; else printf "%.2f", (1 - idle / total) * 100 }'
}

read_mem_mb() {
  local total avail
  total=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  avail=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
  if [[ -z "$avail" ]]; then
    avail=$(awk '/MemFree:/ {print int($2/1024)}' /proc/meminfo)
  fi
  local used=$((total - avail))
  echo "$used $total"
}

read_disk_percent() {
  df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5; exit}'
}

read_load_avg() {
  awk '{print $1}' /proc/loadavg
}

read_cpu_temp_celsius() {
  local temp=""

  if command -v vcgencmd >/dev/null 2>&1; then
    temp="$(vcgencmd measure_temp 2>/dev/null | sed -n "s/temp=\\([0-9.]*\\).*/\\1/p")"
    if [[ -n "$temp" ]]; then
      echo "$temp"
      return
    fi
  fi

  local zone
  for zone in /sys/class/thermal/thermal_zone*/temp /sys/devices/virtual/thermal/thermal_zone*/temp; do
    [[ -r "$zone" ]] || continue
    local raw
    raw="$(tr -d '[:space:]' <"$zone" 2>/dev/null || true)"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      awk -v r="$raw" 'BEGIN { printf "%.1f", r / 1000 }'
      return
    fi
  done

  local sensor
  for sensor in /sys/class/hwmon/hwmon*/temp1_input; do
    [[ -r "$sensor" ]] || continue
    raw="$(tr -d '[:space:]' <"$sensor" 2>/dev/null || true)"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      awk -v r="$raw" 'BEGIN { printf "%.1f", r / 1000 }'
      return
    fi
  done
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
  local -a temp_samples=()
  local cpu used total mem_pct disk load temp
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
    disk_samples+=("${disk:-0}")

    load="$(read_load_avg)"
    load_samples+=("${load:-0}")

    temp="$(read_cpu_temp_celsius || true)"
    if [[ -n "$temp" ]]; then
      temp_samples+=("$temp")
    fi

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
  CPU_TEMP_AVG=""
  CPU_TEMP_MAX=""

  if [[ ${#temp_samples[@]} -gt 0 ]]; then
    read -r CPU_TEMP_AVG CPU_TEMP_MAX < <(avg_max "${temp_samples[@]}")
  fi
}

post_metrics() {
  collect_window_metrics

  local temp_json=""
  if [[ -n "${CPU_TEMP_AVG}" ]]; then
    temp_json=",\"cpuTempC\":${CPU_TEMP_AVG},\"cpuTempCMax\":${CPU_TEMP_MAX}"
  fi

  curl -fsS -X POST "${API_BASE}/api/agents/metrics" \
    -H "Authorization: Bearer ${DASHBOARD_AGENT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"cpuPercent\":${CPU_AVG},\"cpuPercentMax\":${CPU_MAX},\"memUsedMb\":${MEM_USED_AVG},\"memTotalMb\":${MEM_TOTAL_MB},\"memUsedPercentMax\":${MEM_PCT_MAX},\"diskUsedPercent\":${DISK_AVG},\"diskUsedPercentMax\":${DISK_MAX},\"loadAvg\":${LOAD_AVG},\"loadAvgMax\":${LOAD_MAX}${temp_json},\"hostname\":\"${HOSTNAME}\"}" \
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
    sleep "$INTERVAL"
  else
    post_heartbeat || true
    sleep "$INTERVAL"
  fi
done

# dashboard-server-agent

Linux background agent for the Dashboard iOS app. Collects CPU, RAM, disk, and load metrics and sends them to your portfolio backend.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/romanbednarik/dashboard-server-agent/main/install.sh \
  | sudo bash -s -- --token=YOUR_AGENT_TOKEN --api=https://romanbednarik.sk
```

Get `YOUR_AGENT_TOKEN` from the Dashboard app when adding a new server.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/romanbednarik/dashboard-server-agent/main/uninstall.sh \
  | sudo bash -s -- --token=YOUR_AGENT_TOKEN
```

## Requirements

- Linux with systemd
- `curl`, `awk`, `df`
- Outbound HTTPS to your API host

## Files

- `install.sh` — installs to `/opt/dashboard-agent` and enables systemd service
- `uninstall.sh` — stops and removes the agent
- `agent.sh` — metrics loop (30s default)
- `dashboard-agent.service` — systemd unit template

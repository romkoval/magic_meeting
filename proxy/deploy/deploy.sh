#!/usr/bin/env bash
# Build for linux/amd64 and install on the VPS. Usage: ./deploy/deploy.sh user@host
set -euo pipefail
host="${1:?usage: deploy.sh user@host}"
cd "$(dirname "$0")/.."
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o build/proxy .
scp build/proxy deploy/magic-meeting-proxy.service "$host:/tmp/"
ssh "$host" 'set -e
  sudo id magicmeeting >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin magicmeeting
  sudo install -d -m 755 /opt/magic-meeting /etc/magic-meeting
  sudo install -m 755 /tmp/proxy /opt/magic-meeting/proxy
  sudo install -m 644 /tmp/magic-meeting-proxy.service /etc/systemd/system/
  test -f /etc/magic-meeting/proxy.env || echo "WARNING: create /etc/magic-meeting/proxy.env first"
  sudo systemctl daemon-reload
  sudo systemctl enable --now magic-meeting-proxy
  sudo systemctl restart magic-meeting-proxy
  sleep 1 && curl -fsS http://127.0.0.1:8080/healthz'

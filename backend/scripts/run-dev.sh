#!/usr/bin/env bash
# Runs the API over HTTPS on port 8443, reachable from phones on the same
# Wi-Fi. Set TRUSTPUNCH_DEBUG=1 to turn on the /docs page.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f certs/server.pem ]; then
  echo "No certificate yet. Run: scripts/make-dev-cert.sh" >&2
  exit 1
fi

# A fresh one-time code, so a phone can pair right away (valid 10 minutes;
# get another with: .venv/bin/python -m app.cli pair-code).
.venv/bin/python -m app.cli pair-code

# 0.0.0.0 = listen on every network interface, not just this Mac, so phones
# on the Wi-Fi can connect. Only do this on a network you trust.
# --no-access-log: uvicorn's own log prints full URLs (worker ids, query
# strings); the app writes its own JSON access log with route templates only.
exec .venv/bin/uvicorn app.main:app \
  --host 0.0.0.0 --port 8443 --no-access-log \
  --ssl-keyfile certs/server-key.pem \
  --ssl-certfile certs/server.pem

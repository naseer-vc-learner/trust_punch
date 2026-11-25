#!/usr/bin/env bash
# Run TrustPunch on a physical device (iOS or Android) against local emulators.
#
#   ./scripts/run-device.sh              # first available device
#   ./scripts/run-device.sh <device-id>  # a specific one (flutter devices)
#
# Exists because the two --dart-define flags are easy to forget, and forgetting
# them is silent: the app starts, then fails at sign-in with "API key not valid"
# because it tried to reach the real Firebase with placeholder credentials.
set -euo pipefail

cd "$(dirname "$0")/.."

# Resolved every run, not hardcoded: your LAN address changes with the network,
# and a stale IP fails in exactly the same confusing way as a missing one.
HOST="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [[ -z "$HOST" ]]; then
  echo "Could not determine a LAN IP. Is Wi-Fi connected?" >&2
  exit 1
fi

if ! curl -sf -m 5 -o /dev/null "http://${HOST}:4000/"; then
  cat >&2 <<MSG
Emulators are not reachable at ${HOST}:4000

Start them in another terminal:
  ./scripts/emulators.sh
  node scripts/seed-emulator.js
MSG
  exit 1
fi

echo "Mac LAN IP : ${HOST}"
echo "Backend    : local emulators (no cloud, no billing)"
echo "Login      : employee1@test.local / Test123!"
echo
echo "The phone must be on this same network to reach ${HOST}."
echo

DEVICE_ARG=()
if [[ $# -ge 1 ]]; then
  DEVICE_ARG=(-d "$1")
  echo "Device     : $1"
fi

exec flutter run \
  "${DEVICE_ARG[@]}" \
  --device-timeout 30 \
  --dart-define=USE_EMULATOR=true \
  --dart-define=EMULATOR_HOST="$HOST"

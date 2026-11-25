#!/usr/bin/env bash
# Start the full local stack. No Firebase project, no login, no billing.
#
# The `demo-` project prefix is what guarantees that: the Firebase tooling
# treats it as a project that does not exist and refuses to reach any real
# service, so there is no path by which this run can incur a charge.
set -euo pipefail

cd "$(dirname "$0")/.."

# Record the address the emulators will be reachable at, so a flagless
# `flutter run` (or the IDE Run button) still finds them. Without this the app
# would have to be told the IP on every launch.
HOST="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '')"
cat > lib/src/core/emulator_host.g.dart <<EOF
// GENERATED — do not edit by hand.
//
// Rewritten by scripts/emulators.sh on every start, with the LAN address the
// emulator suite is actually listening on.
//
// This exists so a plain \`flutter run\` (or the IDE's Run button, which passes
// no --dart-define) still finds the backend. Without it, the host would only
// be knowable from a command-line flag that is easy to forget.
const String generatedEmulatorHost = '${HOST}';
EOF
echo "Emulator host recorded: ${HOST:-<none, will use simulator defaults>}"

echo "Building functions..."
npm --prefix functions run build

echo
echo "Starting emulators (Ctrl-C to stop)."
echo "  Emulator UI   http://localhost:4000"
echo "  Seed data     node scripts/seed-emulator.js   (in another terminal)"
echo "  Run the app   flutter run --dart-define=USE_EMULATOR=true"
echo

# --import/--export-on-exit persists data between runs, so enrolled test users
# and their face templates survive a restart instead of needing a re-seed.
exec firebase emulators:start \
  --project demo-trustpunch \
  --import=./.emulator-data \
  --export-on-exit=./.emulator-data

#!/usr/bin/env bash
# The offline demo app ("Trust Punch", lib/main.dart) must never reach the
# connected code (lib/src/connected/), which is the only code that talks to
# a server. Only lib/main_connected.dart and the connected code itself may
# import it. CI runs this on every push; run it locally before committing.
set -euo pipefail
cd "$(dirname "$0")/.."

pattern="^[[:space:]]*(import|export|part)[[:space:]]+['\"]([^'\"]*/)?(src/)?connected/"

offenders=$(grep -rlE "$pattern" lib --include='*.dart' \
  | grep -vE '^lib/main_connected\.dart$|^lib/src/connected/' || true)

if grep -qE "^[[:space:]]*(import|export|part)[[:space:]]+['\"][^'\"]*main_connected\.dart" lib/main.dart; then
  offenders="$offenders lib/main.dart"
fi

if [ -n "${offenders// /}" ]; then
  echo "The demo app must not import the connected code. Offending files:" >&2
  for f in $offenders; do echo "  $f" >&2; done
  exit 1
fi
echo "Demo isolation OK: only lib/main_connected.dart and lib/src/connected/ use the connected code."

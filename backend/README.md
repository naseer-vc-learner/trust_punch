# TrustPunch local server

A FastAPI service on your Mac that the **TrustPunch Connected** app sends
punches to. The offline demo app ("Trust Punch") never talks to it.

The phone stays where attendance happens: face match, liveness and GPS all
run on the phone, which keeps working with no server at all. The server
keeps its own copy, stores each punch exactly once, and re-checks what the
phone claims.

## One-time setup

```bash
cd backend
/opt/homebrew/bin/python3.14 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest -q                      # all tests should pass
scripts/make-dev-cert.sh                 # HTTPS certificate for this Mac
```

Run `make-dev-cert.sh` again whenever the Mac's Wi-Fi address changes. It
keeps the same private CA, so the app's trust setting stays valid.
`certs/` holds private keys and is never committed.

## Run the server

```bash
scripts/run-dev.sh
```

It prints a **6-digit pairing code** first, then listens on
`https://<mac-ip>:8443` on your Wi-Fi. Only run it on a network you trust.

## Run the connected app on the iPhone

From the project root, with the server running:

```bash
flutter run -d 00008101-00042D461105001E --flavor connected \
  -t lib/main_connected.dart \
  --dart-define=API_BASE_URL=https://$(ipconfig getifaddr en0):8443 \
  --dart-define=API_DEV_CA=$(base64 -i backend/certs/dev-ca.pem)
```

On the role picker, tap the **Server** line, then **Pair with server**, and
enter the code. Punches made from then on (and any made before) upload on
their own, within a few seconds when online and every minute otherwise.

The first time, iOS asks to allow **Local Network** access: allow it, or
the phone cannot reach the Mac.

## Operator commands

```bash
.venv/bin/python -m app.cli pair-code          # another code (one phone each)
.venv/bin/python -m app.cli devices            # paired phones
.venv/bin/python -m app.cli block <device-id>  # stop a lost phone uploading
.venv/bin/python -m app.cli unblock <device-id>
.venv/bin/python -m app.cli report --day 2026-11-27
```

The report lists each punch with the server's findings.

## What the server checks

| Flag | Meaning |
|---|---|
| `clock_skew` | The phone's clock was more than 2 minutes off the server's when it sent |
| `future_time` | The punch is dated later than the server's current time |
| `far_from_site` | The GPS fix is outside the location's 50 m circle |
| `distance_mismatch` | The distance the phone reported isn't the real distance |
| `site_moved` | A location turned up with coordinates other than first seen |
| `out_of_order` | The day breaks in → (break) → out, e.g. checked in on two phones |

These are flags for a supervisor, not refusals: an honest punch is never
lost because a phone's clock drifted. Automatic and corrected punches skip
the location checks. A correction names the punch it replaces, and the
server sets that one aside.

## Security in this step

- **HTTPS only.** The app trusts only this Mac's development CA when you
  build it with one.
- **Pairing codes** work once, for 10 minutes. Five wrong guesses close
  every open code, and one address gets 5 wrong guesses per 10 minutes.
- **Device tokens** are stored as SHA-256 only. On the phone, the token is
  kept in the Keychain or Keystore, not in the app's files.
- **Input checks:** every field is checked, unknown fields are refused, a
  batch is at most 500 punches, and a request at most 2 MB.
- **No docs page** unless `TRUSTPUNCH_DEBUG=1`. The access log shows paths,
  never attendance data.
- **Server data:** the database is `data/trustpunch.db` (move it with
  `TRUSTPUNCH_DB`). It is not encrypted and not committed.

## Not yet

- **Supervisor login:** reading attendance on the server is CLI-only until
  then.
- **Server-owned projects, locations and workers**, which phones would
  download.
- **Several gate phones sharing one roster.**
- **PostgreSQL** for a real deployment.

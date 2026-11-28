"""Operator commands, run on the server's own machine.

    .venv/bin/python -m app.cli pair-code          # a code to pair one phone
    .venv/bin/python -m app.cli devices            # paired phones
    .venv/bin/python -m app.cli block <device-id>  # stop a phone uploading
    .venv/bin/python -m app.cli unblock <device-id>
    .venv/bin/python -m app.cli report [--day YYYY-MM-DD]

There is deliberately no web page for these yet: reading attendance needs a
supervisor login, which is the next step.
"""

import argparse
import sys
from datetime import date, datetime, timedelta

from .db import connect
from .security import CODE_LIFETIME, new_pair_code


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="app.cli")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("pair-code")
    sub.add_parser("devices")
    for name in ("block", "unblock"):
        sub.add_parser(name).add_argument("device_id")
    report = sub.add_parser("report")
    report.add_argument("--day", default=date.today().isoformat())
    args = parser.parse_args(argv)

    conn = connect()
    try:
        if args.command == "pair-code":
            code = new_pair_code(conn)
            minutes = int(CODE_LIFETIME.total_seconds() // 60)
            print(f"Pairing code: {code}  (works once, for {minutes} minutes)")
        elif args.command == "devices":
            rows = conn.execute(
                "SELECT id, name, platform, created_at, last_seen_at, blocked"
                " FROM devices ORDER BY created_at"
            ).fetchall()
            if not rows:
                print("No phones paired yet.")
            for r in rows:
                state = "BLOCKED" if r["blocked"] else "ok"
                print(f"{r['id']}  {r['name']} ({r['platform']})  {state}"
                      f"  last seen {r['last_seen_at'] or 'never'}")
        elif args.command in ("block", "unblock"):
            changed = conn.execute(
                "UPDATE devices SET blocked = ? WHERE id = ?",
                (1 if args.command == "block" else 0, args.device_id),
            ).rowcount
            print(f"{args.command}ed" if changed else "No such device")
            return 0 if changed else 1
        elif args.command == "report":
            rows = conn.execute(
                "SELECT worker_name, employee_id, site_name, type, at_utc,"
                " offset_minutes, auto, corrected, superseded_by, flags"
                " FROM punches WHERE local_day = ? ORDER BY worker_name, at_utc",
                (args.day,),
            ).fetchall()
            if not rows:
                print(f"No punches for {args.day}.")
            for r in rows:
                notes = [n for n in (
                    "auto" if r["auto"] else "",
                    "corrected" if r["corrected"] else "",
                    "replaced" if r["superseded_by"] else "",
                    r["flags"],
                ) if n]
                # The phone's local time, as the worker saw it.
                local = datetime.fromisoformat(r["at_utc"]) + timedelta(
                    minutes=r["offset_minutes"])
                print(f"{r['worker_name']:<20} {r['employee_id']:<8} {r['type']:<10}"
                      f" {local:%H:%M}  {r['site_name']:<20} {' '.join(notes)}")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

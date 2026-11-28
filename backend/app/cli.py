"""Operator commands, run on the server's own machine.

    .venv/bin/python -m app.cli pair-code          # a code to pair one phone
    .venv/bin/python -m app.cli devices            # paired phones
    .venv/bin/python -m app.cli block <device-id>  # stop a phone uploading
    .venv/bin/python -m app.cli unblock <device-id>
    .venv/bin/python -m app.cli report [--day YYYY-MM-DD]
    .venv/bin/python -m app.cli migrate            # bring the database up to date

Every command first brings the database up to date. Reading attendance
needs a supervisor login (plan, Days 3-4); until then it is CLI-only.
"""

import argparse
import sys
from datetime import date, datetime, timedelta

from app.core.db import connect, migrate
from app.modules.attendance import service as attendance
from app.modules.devices import service as devices


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="app.cli")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("pair-code")
    sub.add_parser("devices")
    sub.add_parser("migrate")
    for name in ("block", "unblock"):
        sub.add_parser(name).add_argument("device_id")
    report = sub.add_parser("report")
    report.add_argument("--day", default=date.today().isoformat())
    args = parser.parse_args(argv)

    migrate()
    if args.command == "migrate":
        print("Database is up to date.")
        return 0

    conn = connect()
    try:
        if args.command == "pair-code":
            code = devices.new_pair_code(conn)
            minutes = int(devices.CODE_LIFETIME.total_seconds() // 60)
            print(f"Pairing code: {code}  (works once, for {minutes} minutes)")
        elif args.command == "devices":
            rows = devices.list_devices(conn)
            if not rows:
                print("No phones paired yet.")
            for r in rows:
                state = "BLOCKED" if r["blocked"] else "ok"
                print(
                    f"{r['id']}  {r['name']} ({r['platform']})  {state}"
                    f"  last seen {r['last_seen_at'] or 'never'}"
                )
        elif args.command in ("block", "unblock"):
            changed = devices.set_blocked(conn, args.device_id, args.command == "block")
            print(f"{args.command}ed" if changed else "No such device")
            return 0 if changed else 1
        elif args.command == "report":
            rows = attendance.report_day(conn, args.day)
            if not rows:
                print(f"No punches for {args.day}.")
            for r in rows:
                notes = [
                    n
                    for n in (
                        "auto" if r["auto"] else "",
                        "corrected" if r["corrected"] else "",
                        "replaced" if r["superseded_by"] else "",
                        r["flags"],
                    )
                    if n
                ]
                # The phone's local time, as the worker saw it.
                local = datetime.fromisoformat(r["at_utc"]) + timedelta(minutes=r["offset_minutes"])
                # The operator's own terminal is this report's purpose.
                print(
                    f"{r['worker_name']:<20} {r['employee_id']:<8} {r['type']:<10}"
                    f" {local:%H:%M}  {r['site_name']:<20} {' '.join(notes)}"
                )
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

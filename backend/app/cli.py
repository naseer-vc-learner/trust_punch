"""Operator commands, run on the server's own machine.

    .venv/bin/python -m app.cli pair-code          # a code to pair one phone
    .venv/bin/python -m app.cli devices            # paired phones
    .venv/bin/python -m app.cli block <device-id>  # stop a phone uploading
    .venv/bin/python -m app.cli unblock <device-id>
    .venv/bin/python -m app.cli report [--day YYYY-MM-DD]
    .venv/bin/python -m app.cli migrate            # bring the database up to date
    .venv/bin/python -m app.cli create-admin --username <name> [--display-name "<name>"]
    .venv/bin/python -m app.cli disable-user <username>   # signs them out everywhere
    .venv/bin/python -m app.cli enable-user <username>

Every command first brings the database up to date. Passwords are always
asked for interactively, never taken as arguments (they would end up in the
shell history). Reading attendance needs a supervisor login (plan, Day 4);
until then it is CLI-only.
"""

import argparse
import getpass
import sys
from datetime import date, datetime, timedelta

from app.core.config import DEFAULT_TENANT_ID
from app.core.db import connect, engine, migrate
from app.modules.attendance import service as attendance
from app.modules.devices import service as devices
from app.modules.users import service as users


def _create_admin(username: str, display_name: str | None) -> int:
    password = getpass.getpass("Password (12+ characters): ")
    if getpass.getpass("Same password again: ") != password:
        print("The two passwords differ; nothing was created.", file=sys.stderr)
        return 1
    with engine().connect() as conn:
        try:
            user_id = users.create_user(
                conn, DEFAULT_TENANT_ID, username, display_name or username, password
            )
        except users.WeakPassword as e:
            print("Choose a stronger password: " + "; ".join(e.reasons), file=sys.stderr)
            return 1
        except (users.InvalidUsername, users.UsernameTaken) as e:
            print(f"Username not accepted: {e}", file=sys.stderr)
            return 1
        conn.commit()
    print(f"Created user {users.normalise_username(username)} ({user_id}).")
    print("Roles arrive on Day 4; until then this account can sign in but not administer.")
    return 0


def _set_disabled(username: str, disabled: bool) -> int:
    with engine().connect() as conn:
        user = users.find(conn, DEFAULT_TENANT_ID, username)
        if user is None:
            print("No such user", file=sys.stderr)
            return 1
        users.set_disabled(conn, user["id"], disabled)
        conn.commit()
    print(("Disabled " if disabled else "Enabled ") + user["username"])
    return 0


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
    admin = sub.add_parser("create-admin")
    admin.add_argument("--username", required=True)
    admin.add_argument("--display-name")
    for name in ("disable-user", "enable-user"):
        sub.add_parser(name).add_argument("username")
    args = parser.parse_args(argv)

    migrate()
    if args.command == "migrate":
        print("Database is up to date.")
        return 0
    if args.command == "create-admin":
        return _create_admin(args.username, args.display_name)
    if args.command in ("disable-user", "enable-user"):
        return _set_disabled(args.username, args.command == "disable-user")

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

#!/usr/bin/env python3
"""Save an Octopus Energy API key for reading Intelligent Octopus charge plans.

    octopus-login --credentials ~/.local/state/solis-tools/octopus.json

Installed as the `octopus-login` command by Homebrew, and runnable directly as
`python3 octopus_login.py` from a source checkout. The SolisMenuBar app's
Octopus sign-in form drives this exact command as a subprocess, piping the key
to its stdin; its first stdout line and its `error: ` stderr lines are what
that form shows, so keep their prefixes. The API key is on the
Octopus dashboard under Personal details, API access. It is read from a prompt
(never a command-line argument, so it stays out of shell history and process
listings), checked against Octopus, and saved with the account number and
the account's Intelligent Octopus devices at owner-only permissions.
`solis-poll --octopus-enable` reads that file and never asks for the key.

With one account, it is found automatically; with more than one, the error
lists them; re-run with --account. Every enrolled device is read, and
solis-poll lists them again on each refresh, so a car enrolled again under a
new device ID needs no new sign-in. --device only checks that a device is on
the account.
Re-running replaces the file, which is how to recover from a regenerated key.
"""

from __future__ import annotations

import argparse
import getpass
import sys
from pathlib import Path

from octopus_client import OctopusClient, OctopusCredentials, OctopusError


def credentials_path(value: str) -> Path:
    # A live key pasted here is already in shell history by the time this runs,
    # so refuse it and, deliberately, never echo the value back.
    if value.startswith("sk_"):
        raise argparse.ArgumentTypeError(
            "this looks like an API key, not a file path. --credentials names the file to "
            "write; the key is typed at the prompt and never goes on the command line. "
            "If it was typed into a terminal, regenerate it on the Octopus dashboard"
        )
    return Path(value)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--credentials",
        type=credentials_path,
        required=True,
        help="file path to write the API key to (the key itself is typed at the prompt)",
    )
    parser.add_argument("--account", help="account number, such as A-1234ABCD")
    parser.add_argument(
        "--device", help="Intelligent Octopus device ID that must be on the account (optional)"
    )
    # Hidden, like hypervolt-login's: tests point these at fake_octopus.py.
    parser.add_argument("--host", default="api.octopus.energy", help=argparse.SUPPRESS)
    parser.add_argument("--port", type=int, default=443, help=argparse.SUPPRESS)
    parser.add_argument("--insecure", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    api_key = getpass.getpass("Octopus API key (not shown): ").strip()
    if not api_key:
        print("error: an API key is required", file=sys.stderr)
        return 2
    credentials = OctopusCredentials(api_key, args.account)
    try:
        credentials.validate()
        if args.device is not None:
            OctopusCredentials(api_key, device_ids=[args.device]).validate()
    except OctopusError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    try:
        client = OctopusClient(
            credentials, host=args.host, port=args.port, use_tls=not args.insecure
        )
        if credentials.account_number is None:
            client.discover_account_number()
        devices = client.discover_devices()
        if args.device is not None and args.device not in devices:
            print(
                f"error: device {args.device} is not on account {credentials.account_number} "
                f"(it has {', '.join(devices)})",
                file=sys.stderr,
            )
            return 1
        planned = client.planned_dispatches()
    except OctopusError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    credentials.save(args.credentials)
    print(
        f"Saved Octopus credentials for account {credentials.account_number}, "
        f"device(s) {', '.join(credentials.device_ids)}, to {args.credentials}"
    )
    print(f"Octopus currently has {len(planned)} planned charge slot(s) for the account.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

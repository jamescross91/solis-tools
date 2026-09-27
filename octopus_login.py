#!/usr/bin/env python3
"""Save an Octopus Energy API key for reading Intelligent Octopus charge plans.

    octopus-login --credentials ~/.local/state/solis-tools/octopus.json

Installed as the `octopus-login` command by Homebrew, and runnable directly as
`python3 octopus_login.py` from a source checkout. The API key is on the
Octopus dashboard under Personal details, API access. It is read from a prompt
(never a command-line argument, so it stays out of shell history and process
listings), checked against Octopus, and saved with the account number and
Intelligent Octopus device ID at owner-only permissions. `solis-poll
--octopus-enable` reads that file and never asks for the key.

With one account and one enrolled device, both are found automatically. With
more than one, the error lists them; re-run with --account or --device.
Re-running replaces the file, which is how to recover from a regenerated key.
"""

from __future__ import annotations

import argparse
import getpass
import sys
from pathlib import Path

from octopus_client import OctopusClient, OctopusCredentials, OctopusError


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--credentials", type=Path, required=True, help="where to write the API-key file"
    )
    parser.add_argument("--account", help="account number, such as A-1234ABCD")
    parser.add_argument("--device", help="Intelligent Octopus device ID")
    # Hidden, like hypervolt-login's: tests point these at fake_octopus.py.
    parser.add_argument("--host", default="api.octopus.energy", help=argparse.SUPPRESS)
    parser.add_argument("--port", type=int, default=443, help=argparse.SUPPRESS)
    parser.add_argument("--insecure", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    api_key = getpass.getpass("Octopus API key (not shown): ").strip()
    if not api_key:
        print("error: an API key is required", file=sys.stderr)
        return 2
    credentials = OctopusCredentials(api_key, args.account, args.device)
    try:
        credentials.validate()
    except OctopusError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    try:
        client = OctopusClient(
            credentials, host=args.host, port=args.port, use_tls=not args.insecure
        )
        if credentials.account_number is None:
            client.discover_account_number()
        if credentials.device_id is None:
            client.discover_device_id()
        planned = client.planned_dispatches()
    except OctopusError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    credentials.save(args.credentials)
    print(
        f"Saved Octopus credentials for account {credentials.account_number}, "
        f"device {credentials.device_id}, to {args.credentials}"
    )
    print(f"Octopus currently has {len(planned)} planned charge slot(s) for this device.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

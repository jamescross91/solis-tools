#!/usr/bin/env python3
"""Exchange a Hypervolt account password for a refresh token, once.

    hypervolt-login --credentials ~/.local/state/solis-tools/hypervolt.json

Installed as the `hypervolt-login` command by Homebrew, and runnable directly
as `python3 hypervolt_login.py` from a source checkout. The SolisMenuBar app's
own sign-in form drives this exact command as a subprocess, piping the
password to its stdin, so the account password only ever passes through this
one short-lived process.

The password is entered interactively (never as a command-line argument, so
it never lands in shell history or a process listing) and used exactly once,
here. Only the resulting refresh token is written to the credentials file;
solis_poll.py's --hypervolt-enable reads that file at runtime and rotates the
refresh token itself as it expires, and never asks for the password again. If
the refresh token is ever revoked, re-run this command rather than expecting
the poller to recover on its own — that failure is deliberately not silent,
so control does not resume against a stale identity.

Re-running this command overwrites any charger ID already stored in the file
with a freshly discovered one, in case the account's charger has changed.
"""

from __future__ import annotations

import argparse
import getpass
import sys
from pathlib import Path

from hypervolt_client import HypervoltAuthError, HypervoltClient, HypervoltCredentials


def login(
    email: str,
    password: str,
    *,
    timeout: float = 10.0,
    token_host: str = "kc.prod.hypervolt.co.uk",
    token_port: int = 443,
    use_tls: bool = True,
) -> HypervoltCredentials:
    import http.client
    import json
    import urllib.parse

    body = urllib.parse.urlencode(
        {
            "client_id": "home-assistant",
            "grant_type": "password",
            "scope": "openid profile email offline_access",
            "username": email,
            "password": password,
        }
    ).encode("ascii")
    connection_cls = http.client.HTTPSConnection if use_tls else http.client.HTTPConnection
    connection = connection_cls(token_host, token_port, timeout=timeout)
    try:
        connection.request(
            "POST",
            "/realms/retail-customers/protocol/openid-connect/token",
            body=body,
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": "solis-tools-hypervolt-client/1",
            },
        )
        response = connection.getresponse()
        payload = response.read()
        if response.status != 200:
            raise HypervoltAuthError(f"Hypervolt login was refused (HTTP {response.status})")
        token = json.loads(payload)
    finally:
        connection.close()
    return HypervoltCredentials(refresh_token=token["refresh_token"])


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--credentials", type=Path, required=True, help="where to write the resulting refresh token"
    )
    parser.add_argument("--email", help="Hypervolt account email (prompted if omitted)")
    # end-to-end tests can redirect to a local fake_hypervolt.py instead of
    # Hypervolt's real cloud API, the same hidden flags solis_poll.py exposes.
    parser.add_argument("--token-host", default="kc.prod.hypervolt.co.uk", help=argparse.SUPPRESS)
    parser.add_argument("--token-port", type=int, default=443, help=argparse.SUPPRESS)
    parser.add_argument("--api-host", default="api.hypervolt.co.uk", help=argparse.SUPPRESS)
    parser.add_argument("--api-port", type=int, default=443, help=argparse.SUPPRESS)
    parser.add_argument("--insecure", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    email = args.email or input("Hypervolt account email: ").strip()
    password = getpass.getpass("Hypervolt account password (not shown): ")
    if not email or not password:
        print("error: both an email and a password are required", file=sys.stderr)
        return 2

    try:
        credentials = login(
            email,
            password,
            token_host=args.token_host,
            token_port=args.token_port,
            use_tls=not args.insecure,
        )
        HypervoltClient(
            credentials,
            token_host=args.token_host,
            token_port=args.token_port,
            api_host=args.api_host,
            api_port=args.api_port,
            use_tls=not args.insecure,
        ).discover_charger_id()
    except HypervoltAuthError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    credentials.save(args.credentials)
    print(
        f"Saved a Hypervolt refresh token for charger {credentials.charger_id} to {args.credentials}"
    )
    print("The password was not stored. Re-run this script if the refresh token is ever revoked.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

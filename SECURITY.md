# Security policy

## Supported versions

Security fixes are made for the latest released version. Users should upgrade
with Homebrew or install the latest source release before reporting an issue.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use
[GitHub private vulnerability reporting](https://github.com/jamescross91/solis-tools/security/advisories/new)
to share:

- the affected version and platform
- reproduction steps or a proof of concept
- the expected impact
- any suggested mitigation

The maintainer will acknowledge a report as soon as practical, investigate it
privately and coordinate disclosure and a release when necessary. Please avoid
publishing details until a fix or agreed disclosure date is available.

Telemetry is read-only by default. Dynamic Grid Voltage Control is off by
default and introduces one tightly constrained write capability: the typed
import actuator may write raw holding-register PDU address 43488 with FC06 after
the user explicitly enables the feature. It captures the live value first,
verifies every write with FC03 and ownership-checks before restoring the
baseline. The typed export actuator for 43074 is present but runtime writes are
blocked until this installation is live-validated.

Baseline restoration also requires fresh, recovered telemetry. Writes are
journalled durably before transmission and ambiguous responses are reconciled
before further commands. Endpoint-scoped journals and an operating-system lock
prevent conflicting controller instances using the same host/port/unit spelling;
the lock does not coordinate other Modbus software or alternative host aliases.
Invalid or unidentified recovery records must not be discarded to bypass checks.

There is no general-purpose Modbus writer. A report that shows writes to any
other address, writes while control is disabled, bypass of the export gate,
exposure of credentials, or execution of untrusted output should be treated as
security-sensitive.

The optional `solis-hub` listens on a network port. Every request except
`/v1/healthz` needs a bearer token, compared in constant time and kept in a
0600 file, with failed attempts rate-limited per source address; remote access
is meant to sit behind Cloudflare Access as well. The hub never speaks Modbus.
A client holding the token can change the controller settings and sign the hub
in to Hypervolt and Octopus; the hub checks settings with the poller's own rules
and applies them by restarting the poller, and passes secrets only to the
login commands, on stdin. The token is therefore an administrator credential:
treat it like a password. A report that shows an authentication bypass, a
setting outside the controller settings (an address, a path, an arbitrary
poller option) reaching the poller, a secret in a log or response, any
client-driven Modbus write, or a way to make a second Modbus session should be
treated as security-sensitive.

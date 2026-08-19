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

The monitor is designed to use read-only Modbus input-register requests. A
report that shows it writing to an inverter, exposing credentials or executing
untrusted output should be treated as security-sensitive.

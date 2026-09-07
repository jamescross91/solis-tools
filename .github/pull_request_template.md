## Summary

<!-- Explain what changed and why. -->

## Validation

<!-- List the commands or checks you ran. -->

<!-- For releases, keep feature/version/changelog/formula changes in this same
PR. Attach the successful Release candidate run using scripts/release.py prepare
VERSION --binary-run RUN_ID, then include .release-assets.json. Do not create a
second formula PR. See docs/releasing.md. -->

## Checklist

- [ ] The change is focused and contains no unrelated edits.
- [ ] Tests cover new or changed behaviour.
- [ ] Documentation is updated where necessary.
- [ ] No secrets, credentials or captured logs from a real network are included.
- [ ] Telemetry remains read-only; control writes require explicit opt-in, stay within the typed whitelist, and preserve the export-validation gate.
- [ ] Control changes include fake-inverter or deterministic safety/recovery tests; no test writes to physical hardware.

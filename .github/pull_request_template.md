## Summary

<!-- Explain what changed and why. -->

## Validation

<!-- List the commands or checks you ran. -->

## Checklist

- [ ] The change is focused and contains no unrelated edits.
- [ ] Tests cover new or changed behaviour.
- [ ] Documentation is updated where necessary.
- [ ] No secrets, credentials or captured logs from a real network are included.
- [ ] Telemetry remains read-only; control writes require explicit opt-in, stay within the typed whitelist, and preserve the export-validation gate.
- [ ] Control changes include fake-inverter or deterministic safety/recovery tests; no test writes to physical hardware.

# Fixtures

Record a sample of the target app (pseudonymized text) and save it here as `sample.jsonl`:

```bash
dsh-reflex dev on
dsh-reflex ax record --app <bundleId> --duration 60s --out Fixtures/sample.jsonl
```

Press Enter during recording to add markers (e.g. "switched tab"). Tests replay the file on virtual time
with `ProgramHarness`, so no real app is needed.

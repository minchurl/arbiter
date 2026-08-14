# Experiment Results

This directory stores durable experiment ledgers. Generated files under
`build/` are useful locally, but they are not tracked by git. When an experiment
changes the interpretation of a placement strategy, record the run shape,
summary numbers, failure modes, and next questions here. Bounded text-only raw
results needed for independent reanalysis may be copied under `artifacts/`;
large traces and benchmark binaries must remain outside git.

## Ledgers and Plans

- [Generic Placement Experiment Results](generic-placement-results.md)
- [Hot-Set Placement Experiment Results](hotset-results.md)
- [XIndex Automatic Hot-Set Sweep and Overnight Plan](hotset-auto-sweep-plan.md)

## Archived Raw Artifacts

- [2026-08-14 XIndex automatic-k1 overnight run](artifacts/hotset-auto-overnight-20260814-012754/README.md):
  22 row logs, resource measurements, compiler decisions, and 375 throughput
  samples.

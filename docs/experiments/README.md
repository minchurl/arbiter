# Experiment Results

This directory stores durable experiment ledgers. Generated files under
`build/` are useful locally, but they are not tracked by git. When an experiment
changes the interpretation of a placement strategy, record the run shape,
summary numbers, failure modes, and next questions here. Bounded text-only raw
results needed for independent reanalysis may be copied under `artifacts/`;
large traces and benchmark binaries must remain outside git.

## Ledgers and Plans

- [Current XIndex hot-set method and retained results](xindex-hotset.md):
  concise entry point, canonical `raw-046` replay, top-12 policy index, and
  claim boundaries.
- [Generic Placement Experiment Results](generic-placement-results.md)
- [Hot-Set Placement Experiment Results](hotset-results.md)
- [XIndex Automatic Hot-Set Sweep and Overnight Plan](hotset-auto-sweep-plan.md)
- [XIndex Full-Trace Broad Hot-Set Sweep](hotset-broad-sweep-plan.md):
  historical deterministic parameter search and the current seed-only driver,
  with threshold-based promotion, parser fail-closed behavior, and a 64G
  protected execution envelope.
- [XIndex Full-Trace Broad Sweep Results](hotset-broad-sweep-results.md): two
  preliminary screen runs, controller failure analysis, short-run tendencies,
  and the bounded claims that can be carried into confirmation.
- [XIndex/YCSB-A Full-Trace Broad Sweep Korean Report](xindex-ycsba-fulltrace-broad-sweep-report-ko.md):
  Korean handoff covering benchmark mechanics, complete parameter settings,
  planned versus actual execution, results, limitations, and next steps.

## Archived Raw Artifacts

- [Curated XIndex hot-set evidence](artifacts/xindex-hotset/README.md): top-12
  confirmation aggregate, five-candidate final stage, `raw-046` observations,
  and the post-cleanup replay.
- [2026-08-14 XIndex automatic-k1 overnight run](artifacts/hotset-auto-overnight-20260814-012754/README.md):
  22 row logs, resource measurements, compiler decisions, and 375 throughput
  samples.
- [2026-08-19 XIndex broad sweep v1](artifacts/hotset-broad-sweep-20260819-234706/README.md):
  exact top-level controller artifacts from the parser-failed first screen.
- [2026-08-22 XIndex broad sweep v2](artifacts/hotset-broad-sweep-v2-20260822-012131/README.md):
  exact top-level artifacts from the fixed-size screen and its ranking-format
  failure.
- [2026-10-06 completed XIndex adaptive broad sweep](artifacts/hotset-broad-sweep-v2-rerun-20261006-110924/README.md):
  131-row completed screen/confirmation/final run, aggregate measurements,
  finalist configs, safety checks, and homogeneous 180-second results.
- [2026-10-08 seed-only `raw-046` replay](artifacts/seed-only-raw046-replay-20261007-235651/README.md):
  post-cleanup full-trace local/CXL regression result, compiler decisions,
  placement reports, resource measurements, and throughput samples.

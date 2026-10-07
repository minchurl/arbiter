# Compact XIndex Hot-Set Evidence

This directory is a curated, small view of the strongest completed parameter
search results and the later seed-only replay. The original result directories,
generated controllers, and every candidate config remain checked in beside it
under `docs/experiments/artifacts/`.

| File | Contents |
|---|---|
| `confirmation-summary.csv` | 12 retained policies; one 15s screening pair plus two 60s confirmation pairs |
| `final-stage-summary.csv` | five finalists; four homogeneous 180s local/CXL pairs |
| `raw-046-final-observations.csv` | eight process-level rows behind the final `raw-046` aggregate |
| `raw-046-final-throughput-samples.csv` | 30-second samples from those eight rows |
| [`../seed-only-raw046-replay-20261007-235651/`](../seed-only-raw046-replay-20261007-235651/) | one full-trace seed-only local/CXL regression pair, reports, logs, and hashes |

The raw row paths in the CSV files document the original result layout and are
not expected to exist in a fresh checkout. All values needed for the retained
aggregate claim are stored here. See
[`../../xindex-hotset.md`](../../xindex-hotset.md) for the method, setup,
interpretation, and claim boundary.

Run `sha256sum -c artifacts.sha256` from this directory to verify all retained
files. The original seed-only replay has its own checksum manifest as well.

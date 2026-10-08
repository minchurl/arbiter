# Research History

This directory contains superseded experiment plans and results for removed or
inactive Arbiter implementations. It is retained to explain how the current
seed-only XIndex workflow was reached.

The commands and configuration keys in these documents are historical. They
must not be treated as current run instructions. Use
[`docs/results/`](../results/README.md) for current claims and
[`README.md`](../../README.md) for supported commands.

The history covers:

- generic shared-mutable placement and its negative baseline;
- lock-touch page migration and its instrumentation overhead;
- direct-allocation and manually pinned site-99 pilots;
- automatic-k and member-expansion experiments;
- the broad-search controller design, failures, fixes, and handoff notes.

Large raw artifacts from failed or superseded runs were removed from the
active tree. They remain recoverable from Git history. Exact inputs reused by
the current YCSB-B analysis were retained under
[`configs/hotset/search-spaces/xindex-broad-100/`](../../configs/hotset/search-spaces/xindex-broad-100/README.md).

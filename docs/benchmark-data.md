# Benchmark Data

Arbiter keeps benchmark source code in this repository, but the full XIndex/YCSB
trace files are large generated artifacts. The canonical local source is:

```text
~/niagara_workloads/YCSB/xindex_dat
```

Active full-size files (shared by A and F):

```text
xindex_load_ycsb_a.dat
xindex_transaction_ycsb_a.dat
```

Import them into the repository working tree with:

```sh
./scripts/import-niagara-workloads.sh --mode copy
```

For local work on the same filesystem, this avoids another 26GB copy:

```sh
./scripts/import-niagara-workloads.sh --mode hardlink
```

The raw `.dat` files are ignored by git so local runs do not accidentally stage
multi-gigabyte generated traces.

## GitHub Packaging

GitHub blocks regular git objects larger than 100MiB. Git LFS also has
per-file limits, so the 21GB transaction traces must be compressed and split
before they can be stored through GitHub.

After installing Git LFS:

```sh
git lfs install
./scripts/import-niagara-workloads.sh --mode copy
./scripts/package-xindex-ycsb-data.sh
```

This writes compressed chunks under:

```text
benchmark/xindex/YCSB/xindex_dat/github-parts
```

Those chunks are covered by `.gitattributes` and should be committed with Git
LFS enabled. The default chunk size is `1900M`, below GitHub Free/Pro's 2GB
LFS per-file limit.

Fresh clones can restore the raw traces with:

```sh
git lfs pull
./scripts/restore-xindex-ycsb-data.sh
```

The full fresh-clone benchmark setup wraps this restore step:

```sh
./scripts/setup-benchmarks.sh
```

That script also builds the Arbiter runtime/plugin, builds GUPS and XIndex
benchmark binaries, creates short XIndex/YCSB smoke traces, and runs short
native/local smoke checks.

If Git LFS is not available, the same chunk directory can be uploaded as GitHub
release assets and restored after downloading the parts into `github-parts`.

## XIndex Run Notes

The XIndex run wrapper reads traces from:

```text
benchmark/xindex/YCSB/xindex_dat
```

Override the directory with `XINDEX_DATA_DIR` or pass exact files with
`YCSB_LOAD_PATH` and `YCSB_TX_PATH`.

YCSB-F reuses the A load and transaction files. In F mode the driver interprets
each UPDATE as one same-worker get/put transaction. It retains the original key
order and read/update mixture and creates no second multi-gigabyte trace.
Explicit `READMODIFYWRITE usertable user<key> ...` records are also accepted.

YCSB-B's measured results and compressed Git LFS chunks are retained as history.
The import, package, and restore defaults now use A only. To restore archived B:

```sh
./scripts/restore-xindex-ycsb-data.sh --include-archived-b
```

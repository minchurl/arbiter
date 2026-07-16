# Benchmark Data

Arbiter keeps benchmark source code in this repository, but the full XIndex/YCSB
trace files are large generated artifacts. The canonical local source is:

```text
~/niagara_workloads/YCSB/xindex_dat
```

Expected full-size files:

```text
xindex_load_ycsb_a.dat
xindex_transaction_ycsb_a.dat
xindex_transaction_ycsb_b.dat
```

Import them into the repository working tree with:

```sh
./scripts/import-niagara-workloads.sh --mode copy
```

For local work on the same filesystem, this avoids another 46GB copy:

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

If Git LFS is not available, the same chunk directory can be uploaded as GitHub
release assets and restored after downloading the parts into `github-parts`.

## XIndex Run Notes

The XIndex run wrapper reads traces from:

```text
benchmark/xindex/YCSB/xindex_dat
```

Override the directory with `XINDEX_DATA_DIR` or pass exact files with
`YCSB_LOAD_PATH` and `YCSB_TX_PATH`.

YCSB-B uses `xindex_transaction_ycsb_b.dat`. If
`xindex_load_ycsb_b.dat` is absent, the wrapper falls back to
`xindex_load_ycsb_a.dat`, matching the available Niagara workload data.

#!/usr/bin/env python3
"""Run explicit microbenchmark cases with alternating local/CXL placement.

Case JSON is a list of objects with name, build (relative to --build-root),
and optional victims, noise, noise_mode, table_size, ballast_mb, read_pct.
Each build must come from build-btree-coherence.sh. No runs overlap.
"""
import argparse
import csv
import json
from pathlib import Path
import runpy
import shutil
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
RUNNER = runpy.run_path(str(ROOT / "scripts/run-btree-coherence.py"))
PARAMS = dict(victims=32, noise=0, noise_mode="none", table_size=256, ballast_mb=8192, read_pct=50)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cases", type=Path)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--result-dir", type=Path, required=True)
    parser.add_argument("--rounds", type=RUNNER["positive"], default=2)
    parser.add_argument("--duration", type=RUNNER["positive"], default=15)
    parser.add_argument("--perf", type=Path, help="optional perf binary for measurement-window counters")
    parser.add_argument("--cpu-node", type=int, default=0)
    parser.add_argument("--local-node", type=int, default=0)
    parser.add_argument("--cxl-node", type=int, default=2)
    opts = parser.parse_args()
    if opts.local_node == opts.cxl_node:
        parser.error("memory nodes must differ")
    cases = json.loads(opts.cases.read_text())
    names = set()
    for case in cases:
        if not case["name"].replace("-", "").replace("_", "").isalnum() or case["name"] in names:
            parser.error("case names must be unique, with letters/digits/hyphens/underscores")
        names.add(case["name"])
        if set(case) - {"name", "build", *PARAMS}:
            parser.error(f"unknown parameters in {case['name']}")
    opts.result_dir.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(opts.cases, opts.result_dir / "cases.json")
    (opts.result_dir / "arguments.json").write_text(json.dumps(vars(opts), default=str, indent=2) + "\n")
    fields = ["case", "build", *PARAMS, "entry_bytes", "epoch_store", "fast_index", *RUNNER["COLUMNS"]]
    with (opts.result_dir / "runs.csv").open("w") as stream:
        writer = csv.DictWriter(stream, fields, lineterminator="\n")
        writer.writeheader()
        for rep in range(1, opts.rounds + 1):
            # Reverse case order and placement order on alternate rounds.
            for case in cases if rep % 2 else list(reversed(cases)):
                binary_dir = (opts.build_root / case["build"]).resolve()
                layout = json.loads((binary_dir / "micro-layout.json").read_text())
                layout.setdefault("fast_index", 0)
                params = PARAMS | {key: case[key] for key in PARAMS if key in case}
                if (not 1 <= params["victims"] <= 256 or not 0 <= params["noise"] <= 256
                        or params["noise_mode"] not in ("none", "spin", "maint", "combined")
                        or params["table_size"] < 1 or params["ballast_mb"] < 0
                        or not 0 <= params["read_pct"] <= 100):
                    parser.error(f"invalid parameters for {case['name']}")
                out = opts.result_dir / case["name"]
                out.mkdir(exist_ok=True)
                if rep == 1:
                    for name in ("inputs.sha256", "selected-objects.json", "micro-layout.json",
                                 "micro-native.hitm-seed-sites.csv"):
                        shutil.copyfile(binary_dir / name, out / name)
                selected = json.loads((binary_dir / "selected-objects.json").read_text())
                if selected["micro"] != {"table": selected["micro"].get("table")}:
                    parser.error("sweep requires table-only automatic selection")
                table_bytes = params["table_size"] * layout["entry_bytes"]
                args = SimpleNamespace(**params, **vars(opts), bin_dir=binary_dir,
                                       selected_objects=selected, entry_bytes=layout["entry_bytes"],
                                       arena_chunk_bytes=max(2 << 20, 2 << (table_bytes - 1).bit_length()))
                args.result_dir = out
                print(f"case {case['name']} ({case['build']})", flush=True)
                for mode in ("local", "cxl") if rep % 2 else ("cxl", "local"):
                    row = RUNNER["measure"](args, "micro", mode, rep)
                    writer.writerow(dict(case=case["name"], build=case["build"], **params, **layout, **row))
                    stream.flush()


if __name__ == "__main__":
    main()

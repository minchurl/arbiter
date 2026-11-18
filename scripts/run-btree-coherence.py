#!/usr/bin/env python3
"""Compare matched native, selected-local and selected-CXL executables."""
import argparse
import csv
import json
import os
from pathlib import Path
import shutil
import subprocess
from datetime import datetime
from statistics import mean


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BIN_DIR = ROOT / "build/arbiter-bench/btree-coherence"
MODES = ("native", "local", "cxl")
COLUMNS = ("benchmark", "round", "mode", "node", "operations", "seconds", "mops_per_s",
           "max_rss_kib", "arena_allocations", "arena_resident_bytes_at_exit", "swaps",
           "live_sample_nodes", "checked_keys", "fallback_allocations", "page_query_errors", "selected_sites")
TARGETED_OBJECTS = {"btree": {"keys": 1, "pointers": 2}, "micro": {"table": 4}}
OBJECT_BYTES = {"keys": 120, "pointers": 128, "table": 8192, "ballast": 8 << 30}


def positive(value):
    n = int(value)
    if n < 1:
        raise argparse.ArgumentTypeError("expected a positive integer")
    return n


def fields(line):
    return dict(item.split("=", 1) for item in line.split() if "=" in item)


def output_line(log, prefix):
    matches = [line for line in log.splitlines() if line.startswith(prefix)]
    if len(matches) != 1:
        raise ValueError(f"expected one {prefix!r} line, found {len(matches)}")
    return matches[0]


def measure(args, benchmark, mode, round_id):
    selected = mode != "native"
    node = args.cxl_node if mode == "cxl" else args.local_node
    stem = args.result_dir / f"{benchmark}-{round_id}-{mode}"
    binary = args.bin_dir / f"{benchmark}-{'placed' if selected else 'native'}"
    command = [str(binary)]
    if benchmark == "micro":
        command += ["--victims", "32", "--noise", "0", "--mode", "none",
                    "--duration", str(args.duration), "--table-size", "256", "--ballast-mb", "8192"]
    env = {k: v for k, v in os.environ.items() if not k.startswith("ARBITER_")}
    env.update(OMP_NUM_THREADS="32", OMP_DYNAMIC="FALSE")
    if selected:
        env.update(ARBITER_HEAP_BACKEND="arena", ARBITER_TARGET_NODE=str(node),
                   ARBITER_ARENA_RESERVE_BYTES=str(24 << 30), ARBITER_ARENA_STRICT="1",
                   ARBITER_ARENA_REPORT="1")
    print(f"round {round_id}: {benchmark} {mode}", flush=True)
    with stem.with_suffix(".log").open("w") as log_file:
        subprocess.run(["systemd-run", "--user", "--scope", "--quiet", "-p", "MemoryMax=64G",
                        "-p", "MemorySwapMax=0", "/usr/bin/time", "-f", "%M %W",
                        "-o", str(stem.with_suffix(".time")), "numactl",
                        f"--cpunodebind={args.cpu_node}", f"--membind={args.local_node}",
                        *command], env=env, stdout=log_file, stderr=subprocess.STDOUT, check=True)
    objects = args.selected_objects[benchmark] if selected else {}
    row = read_measurement(stem, benchmark, round_id, mode, node, args.local_node, args.duration, objects)
    print(f"  {float(row['mops_per_s']):.3f} Mops/s, RSS {row['max_rss_kib'] / 2**20:.2f} GiB", flush=True)
    return row


def read_measurement(stem, benchmark, round_id, mode, node, local_node, duration, selected_objects=None):
    if selected_objects is None:
        selected_objects = TARGETED_OBJECTS[benchmark] if mode != "native" else {}
    log = stem.with_suffix(".log").read_text()
    checked_keys = ""
    if benchmark == "btree":
        result = fields(output_line(log, "btree-result "))
        ops, seconds = int(result["lookups"]), float(result["seconds"])
        checked_keys = int(result["checked"])
        if ops != 600_000_000 or checked_keys != 4096:
            raise ValueError("B-tree sampled lookup validation failed")
        expected = {"keys": local_node, "pointers": local_node, "payload": local_node}
    else:
        config = fields(output_line(log, "config: "))
        sizes = fields(output_line(log, "  table_size="))
        if (config["victims"] != "32" or config["mode"] != "none" or config["noise"].split("(")[0] != "0"
                or sizes["table_size"] != "256" or sizes["ballast"] != "8192MB" or sizes["read_pct"] != "50"):
            raise ValueError(f"unexpected coherence_noise configuration in {stem}.log")
        result = fields(output_line(log, "result: "))
        ops, seconds = int(result["total_ops"]), float(result["elapsed"].removesuffix("s"))
        if ops % 64 or abs(seconds - duration) > max(1, duration * 0.05):
            raise ValueError(f"unexpected microbenchmark count or duration: {result}")
        expected = {"table": local_node, "ballast": local_node}
    for obj in selected_objects:
        expected[obj] = node
    if ops <= 0 or seconds <= 0:
        raise ValueError("empty measurement")

    samples = []
    for obj, target in expected.items():
        line = output_line(log, f"placement object={obj} ")
        nodes = fields(line)["nodes"]
        if nodes.split(",") != [str(target)] * 3:
            raise ValueError(f"expected node {target}: {line}")
        samples.append(f"{obj}={nodes}")

    allocations = resident = fallbacks = query_errors = ""
    if selected_objects:
        summary = fields(output_line(log, "arbiter-arena-summary "))
        placement = fields(output_line(log, "arbiter-arena-residency "))
        allocations = int(summary["allocations"])
        resident = int(placement["resident_bytes"])
        fallbacks = int(summary["fallback_allocations"])
        query_errors = int(placement["query_error_pages"])
        sites = [fields(line) for line in log.splitlines() if line.startswith("arbiter-arena-site ")]
        shapes = {(int(s["site"]), int(s["object_bytes"])) for s in sites}
        expected_shapes = {(site, OBJECT_BYTES[obj]) for obj, site in selected_objects.items()}
        counts = {int(s["allocations"]) for s in sites}
        valid_sites = (len(sites) == len(selected_objects) and shapes == expected_shapes
                       and len(counts) == 1 and sum(int(s["allocations"]) for s in sites) == allocations)
        if benchmark == "micro":
            valid_sites = valid_sites and counts == {1}
        if not (valid_sites and allocations > 0 and fallbacks == 0
                and summary["node"] == str(node) and query_errors == 0
                and placement["mincore_error_batches"] == "0"
                and resident > 0 and placement.get(f"node{node}_pages") == placement["resident_pages"]):
            raise ValueError(f"incomplete or misplaced arena in {stem}.log")
    elif "arbiter-arena-site " in log:
        raise ValueError(f"unexpected selected allocations in {stem}.log")
    rss, swaps = map(int, stem.with_suffix(".time").read_text().split())
    if swaps:
        raise ValueError(f"swapped during {stem}")
    return dict(benchmark=benchmark, round=round_id, mode=mode, node=node,
                operations=ops, seconds=seconds, mops_per_s=f"{ops / seconds / 1e6:.6f}",
                max_rss_kib=rss, arena_allocations=allocations, arena_resident_bytes_at_exit=resident,
                swaps=swaps, live_sample_nodes=" ".join(samples), checked_keys=checked_keys,
                fallback_allocations=fallbacks, page_query_errors=query_errors,
                selected_sites=",".join(str(site) for site in selected_objects.values()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--benchmark", choices=("both", "btree", "micro"), default="both")
    parser.add_argument("--rounds", type=positive, default=3)
    parser.add_argument("--duration", type=positive, default=120, help="microbenchmark seconds per row")
    parser.add_argument("--cpu-node", type=int, default=0)
    parser.add_argument("--local-node", type=int, default=0)
    parser.add_argument("--cxl-node", type=int, default=2)
    parser.add_argument("--bin-dir", type=Path, default=os.getenv("ARBITER_BENCH_BUILD_DIR", DEFAULT_BIN_DIR))
    parser.add_argument("--result-dir", type=Path, default=ROOT / "build/arbiter-bench" /
                        datetime.now().strftime("btree-coherence-%Y%m%d-%H%M%S"))
    args = parser.parse_args()
    if args.local_node == args.cxl_node:
        parser.error("the two memory nodes must differ")
    args.bin_dir = args.bin_dir.resolve()
    objects_path = args.bin_dir / "selected-objects.json"
    args.selected_objects = json.loads(objects_path.read_text()) if objects_path.exists() else TARGETED_OBJECTS
    args.result_dir.mkdir(parents=True, exist_ok=False)
    print(f"Results: {args.result_dir}", flush=True)
    for artifact in ("inputs.sha256", "btree.hitm-seed-sites.csv", "micro.hitm-seed-sites.csv"):
        shutil.copyfile(args.bin_dir / artifact, args.result_dir / artifact)
    if objects_path.exists():
        shutil.copyfile(objects_path, args.result_dir / objects_path.name)
    for report in args.bin_dir.glob("*-*.hitm-seed-sites.csv"):
        shutil.copyfile(report, args.result_dir / report.name)
    benchmarks = ("btree", "micro") if args.benchmark == "both" else (args.benchmark,)
    csv_path = args.result_dir / "runs.csv"
    with csv_path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, COLUMNS, lineterminator="\n")
        writer.writeheader()
        for index in range(args.rounds):
            # Rotate all three modes through the first, middle and last position.
            shift = index % len(MODES)
            for benchmark in benchmarks:
                for mode in MODES[shift:] + MODES[:shift]:
                    writer.writerow(measure(args, benchmark, mode, index + 1))
                    stream.flush()
    with csv_path.open() as stream:
        rows = list(csv.DictReader(stream))
    for benchmark in benchmarks:
        if not args.selected_objects[benchmark]:
            print(f"{benchmark} selected zero allocations. All modes used local memory.")
        rates = {mode: mean(float(row["mops_per_s"]) for row in rows
                            if row["benchmark"] == benchmark and row["mode"] == mode)
                 for mode in MODES}
        print(f"{benchmark} mean Mops/s  native {rates['native']:.2f}  "
              f"local {rates['local']:.2f}  CXL {rates['cxl']:.2f}  "
              f"CXL vs local {(rates['cxl'] / rates['local'] - 1) * 100:+.2f}%")


if __name__ == "__main__":
    main()

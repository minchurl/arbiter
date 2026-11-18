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
PERF_EVENTS = ("cycles:u,instructions:u,mem_load_l3_hit_retired.xsnp_fwd:u,"
               "mem_load_retired.l3_miss:u,mem_inst_retired.lock_loads:u")


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
        command += ["--victims", str(args.victims), "--noise", str(args.noise), "--mode", args.noise_mode,
                    "--duration", str(args.duration), "--table-size", str(args.table_size),
                    "--ballast-mb", str(args.ballast_mb), "--read-pct", str(args.read_pct)]
    env = {k: v for k, v in os.environ.items() if not k.startswith("ARBITER_")}
    env.update(OMP_NUM_THREADS="32", OMP_DYNAMIC="FALSE")
    if selected:
        env.update(ARBITER_HEAP_BACKEND="arena", ARBITER_TARGET_NODE=str(node),
                   ARBITER_ARENA_RESERVE_BYTES=str(24 << 30), ARBITER_ARENA_STRICT="1",
                   ARBITER_ARENA_SLAB_BYTES=str(args.arena_chunk_bytes), ARBITER_ARENA_REPORT="1")
    fifos = []
    if getattr(args, "perf", None):
        if benchmark != "micro":
            raise ValueError("measurement-window perf control is implemented only for micro")
        control, ack = (stem.with_suffix(suffix).resolve() for suffix in (".ctl", ".ack"))
        for path in (control, ack):
            os.mkfifo(path)
            fifos.append(path)
        env.update(ARBITER_MICRO_PERF_CONTROL=str(control), ARBITER_MICRO_PERF_ACK=str(ack))
        command = [str(args.perf), "stat", "-x,", "-D", "-1", "--control", f"fifo:{control},{ack}",
                   "-e", PERF_EVENTS, "-o", str(stem.with_suffix(".perf")), "--", *command]
    print(f"round {round_id}: {benchmark} {mode}", flush=True)
    try:
        with stem.with_suffix(".log").open("w") as log_file:
            subprocess.run(["systemd-run", "--user", "--scope", "--quiet", "-p", "MemoryMax=64G",
                            "-p", "MemorySwapMax=0", "/usr/bin/time", "-f", "%M %W",
                            "-o", str(stem.with_suffix(".time")), "numactl",
                            f"--cpunodebind={args.cpu_node}", f"--membind={args.local_node}",
                            *command], env=env, stdout=log_file, stderr=subprocess.STDOUT, check=True)
    finally:
        for path in fifos:
            path.unlink()
    if getattr(args, "perf", None):
        counters = {}
        with stem.with_suffix(".perf").open() as stream:
            for values in csv.reader(stream):
                if values and not values[0].startswith("#"):
                    count, coverage = float(values[0]), float(values[4])
                    if count < 0 or not 99 <= coverage <= 100:
                        raise ValueError(f"counter unavailable or multiplexed in {stem}.perf: {values}")
                    counters[values[2]] = count
        if set(counters) != set(PERF_EVENTS.split(",")) or counters["cycles:u"] <= 0:
            raise ValueError(f"incomplete measurement-window counters in {stem}.perf")
    objects = args.selected_objects[benchmark] if selected else {}
    micro_config = dict(victims=args.victims, noise=args.noise, mode=args.noise_mode,
                        table_size=args.table_size, ballast_mb=args.ballast_mb, read_pct=args.read_pct,
                        entry_bytes=args.entry_bytes)
    row = read_measurement(stem, benchmark, round_id, mode, node, args.local_node,
                           args.duration, objects, micro_config)
    print(f"  {float(row['mops_per_s']):.3f} Mops/s, RSS {row['max_rss_kib'] / 2**20:.2f} GiB", flush=True)
    return row


def read_measurement(stem, benchmark, round_id, mode, node, local_node, duration,
                     selected_objects=None, micro_config=None):
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
        mc = micro_config or dict(victims=32, noise=0, mode="none", table_size=256,
                                 ballast_mb=8192, read_pct=50, entry_bytes=32)
        noise = 0 if mc["mode"] == "none" else mc["noise"] + (mc["mode"] == "combined")
        if (config["victims"] != str(mc["victims"]) or config["mode"] != mc["mode"]
                or config["noise"].split("(")[0] != str(noise)
                or sizes["table_size"] != str(mc["table_size"])
                or sizes["ballast"] != f"{mc['ballast_mb']}MB" or sizes["read_pct"] != str(mc["read_pct"])):
            raise ValueError(f"unexpected coherence_noise configuration in {stem}.log")
        result = fields(output_line(log, "result: "))
        ops, seconds = int(result["total_ops"]), float(result["elapsed"].removesuffix("s"))
        if ops % 64 or abs(seconds - duration) > max(1, duration * 0.05):
            raise ValueError(f"unexpected microbenchmark count or duration: {result}")
        expected = {"table": local_node}
        if mc["ballast_mb"]:
            expected["ballast"] = local_node
        if "validation: " in log:
            check = fields(output_line(log, "validation: "))
            reads, writes = int(check["reads"]), int(check["writes"])
            if (check["status"] != "ok" or int(check["versions"]) != writes or reads + writes != ops
                    or (mc["read_pct"] == 100 and writes) or (mc["read_pct"] == 0 and reads)):
                raise ValueError("microbenchmark read/write validation failed")
            layout = fields(output_line(log, "layout: "))
            if int(layout["entry_bytes"]) != mc["entry_bytes"]:
                raise ValueError("unexpected entry layout")
        elif micro_config is not None:
            raise ValueError("rebuild microbenchmark with read/write validation before new measurements")
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
        object_bytes = dict(OBJECT_BYTES)
        if benchmark == "micro":
            object_bytes.update(table=mc["table_size"] * mc["entry_bytes"], ballast=mc["ballast_mb"] << 20)
        expected_shapes = {(site, object_bytes[obj]) for obj, site in selected_objects.items()}
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
    parser.add_argument("--victims", type=positive, default=32)
    parser.add_argument("--noise", type=int, default=0)
    parser.add_argument("--noise-mode", choices=("none", "spin", "maint", "combined"), default="none")
    parser.add_argument("--table-size", type=positive, default=256)
    parser.add_argument("--ballast-mb", type=int, default=8192)
    parser.add_argument("--read-pct", type=int, choices=range(101), metavar="0..100", default=50)
    parser.add_argument("--arena-chunk-bytes", type=positive, default=2 << 20)
    parser.add_argument("--modes", choices=MODES, nargs="+", default=list(MODES))
    parser.add_argument("--perf", type=Path, help="perf binary; count only the microbenchmark measurement window")
    parser.add_argument("--cpu-node", type=int, default=0)
    parser.add_argument("--local-node", type=int, default=0)
    parser.add_argument("--cxl-node", type=int, default=2)
    parser.add_argument("--bin-dir", type=Path, default=os.getenv("ARBITER_BENCH_BUILD_DIR", DEFAULT_BIN_DIR))
    parser.add_argument("--result-dir", type=Path, default=ROOT / "build/arbiter-bench" /
                        datetime.now().strftime("btree-coherence-%Y%m%d-%H%M%S"))
    args = parser.parse_args()
    if args.noise < 0 or args.noise > 256 or args.ballast_mb < 0 or args.victims > 256:
        parser.error("noise must be 0..256, victims 1..256, ballast non-negative")
    if len(set(args.modes)) != len(args.modes):
        parser.error("duplicate modes")
    if args.perf and args.benchmark != "micro":
        parser.error("--perf requires --benchmark micro")
    if args.local_node == args.cxl_node:
        parser.error("the two memory nodes must differ")
    args.bin_dir = args.bin_dir.resolve()
    layout_path = args.bin_dir / "micro-layout.json"
    args.entry_bytes = json.loads(layout_path.read_text())["entry_bytes"] if layout_path.exists() else 32
    objects_path = args.bin_dir / "selected-objects.json"
    args.selected_objects = json.loads(objects_path.read_text()) if objects_path.exists() else TARGETED_OBJECTS
    args.result_dir.mkdir(parents=True, exist_ok=False)
    (args.result_dir / "arguments.json").write_text(json.dumps(vars(args), default=str, indent=2) + "\n")
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
            shift = index % len(args.modes)
            for benchmark in benchmarks:
                for mode in args.modes[shift:] + args.modes[:shift]:
                    writer.writerow(measure(args, benchmark, mode, index + 1))
                    stream.flush()
    with csv_path.open() as stream:
        rows = list(csv.DictReader(stream))
    for benchmark in benchmarks:
        if not args.selected_objects[benchmark]:
            print(f"{benchmark} selected zero allocations. All modes used local memory.")
        rates = {mode: mean(float(row["mops_per_s"]) for row in rows
                            if row["benchmark"] == benchmark and row["mode"] == mode)
                 for mode in args.modes}
        print(f"{benchmark} mean Mops/s  " + "  ".join(f"{mode} {rate:.2f}" for mode, rate in rates.items()))
        if "local" in rates and "cxl" in rates:
            print(f"CXL vs local {(rates['cxl'] / rates['local'] - 1) * 100:+.2f}%")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Check read/write extremes and lock ownership on a single contended entry."""
import argparse
import os
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
helpers = runpy.run_path(str(ROOT / "scripts/run-btree-coherence.py"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bin_dir", type=Path)
    parser.add_argument("--node", type=int, default=0)
    args = parser.parse_args()
    for mode in ("native", "placed"):
        binary = args.bin_dir.resolve() / f"micro-{mode}"
        env = {k: v for k, v in os.environ.items() if not k.startswith("ARBITER_")}
        if mode == "placed":
            env.update(ARBITER_HEAP_BACKEND="arena", ARBITER_TARGET_NODE=str(args.node),
                       ARBITER_ARENA_STRICT="1")
        for read_pct in (0, 50, 100):
            result = subprocess.run([str(binary), "--victims", "16", "--table-size", "1",
                                     "--duration", "1", "--noise", "2", "--mode", "combined",
                                     "--read-pct", str(read_pct)], env=env,
                                    capture_output=True, text=True, check=True, timeout=30)
            check = helpers["fields"](helpers["output_line"](result.stdout, "validation: "))
            count = helpers["fields"](helpers["output_line"](result.stdout, "result: "))
            reads, writes = int(check["reads"]), int(check["writes"])
            assert check["status"] == "ok" and writes == int(check["versions"])
            assert reads + writes == int(count["total_ops"]) > 0
            assert read_pct != 0 or reads == 0
            assert read_pct != 100 or writes == 0
            assert read_pct != 50 or (reads > 0 and writes > 0)
        for flag, value in (("--read-pct", "101"), ("--read-pct", "-1"), ("--victims", "0"),
                            ("--victims", "257"), ("--noise", "-1"), ("--table-size", "0"),
                            ("--duration", "bad"), ("--ballast-mb", "-1")):
            result = subprocess.run([str(binary), flag, value], env=env,
                                    capture_output=True, text=True, timeout=5)
            assert result.returncode == 1, (flag, value, result)
        print(f"{mode}: operation mix, version totals, epoch totals, contention and invalid CLI passed")


if __name__ == "__main__":
    main()

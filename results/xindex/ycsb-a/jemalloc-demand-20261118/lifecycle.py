"""Supplemental whole-process allocation/free/reuse check, not XIndex throughput."""
import csv
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
base = Path(__file__).resolve().parent
out = base / 'lifecycle'
out.mkdir(exist_ok=True)
for variant in ('baseline', 'candidate'):
    subprocess.run([str(root / '.tools/llvm-18.1.8/bin/clang++'), '-O3', '-std=c++17', '-pthread',
                    '-I' + str(root / 'runtime/include'), str(root / 'tests/llvm/arbiter-slab-arena-smoke.cpp'),
                    str(base / variant / 'libarbiter_runtime.a'), '-ljemalloc', '-lnuma',
                    '-o', str(out / variant)], check=True)
with (out / 'runs.csv').open('w') as stream:
    writer = csv.writer(stream)
    writer.writerow(['order', 'round', 'variant', 'node', 'wall_s', 'max_rss_kib', 'swaps'])
    index = 0
    for r in range(3):
        for node in (0, 2):
            variants = ('baseline', 'candidate') if (r + node // 2) % 2 == 0 else ('candidate', 'baseline')
            for variant in variants:
                index += 1
                stem = out / f'{index:02d}-{variant}-node{node}'
                env = {k: v for k, v in os.environ.items() if not k.startswith('ARBITER_')}
                env.update(ARBITER_HEAP_BACKEND='arena', ARBITER_ARENA_STRICT='1',
                           ARBITER_TARGET_NODE=str(node), ARBITER_EXPECT_NODE=str(node),
                           ARBITER_TEST_OBJECTS='2000000', ARBITER_TEST_THREADS='8')
                if variant == 'baseline':
                    env.update(ARBITER_ARENA_RESERVE_BYTES=str(512 << 20), ARBITER_ARENA_SLAB_BYTES=str(2 << 20))
                with stem.with_suffix('.log').open('w') as log:
                    subprocess.run(['/usr/bin/time', '-f', '%e %M %W', '-o', str(stem.with_suffix('.time')),
                                    'numactl', '--cpunodebind=0', '--membind=0', str(out / variant)],
                                   env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
                values = stem.with_suffix('.time').read_text().split()
                assert values[2] == '0'
                writer.writerow([index, r+1, variant, node, *values])
                stream.flush()
                print(index, variant, node, *values, flush=True)

#!/usr/bin/env python3
"""Paired full XIndex/YCSB-A comparison of frozen runtime executables."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = Path(__file__).resolve().parent
DATA = ROOT / 'benchmark/xindex/YCSB/xindex_dat'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--rounds', type=int, default=2)
parser.add_argument('--resume', action='store_true')
args = parser.parse_args()
assert args.rounds > 0
OUT = BASE / 'full'
OUT.mkdir(exist_ok=args.resume)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def fields(line):
    return dict(re.findall(r'(\w+)=([^\s]+)', line))

def line(log, prefix):
    matches = [s for s in log.splitlines() if s.startswith(prefix)]
    assert len(matches) == 1, (prefix, len(matches))
    return matches[0]

manifest = dict(base_commit=subprocess.check_output(['git', 'rev-parse', '9d90964'], cwd=ROOT, text=True).strip(),
                load_records=100000000, operations=400000000, fg=31, bg=1,
                cpu_node=0, ordinary_memory_node=0, memory_max='64G', swap_max=0,
                bitcode_sha256=sha(BASE / 'baseline/ycsb_bench.arbiter.bc'),
                policy='configs/hitm-seed/policy-candidates/evidence-balanced-size-tiebreaker.config',
                binaries={v: sha(BASE / v / 'ycsb_bench-arbiter') for v in ('baseline', 'candidate')},
                sources={v: sha(BASE / v / 'arbiter_jemalloc_arena.cpp') for v in ('baseline', 'candidate')})
if args.resume:
    assert json.loads((OUT / 'manifest.json').read_text()) == manifest
else:
    (OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(OUT / 'topology.txt').write_text(subprocess.check_output(['numactl', '--hardware'], text=True))
patterns = [[('baseline', 0), ('candidate', 0), ('candidate', 2), ('baseline', 2)],
            [('candidate', 0), ('baseline', 0), ('baseline', 2), ('candidate', 2)]]
order = [item for r in range(args.rounds) for item in patterns[r % 2]]
columns = ['order', 'variant', 'round', 'node', 'tx_per_s', 'timed_s', 'wall_s',
           'max_rss_kib', 'arena_resident_bytes', 'arena_assigned_bytes', 'allocations',
           'fallbacks', 'resident_pages', 'target_pages', 'zero_pages', 'query_error_pages',
           'swaps', 'executed', 'digest', 'sites']
completed = []
if args.resume:
    with (OUT / 'runs.csv').open() as stream:
        completed = list(csv.DictReader(stream))
    assert [(r['variant'], int(r['node'])) for r in completed] == order[:len(completed)]
expected_digest = completed[0]['digest'] if completed else None
expected_allocations = completed[0]['allocations'] if completed else None
with (OUT / 'runs.csv').open('a' if args.resume else 'w') as stream:
    writer = csv.DictWriter(stream, columns)
    if not completed:
        writer.writeheader()
    for index, (variant, node) in enumerate(order, 1):
        if index <= len(completed):
            continue
        stem = OUT / f'{index:02d}-{variant}-node{node}'
        env = {k: v for k, v in os.environ.items() if not k.startswith(('ARBITER_', 'XINDEX_'))}
        env.update(ARBITER_HEAP_BACKEND='arena', ARBITER_ARENA_STRICT='1',
                   ARBITER_ARENA_REPORT='1', ARBITER_TARGET_NODE=str(node),
                   ARBITER_ARENA_SLOT_ALIGNMENT='64', XINDEX_VALIDATE='1', XINDEX_VALIDATION_KEYS='4096')
        if variant == 'baseline':
            env.update(ARBITER_ARENA_RESERVE_BYTES=str(24 << 30), ARBITER_ARENA_SLAB_BYTES=str(2 << 20))
        command = ['systemd-run', '--user', '--scope', '--quiet', '-p', 'MemoryMax=64G', '-p', 'MemorySwapMax=0',
                   '/usr/bin/time', '-f', '%e %M %W', '-o', str(stem.with_suffix('.time')),
                   'numactl', '--cpunodebind=0', '--membind=0', str(BASE / variant / 'ycsb_bench-arbiter'),
                   '--fg', '31', '--bg', '1', '--iteration', '1', '--ycsb_type', 'a',
                   '--ycsb-load', str(DATA / 'xindex_load_ycsb_a.dat'),
                   '--ycsb-tx', str(DATA / 'xindex_transaction_ycsb_a.dat')]
        print(f'[{index}/{len(order)}] {variant} node{node}', flush=True)
        with stem.with_suffix('.log').open('w') as output:
            subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, check=True, timeout=600)
        log = stem.with_suffix('.log').read_text()
        summary = fields(line(log, 'arbiter-arena-summary '))
        residency = fields(line(log, 'arbiter-arena-residency '))
        validation = fields(line(log, 'xindex-state-validation '))
        executed = int(fields(line(log, 'xindex-operation-count '))['executed'])
        assert 'load number : 100000000\n' in log and executed == 400000000
        assert validation['sampled_keys'] == validation['successful_reads'] == '4096'
        assert validation['failed_reads'] == '0'
        if expected_digest is None:
            expected_digest, expected_allocations = validation['digest'], summary['allocations']
        assert validation['digest'] == expected_digest and summary['allocations'] == expected_allocations
        assert summary['node'] == str(node) and summary['fallback_allocations'] == '0'
        assert residency['query_error_pages'] == residency['mincore_error_batches'] == '0'
        assert int(residency['resident_pages']) > 0 and residency.get(f'node{node}_pages') == residency['resident_pages']
        sites = sorted(int(fields(s)['site']) for s in log.splitlines() if s.startswith('arbiter-arena-site '))
        assert sites == [68, 71, 74], sites
        wall, rss, swaps = stem.with_suffix('.time').read_text().split()
        assert swaps == '0'
        throughput = float(re.search(r'Throughput\(op/s\):\s*(\S+)', log)[1])
        row = dict(order=index, variant=variant, round=(index-1)//4+1, node=node,
                   tx_per_s=throughput, timed_s=executed/throughput, wall_s=wall, max_rss_kib=rss,
                   arena_resident_bytes=residency['resident_bytes'], arena_assigned_bytes=summary['assigned_bytes'],
                   allocations=summary['allocations'], fallbacks=summary['fallback_allocations'],
                   resident_pages=residency['resident_pages'], target_pages=residency[f'node{node}_pages'],
                   zero_pages=residency.get('zero_pages', '0'), query_error_pages=residency['query_error_pages'],
                   swaps=swaps, executed=executed, digest=validation['digest'], sites=';'.join(map(str,sites)))
        writer.writerow(row)
        stream.flush()
        print(f"  PASS {throughput/1e6:.3f} Mtx/s, RSS {int(rss)/2**20:.3f} GiB, wall {wall}s", flush=True)
        time.sleep(2)

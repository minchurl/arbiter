#!/usr/bin/env python3
"""Run matched native/Local/CXL libcuckoo binaries, retaining every raw result."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bin-dir', type=Path, default=Path('build/arbiter-bench/libcuckoo'))
    p.add_argument('--result-dir', type=Path, required=True)
    p.add_argument('--benchmark', choices=['contention', 'universal'], default='contention')
    p.add_argument('--modes', nargs='+', choices=['native', 'local', 'cxl'], default=['native', 'local', 'cxl'])
    p.add_argument('--rounds', type=int, default=3)
    p.add_argument('--threads', type=int, default=32)
    p.add_argument('--reads', type=int, default=50)
    p.add_argument('--keys', type=int, default=1048576)
    p.add_argument('--hot', type=int, default=65536)
    p.add_argument('--operations', type=int, default=1000000, help='contention operations per worker')
    p.add_argument('--partitioned', action='store_true')
    p.add_argument('--initial-capacity', type=int, default=23, help='universal capacity exponent')
    p.add_argument('--prefill', type=int, default=75)
    p.add_argument('--total-ops', type=int, default=1000, help='universal percent of initial capacity')
    p.add_argument('--seed', type=int, default=1729)
    p.add_argument('--cpu-node', type=int, default=0)
    p.add_argument('--local-node', type=int, default=0)
    p.add_argument('--cxl-node', type=int, default=2)
    p.add_argument('--timeout', type=int, default=600)
    args = p.parse_args()
    if args.rounds < 1 or args.threads < 1 or not 0 <= args.reads <= 100:
        p.error('invalid rounds/threads/reads')
    args.bin_dir = args.bin_dir.resolve()
    args.result_dir.mkdir(parents=True, exist_ok=False)
    config = {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()}
    config['binaries'] = {mode: hashlib.sha256((args.bin_dir / f'{args.benchmark}-{mode}').read_bytes()).hexdigest()
                          for mode in ['native', 'placed']}
    (args.result_dir / 'manifest.json').write_text(json.dumps(config, indent=2)+'\n')
    rows = []
    for repeat in range(1, args.rounds+1):
        # Reverse pair order every round; use the same seed within each round.
        for mode in (args.modes if repeat % 2 else list(reversed(args.modes))):
            stem = args.result_dir / f'{repeat}-{mode}'
            binary = args.bin_dir / f'{args.benchmark}-{"native" if mode=="native" else "placed"}'
            workload = ['--seed', str(args.seed+repeat-1)]
            if args.benchmark == 'contention':
                workload += ['--keys', str(args.keys), '--hot', str(args.hot), '--threads', str(args.threads),
                             '--reads', str(args.reads), '--operations', str(args.operations)]
                if args.partitioned:
                    workload += ['--partitioned']
            else:
                workload += ['--reads', str(args.reads), '--updates', str(100-args.reads),
                             '--initial-capacity', str(args.initial_capacity), '--prefill', str(args.prefill),
                             '--total-ops', str(args.total_ops), '--num-threads', str(args.threads)]
            env = dict(os.environ, ARBITER_TARGET_NODE=str(args.cxl_node if mode=='cxl' else args.local_node),
                       ARBITER_ARENA_REPORT='1')
            command = ['systemd-run', '--user', '--scope', '--quiet', '-p', 'MemoryMax=64G',
                       '-p', 'MemorySwapMax=0', '--', '/usr/bin/time', '-f', 'max_rss_kb=%M',
                       'timeout', '--kill-after=10', str(args.timeout), 'numactl', f'--cpunodebind={args.cpu_node}', f'--membind={args.local_node}', str(binary), *workload]
            stem.with_suffix('.command.json').write_text(json.dumps(command)+'\n')
            start=time.monotonic()
            with stem.with_suffix('.json').open('w') as stdout, stem.with_suffix('.stderr').open('w') as stderr:
                run=subprocess.run(command, env=env, stdout=stdout, stderr=stderr, timeout=args.timeout+30)
            if run.returncode:
                raise RuntimeError(f'{stem}: exit {run.returncode}; inspect stderr')
            data=json.loads(stem.with_suffix('.json').read_text())
            log=stem.with_suffix('.stderr').read_text()
            if args.benchmark=='contention':
                if not data['valid'] or data['failures']:
                    raise RuntimeError(f'{stem}: correctness failed')
                mops=data['mops']
            else:
                mops=data['output']['throughput']['value']/1e6
            sites=[]
            if mode!='native':
                for line in log.splitlines():
                    if line.startswith('arbiter-arena-site '):
                        sites.append(dict(re.findall(r'(\w+)=(-?\d+)',line)))
                residency=re.search(r'^arbiter-arena-residency (.*)$', log, re.M)
                if not sites or not residency:
                    raise RuntimeError(f'{stem}: no selected allocation executed / no residency evidence')
                fields=dict(re.findall(r'(\w+)=(-?\d+)',residency[1]))
                target=env['ARBITER_TARGET_NODE']
                if int(fields['resident_pages'])==0 or int(fields['query_error_pages']) or int(fields['mincore_error_batches']) or fields.get(f'node{target}_pages')!=fields['resident_pages']:
                    raise RuntimeError(f'{stem}: placement validation failed: {fields}')
                if 'fallback_allocations=0' not in log:
                    raise RuntimeError(f'{stem}: missing strict allocator evidence')
            row=dict(round=repeat,mode=mode,mops=mops,wall_seconds=round(time.monotonic()-start,3),
                     max_rss_kb=int(re.search(r'max_rss_kb=(\d+)',log)[1]),
                     sites=';'.join(s['site'] for s in sites),
                     selected_allocations=sum(int(s['allocations']) for s in sites),valid=True)
            rows.append(row)
            with (args.result_dir/'runs.csv').open('w') as stream:
                writer=csv.DictWriter(stream,fieldnames=list(row));writer.writeheader();writer.writerows(rows)
            print(json.dumps(row),flush=True)


if __name__=='__main__':
    main()

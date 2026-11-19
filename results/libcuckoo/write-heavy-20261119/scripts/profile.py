"""Sequential whole-process diagnostics, excluded from throughput comparisons."""
import json
import os
import re
import subprocess
from pathlib import Path

root = Path.cwd()
base = root / 'build/libcuckoo-write-heavy-20261119'
out = base / 'profiles'
out.mkdir(exist_ok=False)
perf = '/usr/lib/linux-hwe-6.8-tools-6.8.0-149/perf'
binary = root / 'build/libcuckoo-rmw/bench-final/contention-placed'
cases = {case['name']: case for case in json.loads((base/'cases.json').read_text())}
events = 'cycles:u,instructions:u,mem_inst_retired.lock_loads:u,mem_load_l3_hit_retired.xsnp_fwd:u,ocr.demand_rfo.l3_hit.snoop_hitm:u,ocr.demand_rfo.any_response:u'

def run(kind, hot, mode, node):
    stem = out / f'{kind}-hot{hot}-{mode}'
    count = cases[f'update100-hot{hot}']['confirmation_count']
    env = {k: v for k, v in os.environ.items() if not k.startswith(('ARBITER_', 'MALLOC_CONF', 'XINDEX_'))}
    env.update(ARBITER_TARGET_NODE=str(node), ARBITER_ARENA_REPORT='1')
    workload = ['numactl', '--cpunodebind=0', '--membind=0', str(binary), '--keys', '1048576', '--hot', str(hot), '--threads', '32', '--operations', str(count), '--reads', '0', '--seed', '440001']
    if kind == 'stat':
        instrument = [perf, 'stat', '-x,', '-o', str(stem.with_suffix('.perf.csv')), '-e', events, '--']
    else:
        instrument = [perf, 'record', '-e', 'mem_load_l3_hit_retired.xsnp_fwd:upp,mem_inst_retired.lock_loads:upp', '-c', '100003', '-d', '-m', '64', '-o', str(stem.with_suffix('.data')), '--', 'strace', '-qq', '-f', '-e', 'trace=mbind', '-o', str(stem.with_suffix('.mbind.log'))]
    command = ['systemd-run', '--user', '--scope', '--quiet', '-p', 'MemoryMax=64G', '-p', 'MemorySwapMax=0', '--', 'timeout', '--kill-after=10', '180', *instrument, *workload]
    stem.with_suffix('.command.json').write_text(json.dumps(command)+'\n')
    with stem.with_suffix('.json').open('w') as stdout, stem.with_suffix('.stderr').open('w') as stderr:
        subprocess.run(command, env=env, stdout=stdout, stderr=stderr, check=True, timeout=210)
    data = json.loads(stem.with_suffix('.json').read_text())
    assert data['valid'] and data['failures'] == 0 and data['updates'] == 32*count
    log = stem.with_suffix('.stderr').read_text()
    fields = dict(re.findall(r'(\w+)=(-?\d+)', re.search(r'arbiter-arena-residency (.*)', log)[1]))
    assert int(fields['resident_pages']) > 0
    assert fields['resident_pages'] == fields[f'node{node}_pages']
    assert fields['query_error_pages'] == fields['mincore_error_batches'] == '0'
    assert 'fallback_allocations=0' in log
    if kind == 'samples':
        with stem.with_suffix('.samples.txt').open('w') as stdout, stem.with_suffix('.decode.stderr').open('w') as stderr:
            subprocess.run([perf, 'script', '--show-lost-events', '-i', str(stem.with_suffix('.data')), '-F', 'comm,event,addr'], stdout=stdout, stderr=stderr, check=True)
    print(stem.name, data['mops'], flush=True)

for hot in [1, 65536]:
    for mode, node in [('local', 0), ('cxl', 2)]:
        run('stat', hot, mode, node)
for mode, node in [('local', 0), ('cxl', 2)]:
    run('samples', 1, mode, node)
print('PROFILES COMPLETE', flush=True)

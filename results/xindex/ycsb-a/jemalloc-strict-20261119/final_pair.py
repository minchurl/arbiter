#!/usr/bin/env python3
"""Exactly one Local/CXL full-trace pair; refuses an existing output directory."""
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
BASE = Path(__file__).resolve().parent
OUT = BASE / 'final-full'
OUT.mkdir()
DATA = ROOT / 'benchmark/xindex/YCSB/xindex_dat'
BINARY = BASE / 'final/ycsb_bench-arbiter'
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def fields(line):
    return dict(re.findall(r'(\w+)=([^\s]+)',line))
def one(log,prefix):
    matches = [s for s in log.splitlines() if s.startswith(prefix)]
    assert len(matches)==1,(prefix,len(matches))
    return fields(matches[0])
manifest = dict(started_utc=datetime.now(timezone.utc).isoformat(),
    base_commit='9d9096491b883ecf11a57b96159a9aed1f7506a3',
    load_records=100000000, operations=400000000, fg=31, bg=1,
    cpu_node=0, ordinary_memory_node=0, memory_max='64G', swap_max=0,
    order=[0,2], repeats=1, malloc_conf=os.getenv('MALLOC_CONF',''),
    binary_sha256=sha(BINARY), runtime_sha256=sha(BASE/'final/libarbiter_runtime.a'),
    input_bitcode_sha256=sha(BASE/'final/ycsb_bench.bc'),
    rewritten_bitcode_sha256=sha(BASE/'final/ycsb_bench.arbiter.bc'),
    plugin_sha256=sha(ROOT/'build/jemalloc-comparison/release/lib/ArbiterLLVMPlugin.so'),
    policy='configs/hitm-seed/policy-candidates/evidence-balanced-size-tiebreaker.config',
    source_sha256={str(p.relative_to(ROOT)):sha(p) for p in sorted((ROOT/'runtime').rglob('*')) if p.suffix in ('.cpp','.h')})
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(OUT/'topology.txt').write_text(subprocess.check_output(['numactl','--hardware'],text=True))
columns=['node','tx_per_s','wall_s','max_rss_kib','arena_resident_bytes','allocations','executed','digest','sites','fallbacks','resident_pages','target_pages','zero_pages','query_error_pages','swaps']
with (OUT/'runs.csv').open('w') as stream:
    writer=csv.DictWriter(stream,columns);writer.writeheader();stream.flush()
    for node in (0,2):
        stem=OUT/f'node{node}'
        env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','XINDEX_'))}
        env.update(ARBITER_TARGET_NODE=str(node),ARBITER_ARENA_REPORT='1',
                   ARBITER_ARENA_SLOT_ALIGNMENT='64',XINDEX_VALIDATE='1',XINDEX_VALIDATION_KEYS='4096')
        cmd=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=64G','-p','MemorySwapMax=0',
             '/usr/bin/time','-f','%e %M %W','-o',str(stem.with_suffix('.time')),
             'numactl','--cpunodebind=0','--membind=0',str(BINARY),'--fg','31','--bg','1','--iteration','1','--ycsb_type','a',
             '--ycsb-load',str(DATA/'xindex_load_ycsb_a.dat'),'--ycsb-tx',str(DATA/'xindex_transaction_ycsb_a.dat')]
        print(f'Start node{node}: one full pass',flush=True)
        with stem.with_suffix('.log').open('w') as log:
            subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=600)
        log=stem.with_suffix('.log').read_text()
        assert 'arbiter-allocation-failure' not in log
        assert 'load number : 100000000\n' in log
        op=one(log,'xindex-operation-count ');v=one(log,'xindex-state-validation ')
        s=one(log,'arbiter-arena-summary ');r=one(log,'arbiter-arena-residency ')
        assert op['executed']=='400000000' and s['allocations']=='52791182'
        assert v['digest']=='0x7474b8e9d3962859' and v['sampled_keys']==v['successful_reads']=='4096' and v['failed_reads']=='0'
        assert s['node']==str(node) and s['fallback_allocations']=='0'
        assert r['query_error_pages']==r['mincore_error_batches']=='0'
        assert int(r['resident_pages'])>0 and r['resident_pages']==r.get(f'node{node}_pages')
        sites=sorted(int(fields(line)['site']) for line in log.splitlines() if line.startswith('arbiter-arena-site '))
        assert sites==[68,71,74]
        wall,rss,swaps=stem.with_suffix('.time').read_text().split();assert swaps=='0'
        throughput=float(re.search(r'Throughput\(op/s\):\s*(\S+)',log)[1])
        writer.writerow(dict(node=node,tx_per_s=throughput,wall_s=wall,max_rss_kib=rss,
            arena_resident_bytes=r['resident_bytes'],allocations=s['allocations'],executed=op['executed'],digest=v['digest'],
            sites=';'.join(map(str,sites)),fallbacks=s['fallback_allocations'],resident_pages=r['resident_pages'],
            target_pages=r[f'node{node}_pages'],zero_pages=r.get('zero_pages','0'),query_error_pages=r['query_error_pages'],swaps=swaps))
        stream.flush()
        print(f'PASS node{node}: {throughput/1e6:.3f} M tx/s, peak RSS {int(rss)/2**20:.3f} GiB',flush=True)

"""Separate whole-process diagnostics, never used as uninstrumented timing rows."""
import json, os, re, subprocess
from pathlib import Path
root=Path.cwd();build=root/'build/libcuckoo-rmw';out=build/'lock-profiles';out.mkdir(exist_ok=False)
perf='/usr/lib/linux-hwe-6.8-tools-6.8.0-149/perf'
events='cycles:u,instructions:u,mem_inst_retired.lock_loads:u,mem_load_l3_hit_retired.xsnp_fwd:u,ocr.demand_rfo.l3_hit.snoop_hitm:u,ocr.demand_rfo.any_response:u'
def validate(stem,node):
 data=json.loads(stem.with_suffix('.json').read_text());assert data['valid'] and data['failures']==0
 log=stem.with_suffix('.stderr').read_text();match=re.search(r'arbiter-arena-residency (.*)',log);assert match
 fields=dict(re.findall(r'(\w+)=(-?\d+)',match[1]))
 assert fields['resident_pages']==fields['node'+str(node)+'_pages'] and int(fields['resident_pages'])>0
 assert fields['query_error_pages']==fields['mincore_error_batches']=='0' and 'fallback_allocations=0' in log
 return data
for variant,folder in [('baseline','bench-final'),('ttas','variant-ttas'),('ttas-padded','variant-ttas-padded')]:
 for mode,node in [('local',0),('cxl',2)]:
  stem=out/(variant+'-'+mode)
  workload=['numactl','--cpunodebind=0','--membind=0',str(build/folder/'contention-placed'),'--keys','1048576','--hot','64','--threads','32','--operations','12000000','--reads','0','--seed','53071']
  command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=64G','-p','MemorySwapMax=0','--',perf,'stat','-x,','-o',str(stem.with_suffix('.perf.csv')),'-e',events,'--',*workload]
  env=dict(os.environ,ARBITER_TARGET_NODE=str(node),ARBITER_ARENA_REPORT='1')
  stem.with_suffix('.command.json').write_text(json.dumps(command)+'\n')
  with stem.with_suffix('.json').open('w') as stdout,stem.with_suffix('.stderr').open('w') as stderr:
   subprocess.run(command,env=env,stdout=stdout,stderr=stderr,check=True,timeout=180)
  data=validate(stem,node)
  print(variant,mode,data['mops'],flush=True)
# Sample baseline and TTAS addresses; record all mbind ranges.
for variant,folder in [('baseline','bench-final'),('ttas','variant-ttas')]:
 for mode,node in [('local',0),('cxl',2)]:
  stem=out/('samples-'+variant+'-'+mode)
  workload=['strace','-qq','-f','-e','trace=mbind','-o',str(stem.with_suffix('.mbind.log')),'numactl','--cpunodebind=0','--membind=0',str(build/folder/'contention-placed'),'--keys','1048576','--hot','64','--threads','32','--operations','12000000','--reads','0','--seed','53072']
  command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=64G','-p','MemorySwapMax=0','--',perf,'record','-e','mem_load_l3_hit_retired.xsnp_fwd:upp,mem_inst_retired.lock_loads:upp','-c','100003','-d','-m','64','-o',str(stem.with_suffix('.data')),'--',*workload]
  env=dict(os.environ,ARBITER_TARGET_NODE=str(node),ARBITER_ARENA_REPORT='1')
  stem.with_suffix('.command.json').write_text(json.dumps(command)+'\n')
  with stem.with_suffix('.json').open('w') as stdout,stem.with_suffix('.stderr').open('w') as stderr:
   subprocess.run(command,env=env,stdout=stdout,stderr=stderr,check=True,timeout=180)
  data=validate(stem,node)
  with stem.with_suffix('.samples.txt').open('w') as stdout,stem.with_suffix('.decode.stderr').open('w') as stderr:
   subprocess.run([perf,'script','--show-lost-events','-i',str(stem.with_suffix('.data')),'-F','comm,event,addr'],stdout=stdout,stderr=stderr,check=True)
  print('samples',mode,flush=True)

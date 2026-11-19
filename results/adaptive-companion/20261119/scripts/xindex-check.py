"""One full old/new CXL pair: correctness/regression diagnostic, not a speedup claim."""
import csv,hashlib,json,os,re,subprocess,time
from pathlib import Path
from host_guard import snapshot,foreign,wait_quiet
root=Path.cwd();base=root/'build/adaptive-companion';out=base/'xindex-check';out.mkdir(exist_ok=False);rows=[];waits=[]
for label,binary in [('prior',root/'build/budgeted-companion/xindex/seed'),('current',base/'xindex/adaptive')]:
 for attempt in range(1,5):
  wait_quiet(waits);stem=out/f'{label}-attempt{attempt}'
  env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','XINDEX_','MALLOC_CONF'))};env.update(ARBITER_TARGET_NODE='2',ARBITER_ARENA_REPORT='1',XINDEX_VALIDATE='1',LD_LIBRARY_PATH='/opt/intel/oneapi/mkl/latest/lib:'+env.get('LD_LIBRARY_PATH',''))
  command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=64G','-p','MemorySwapMax=0','--','/usr/bin/time','-f','%M %W','-o',str(stem.with_suffix('.time')),'timeout','900','numactl','--cpunodebind=0','--membind=0',str(binary),'--fg','31','--bg','1','--iteration','1','--ycsb_type','a','--ycsb-load',str(root/'benchmark/xindex/YCSB/xindex_dat/xindex_load_ycsb_a.dat'),'--ycsb-tx',str(root/'benchmark/xindex/YCSB/xindex_dat/xindex_transaction_ycsb_a.dat')]
  stem.with_suffix('.command.json').write_text(json.dumps(dict(command=command,environment={k:v for k,v in env.items() if k.startswith(('ARBITER_','XINDEX_','LD_LIBRARY'))},binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest()),indent=2)+'\n')
  before=snapshot();busy=[];begin=time.monotonic()
  with stem.with_suffix('.log').open('w') as f:
   process=subprocess.Popen(command,env=env,stdout=f,stderr=subprocess.STDOUT)
   while process.poll() is None:time.sleep(.5);after=snapshot();busy+=foreign(before,after,process.pid);before=after
  wall=time.monotonic()-begin;text=stem.with_suffix('.log').read_text()
  stem.with_suffix('.host.json').write_text(json.dumps(busy,indent=2)+'\n')
  assert process.returncode==0 and 'executed=400000000' in text and 'digest=0x7474b8e9d3962859' in text
  assert 'fallback_allocations=0' in text and 'query_error_pages=0' in text and 'arbiter-adaptive ' not in text
  rss,swaps=map(int,stem.with_suffix('.time').read_text().split());assert swaps==0
  if busy:continue
  seconds=float(re.search(r'Time\(sec\) : ([\d.]+)',text)[1]);rows.append(dict(mode=label,attempt=attempt,ops=400000000,seconds=seconds,mops=400/seconds,wall_seconds=wall,rss_kib=rss,valid=True));print('XINDEX',label,400/seconds,flush=True);break
 else:raise RuntimeError('Repeated interference')
with (out/'runs.csv').open('w') as f:w=csv.DictWriter(f,fieldnames=list(rows[0]),lineterminator='\n');w.writeheader();w.writerows(rows)
(out/'host-waits.json').write_text(json.dumps(waits,indent=2)+'\n')

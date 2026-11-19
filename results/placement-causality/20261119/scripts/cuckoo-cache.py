"""Five-second cache counters after prefill, while all workers remain active."""
import csv,hashlib,json,os,re,signal,subprocess,time
from pathlib import Path
root=Path.cwd();base=root/'build/xindex-contention-cause-20261119';out=base/'cuckoo-cache';out.mkdir(exist_ok=False)
binary=(root/'build/libcuckoo-rmw/bench-final/contention-placed').resolve();perf='/usr/lib/linux-hwe-6.8-tools-6.8.0-149/perf'
events='cycles:u,instructions:u,mem_inst_retired.all_loads:u,mem_load_retired.l3_miss:u,mem_inst_retired.lock_loads:u'

def target_pid(pid):
 try:
  if Path('/proc',str(pid),'exe').resolve()==binary:return pid
  for child in Path('/proc',str(pid),'task',str(pid),'children').read_text().split():
   match=target_pid(int(child))
   if match:return match
 except FileNotFoundError:pass
 return None

for hot,count in [(1,2000000),(64,12000000),(65536,188100000)]:
 for mode,node in [('local',0),('cxl',2)]:
  stem=out/f'hot{hot}-{mode}';env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','MALLOC_CONF','XINDEX_'))}
  env.update(ARBITER_TARGET_NODE=str(node),ARBITER_ARENA_REPORT='1')
  command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=64G','-p','MemorySwapMax=0','--','timeout','--kill-after=10','180','numactl','--cpunodebind=0','--membind=0',str(binary),'--keys','1048576','--hot',str(hot),'--threads','32','--operations',str(count),'--reads','0','--seed','480001']
  manifest=dict(command=command,binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),hot=hot,node=node,mode=mode,operations_per_worker=count,scope='Five-second diagnostic hot-workload window after prefill and one-second warmup. Ratios use counters from the same window; no assumed exact logical-operation denominator.')
  with stem.with_suffix('.json').open('w') as stdout,stem.with_suffix('.stderr').open('w') as stderr:
   proc=subprocess.Popen(command,env=env,stdout=stdout,stderr=stderr,start_new_session=True)
   try:
    pid=None;start=time.monotonic()
    while proc.poll() is None and not pid and time.monotonic()-start<10:pid=target_pid(proc.pid);time.sleep(.005)
    assert pid
    while len(list(Path(f'/proc/{pid}/task').iterdir()))<33:
     assert proc.poll() is None and time.monotonic()-start<30;time.sleep(.002)
    time.sleep(1)
    before=len(list(Path(f'/proc/{pid}/task').iterdir()));assert before==33
    stat=[perf,'stat','-p',str(pid),'--timeout','5000','-x,','-e',events,'-o',str(stem.with_suffix('.perf.csv'))]
    manifest.update(pid=pid,stat_command=stat,window_start_monotonic=time.monotonic(),threads_before=before)
    subprocess.run(stat,stdout=subprocess.DEVNULL,stderr=stderr,check=True)
    after=len(list(Path(f'/proc/{pid}/task').iterdir()));manifest.update(window_end_monotonic=time.monotonic(),threads_after=after,all_workers_active=(after==33))
    proc.wait(timeout=180);assert proc.returncode==0
   finally:
    if proc.poll() is None:
     os.killpg(proc.pid,signal.SIGTERM);proc.wait(timeout=15)
  data=json.loads(stem.with_suffix('.json').read_text());log=stem.with_suffix('.stderr').read_text()
  assert data['valid'] and data['updates']==data['value_sum']==count*32 and data['failures']==0
  fields=dict(re.findall(r'(\w+)=(-?\d+)',re.search(r'arbiter-arena-residency (.*)',log)[1]));assert fields['resident_pages']==fields[f'node{node}_pages'] and fields['query_error_pages']==fields['mincore_error_batches']=='0' and 'fallback_allocations=0' in log
  counters={}
  for row in csv.reader(stem.with_suffix('.perf.csv').open()):
   if len(row)>=5 and row[2] in events.split(','):
    assert float(row[4])>99.5,(stem,row);counters[row[2]]=float(row[0])
  assert len(counters)==5
  manifest.update(valid=True,counters=counters,llc_misses_per_1000_loads=1000*counters['mem_load_retired.l3_miss:u']/counters['mem_inst_retired.all_loads:u'])
  stem.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
  print(stem.name,'LLC misses/1000 loads',manifest['llc_misses_per_1000_loads'],'all_workers',manifest['all_workers_active'],flush=True)

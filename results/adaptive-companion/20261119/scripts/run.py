"""Benchmark arguments belong to evaluation only; the controller never reads them."""
import argparse,csv,hashlib,json,os,re,signal,subprocess,time
from pathlib import Path
from host_guard import snapshot,foreign,wait_quiet,POLICY
root=Path.cwd();base=root/'build/adaptive-companion'
p=argparse.ArgumentParser();p.add_argument('case');p.add_argument('--table',type=int,default=16);p.add_argument('--reads',type=int,default=50);p.add_argument('--seconds',type=int,default=120);p.add_argument('--rounds',type=int,default=1);p.add_argument('--modes',nargs='+',default=['plain','observe','adapt']);p.add_argument('--phase-after',type=float,default=0);args=p.parse_args()
out=base/args.case;out.mkdir(exist_ok=False);rows=[];guard=[]
variant=json.loads((base/'variants.json').read_text())['records']['micro']
(out/'manifest.json').write_text(json.dumps(dict(args=vars(args),variant=variant,guard=POLICY,shutdown_validation='Live migrations require zero failures/missing/mismatch. Cancelled atexit migrations are recorded separately, may meet purged pages, must stay within budget, and require valid final progress/results.',measurement='Total benchmark throughput includes online exploration, migration, monitoring and rollback. No debugger and no benchmark source changes.'),indent=2)+'\n')
def target(parent,binary):
 try:
  if Path(f'/proc/{parent}/exe').resolve()==binary:return parent
  for child in Path(f'/proc/{parent}/task/{parent}/children').read_text().split():
   found=target(int(child),binary)
   if found:return found
 except (FileNotFoundError,ProcessLookupError):pass
 return None
for repeat in range(1,args.rounds+1):
 for mode in (args.modes if repeat%2 else list(reversed(args.modes))):
  for attempt in range(1,5):
   wait_quiet(guard);stem=out/f'{repeat}-{mode}-attempt{attempt}'
   binary=Path(variant['plain']['path'] if mode=='plain' else variant['binary'])
   expected=variant['plain']['sha256'] if mode=='plain' else variant['binary_sha256']
   assert hashlib.sha256(binary.read_bytes()).hexdigest()==expected
   env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','XINDEX_','MALLOC_CONF'))}
   env.update(ARBITER_TARGET_NODE='2',ARBITER_ARENA_REPORT='1')
   if mode=='plain':env['ARBITER_EXPERIMENT_PLAN']=str(base/'micro/local.plan')
   else:env['ARBITER_ADAPTIVE_MODE']=mode
   command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=16G','-p','MemorySwapMax=0','--','/usr/bin/time','-f','%M %W','-o',str(stem.with_suffix('.time')),'timeout','--kill-after=10',str(args.seconds+90),'numactl','--cpunodebind=0','--membind=0',str(binary),'--victims','32','--noise','0','--mode','none','--duration',str(args.seconds),'--table-size',str(args.table),'--ballast-mb','8192','--read-pct',str(args.reads)]
   stem.with_suffix('.command.json').write_text(json.dumps(dict(command=command,environment={k:v for k,v in env.items() if k.startswith('ARBITER_')},binary_sha256=expected),indent=2)+'\n')
   begin=time.monotonic();last=snapshot();busy=[];shifted=None;benchmark_pid=None
   with stem.with_suffix('.log').open('w') as log:
    process=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:
     while process.poll() is None:
      time.sleep(.5);now=snapshot();busy+=foreign(last,now,process.pid);last=now
      if args.phase_after and not shifted and time.monotonic()-begin>args.phase_after:
       benchmark_pid=target(process.pid,binary)
       if benchmark_pid:
        tids=[int(x.name) for x in Path(f'/proc/{benchmark_pid}/task').iterdir()]
        for tid in tids:os.sched_setaffinity(tid,set(range(8)))
        shifted=dict(time_since_launch=time.monotonic()-begin,tids=tids,cpus=list(range(8)))
     process.wait()
    finally:
     if process.poll() is None:os.killpg(process.pid,signal.SIGTERM);process.wait(timeout=15)
   wall=time.monotonic()-begin;text=stem.with_suffix('.log').read_text()
   stem.with_suffix('.host.json').write_text(json.dumps(dict(busy=busy,affinity_change=shifted),indent=2)+'\n')
   (out/'host-waits.json').write_text(json.dumps(guard,indent=2)+'\n')
   assert process.returncode==0,(stem,text[-3000:])
   assert 'status=ok' in text and 'fallback_allocations=0' in text
   assert 'query_error_pages=0' in text and 'mincore_error_batches=0' in text
   ops=int(re.search(r'total_ops=(\d+)',text)[1]);seconds=float(re.search(r'elapsed=([\d.]+)',text)[1])
   val=dict(re.findall(r'(\w+)=([^\s]+)',re.search(r'validation: (.*)',text)[1]));assert int(val['reads'])+int(val['writes'])==ops and val['writes']==val['versions']
   events=[json.loads(line[len('arbiter-adaptive '):]) for line in text.splitlines() if line.startswith('arbiter-adaptive ')]
   if mode!='plain':
    end=[e for e in events if e['event']=='finish'];assert len(end)==1 and end[0]['progress']==ops and end[0].get('active_sources',end[0].get('workers'))==32 and not end[0].get('invalid_progress'),end
   migrations=[e for e in events if e['event']=='migration']
   for e in migrations:
    assert e['target_pages']*4096<=e['budget_bytes'],e
    if e.get('cancelled'):
     assert end[0]['time']>=e['time'] and 'frees=2 live=0' in text,e
    else:assert e['failed']==e['mismatch']==e['missing']==0,e
   assert not any('fail' in e.get('action','') or 'exception' in e['event'] for e in events),events
   stem.with_suffix('.events.json').write_text(json.dumps(events,indent=2)+'\n')
   rss,swaps=map(int,stem.with_suffix('.time').read_text().split());assert swaps==0
   if busy:print('REJECT',args.case,mode,flush=True);continue
   decisions=[e for e in events if e['event']=='decision'];holds=[e for e in decisions if e['action']=='hold']
   row=dict(round=repeat,mode=mode,attempt=attempt,ops=ops,seconds=seconds,mops=ops/seconds/1e6,wall_seconds=wall,rss_kib=rss,migration_seconds=sum(e['seconds'] for e in migrations),migration_count=len(migrations),chosen_bp=holds[-1]['ratio_bp'] if holds else 0,last_target_pages=migrations[-1]['target_pages'] if migrations else 0,valid=True)
   rows.append(row)
   with (out/'runs.csv').open('w') as f:w=csv.DictWriter(f,fieldnames=list(row),lineterminator='\n');w.writeheader();w.writerows(rows)
   print(args.case,repeat,mode,round(row['mops'],3),'Mops/s',[(e['action'],e['ratio_bp']) for e in decisions],flush=True);break
  else:raise RuntimeError('Repeated host interference')
print('CASE FINISHED',args.case,flush=True)

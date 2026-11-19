"""Untraced first-touch placement comparisons; no benchmark edits or migration."""
import argparse,csv,hashlib,json,os,re,signal,struct,subprocess,time
from pathlib import Path
from host_guard import snapshot,foreign,wait_quiet,POLICY
root=Path.cwd();base=root/'build/budgeted-companion'
p=argparse.ArgumentParser();p.add_argument('case');p.add_argument('--workload',choices=['micro','xindex'],default='micro');p.add_argument('--table',type=int,default=16);p.add_argument('--threads',type=int,default=32);p.add_argument('--reads',type=int,default=50);p.add_argument('--seconds',type=int,default=20);p.add_argument('--rounds',type=int,default=2);p.add_argument('--strategies',nargs='+',default=['original','seed','local','half','cap1g','cap4g','full']);args=p.parse_args()
out=base/args.case;out.mkdir(exist_ok=False)
variant=json.loads((base/'variants.json').read_text())['records'][args.workload]
policies={'local':(0,0),'half':(50,2**64-1),'cap1g':(100,1024**3),'cap4g':(100,4*1024**3),'full':(100,2**64-1)}
manifest=dict(args=vars(args),variant=variant,policy=policies,cap_scope='Finite budgets divided equally across automatically discovered companion sites; all selected seed sites retain their original policy.',measurement='Untraced benchmark, no page migration. Live NUMA VMAs checked after initialization; full per-page checks are separate diagnostics. '+POLICY)
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
rows=[];guard=[];symbol_cache={}
def find_target(parent,binary):
    try:
        if Path(f'/proc/{parent}/exe').resolve()==binary:return parent
        for child in Path(f'/proc/{parent}/task/{parent}/children').read_text().split():
            found=find_target(int(child),binary)
            if found:return found
    except (FileNotFoundError,ProcessLookupError):pass
    return None
def live(process,binary,stem):
    if binary not in symbol_cache:
        text=subprocess.check_output(['nm',str(binary)],text=True)
        symbol_cache[binary]={name:int(re.search(r'^([0-9a-f]+) \w '+re.escape(name)+r'$',text,re.M)[1],16) for name in ['_ZL7g_start.0','_ZL7g_table','_ZL9g_ballast']}
    pid=find_target(process.pid,binary)
    if not pid:return False
    maps=Path(f'/proc/{pid}/maps').read_text();load=int(next(line for line in maps.splitlines() if str(binary) in line and line.split()[2]=='00000000').split('-')[0],16)
    fd=os.open(f'/proc/{pid}/mem',os.O_RDONLY)
    try:
        if not os.pread(fd,1,load+symbol_cache[binary]['_ZL7g_start.0'])[0]:return False
        pointers={name:struct.unpack('<Q',os.pread(fd,8,load+symbol_cache[binary][symbol]))[0] for name,symbol in [('table','_ZL7g_table'),('ballast','_ZL9g_ballast')]}
    finally:os.close(fd)
    maps=Path(f'/proc/{pid}/maps').read_text();numa=Path(f'/proc/{pid}/numa_maps').read_text();smaps=Path(f'/proc/{pid}/smaps_rollup').read_text()
    assert re.search(r'AnonHugePages:\s+0 kB',smaps) and re.search(r'Swap:\s+0 kB',smaps)
    by={int(line.split()[0],16):line for line in numa.splitlines()};objects={}
    for name,bytes in [('table',args.table*64),('ballast',8*1024**3)]:
        addr=pointers[name];regions=[];covered=0;counts={}
        for line in maps.splitlines():
            start,end=map(lambda x:int(x,16),line.split()[0].split('-'))
            if end<=addr or start>=addr+bytes:continue
            covered+=min(end,addr+bytes)-max(start,addr)
            ns={int(k):int(v) for k,v in re.findall(r'\bN(\d+)=(\d+)',by[start])}
            for k,v in ns.items():counts[k]=counts.get(k,0)+v
            regions.append(dict(mapping=line,numa=by[start]))
        assert covered==bytes and set(counts)<={0,2} and sum(counts.values())*4096>=bytes
        objects[name]=dict(address=hex(addr),bytes=bytes,containing_vma_pages=counts,regions=regions)
    stem.with_suffix('.live.json').write_text(json.dumps(dict(pid=pid,objects=objects,note='Containing VMAs include boundary/allocator pages; these are not exact per-object page counts.'),indent=2)+'\n')
    stem.with_suffix('.smaps').write_text(smaps)
    return True
for repeat in range(1,args.rounds+1):
    order=args.strategies if repeat%2 else list(reversed(args.strategies))
    for strategy in order:
        assert strategy in policies or strategy in ['original','seed','seed-local']
        binary=Path(variant['original_binary'] if strategy=='original' else variant['binaries']['seed' if strategy.startswith('seed') else 'expanded']['path']).resolve()
        expected_hash=json.loads((base/'manifest.json').read_text())['files'][str(binary.relative_to(root))] if strategy=='original' else variant['binaries']['seed' if strategy.startswith('seed') else 'expanded']['sha256']
        node=0 if strategy=='seed-local' else 2
        for attempt in range(1,11):
            wait_quiet(guard)
            stem=out/f'{repeat}-{strategy}-attempt{attempt}'
            env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','XINDEX_','MALLOC_CONF'))}
            env.update(ARBITER_TARGET_NODE=str(node),ARBITER_ARENA_REPORT='1',XINDEX_VALIDATE='1',LD_LIBRARY_PATH='/opt/intel/oneapi/mkl/latest/lib:'+env.get('LD_LIBRARY_PATH',''))
            if strategy in policies:
                percent,cap=policies[strategy];per_site=cap if cap==2**64-1 else cap//max(1,len(variant['companions']))
                plan=stem.with_suffix('.plan');plan.write_text(''.join(f'{site} 0 {percent} {per_site}\n' for site in variant['companions']))
                env['ARBITER_EXPERIMENT_PLAN']=str(plan)
            if args.workload=='micro':workload=['--victims',str(args.threads),'--noise','0','--mode','none','--duration',str(args.seconds),'--table-size',str(args.table),'--ballast-mb','8192','--read-pct',str(args.reads)]
            else:workload=['--fg','31','--bg','1','--iteration','1','--ycsb_type','a','--ycsb-load',str(root/'benchmark/xindex/YCSB/xindex_dat/xindex_load_ycsb_a.dat'),'--ycsb-tx',str(root/'benchmark/xindex/YCSB/xindex_dat/xindex_transaction_ycsb_a.dat')]
            command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=64G','-p','MemorySwapMax=0','--','/usr/bin/time','-f','%M %W','-o',str(stem.with_suffix('.time')),'timeout','--kill-after=10','900','numactl','--cpunodebind=0','--membind=0',str(binary),*workload]
            binary_hash=hashlib.sha256(binary.read_bytes()).hexdigest();assert binary_hash==expected_hash,'Benchmark binary changed'
            stem.with_suffix('.command.json').write_text(json.dumps(dict(command=command,environment={k:v for k,v in env.items() if k.startswith(('ARBITER_','XINDEX_','LD_LIBRARY'))},binary_sha256=binary_hash),indent=2)+'\n')
            start=time.monotonic();before=snapshot();busy=[];observed=args.workload!='micro'
            with stem.with_suffix('.log').open('w') as f:
                process=subprocess.Popen(command,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
                try:
                    while process.poll() is None:
                        time.sleep(.5);after=snapshot();busy+=foreign(before,after,process.pid);before=after
                        if not observed and process.poll() is None:observed=live(process,binary,stem)
                    process.wait()
                finally:
                    if process.poll() is None:os.killpg(process.pid,signal.SIGTERM);process.wait(timeout=15)
            stem.with_suffix('.host.json').write_text(json.dumps(dict(contaminated=bool(busy),processes=busy),indent=2)+'\n')
            (out/'host-waits.json').write_text(json.dumps(guard,indent=2)+'\n')
            log=stem.with_suffix('.log').read_text();assert process.returncode==0 and observed,(stem,log[-2500:])
            assert 'fallback_allocations=0' in log and 'query_error_pages=0' in log and 'mincore_error_batches=0' in log
            if args.workload=='micro':
                assert 'status=ok' in log
                ops=int(re.search(r'total_ops=(\d+)',log)[1]);seconds=float(re.search(r'elapsed=([\d.]+)',log)[1])
                val=dict(re.findall(r'(\w+)=([^\s]+)',re.search(r'validation: (.*)',log)[1]));assert int(val['reads'])+int(val['writes'])==ops and val['writes']==val['versions']
            else:
                ops=int(re.search(r'xindex-operation-count executed=(\d+)',log)[1]);seconds=float(re.search(r'Time\(sec\) : ([\d.]+)',log)[1]);assert ops==400000000 and 'digest=0x7474b8e9d3962859' in log
            plans=[]
            for line in log.splitlines():
                if line.startswith('arbiter-placement-site '):
                    r={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)};assert r['target_assigned_bytes']<=r['target_limit_bytes'];plans.append(r)
            if strategy in policies:
                assert {r['site'] for r in plans}<=set(variant['companions'])
                if args.workload=='micro':assert {r['site'] for r in plans}==set(variant['companions'])
                if cap!=2**64-1:assert sum(r['target_assigned_bytes'] for r in plans)<=cap
            rss,swaps=map(int,stem.with_suffix('.time').read_text().split());assert swaps==0
            if busy:
                print('REJECT concurrent load',args.case,repeat,strategy,flush=True);continue
            row=dict(round=repeat,strategy=strategy,node=node,attempt=attempt,ops=ops,seconds=seconds,mops=ops/seconds/1e6,wall_seconds=time.monotonic()-start,rss_kib=rss,target_assigned_bytes=sum(r['target_assigned_bytes'] for r in plans),valid=True)
            rows.append(row)
            with (out/'runs.csv').open('w') as f:w=csv.DictWriter(f,fieldnames=list(row),lineterminator='\n');w.writeheader();w.writerows(rows)
            print(args.case,repeat,strategy,round(row['mops'],3),'Mops/s',flush=True)
            break
        else:raise RuntimeError('Too many contaminated attempts; no result accepted')

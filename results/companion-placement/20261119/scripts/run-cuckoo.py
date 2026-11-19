"""Lock/bucket placement, frozen allocation-only variants and identical input."""
import argparse,csv,hashlib,json,os,re,signal,subprocess,time
from pathlib import Path
root=Path.cwd();base=root/'build/companion-placement'
p=argparse.ArgumentParser();p.add_argument('name');p.add_argument('--rounds',type=int,default=2);p.add_argument('--keys',type=int,default=1048576);p.add_argument('--hot',type=int,default=65536);p.add_argument('--threads',type=int,default=32);p.add_argument('--reads',type=int,default=0);p.add_argument('--operations',type=int,default=16000000);p.add_argument('--variants',nargs='+',default=['lock','bucket','both']);p.add_argument('--nodes',type=int,nargs='+',default=[0,2]);p.add_argument('--plain',action='store_true');args=p.parse_args()
out=base/args.name;out.mkdir(exist_ok=False)
manifest=dict(args=vars(args),binaries={name:hashlib.sha256((base/name/'binary').read_bytes()).hexdigest() for name in args.variants},method='Existing site overrides: lock 26, initial bucket 13. GDB snapshot after timer and worker join, before validation/deallocation. No timed breakpoints; strict NUMA binding applies for the full allocation lifetime.')
if args.plain:manifest['method']='Untraced benchmark. External NUMA snapshot once all workers exist; strict NUMA binding and allocation counts independently checked. No debugger or instruction instrumentation.'
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
rows=[]
choices=[(v,n) for v in args.variants for n in args.nodes]
for repeat in range(1,args.rounds+1):
    order=choices if repeat%2 else list(reversed(choices))
    for variant,node in order:
        stem=out/f'{repeat}-{variant}-node{node}';binary=base/variant/'binary'
        env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','MALLOC_CONF'))}
        env.update(ARBITER_TARGET_NODE=str(node),ARBITER_ARENA_REPORT='1')
        commands=['set pagination off','set confirm off','set print thread-events off','set disable-randomization off','break contention.cpp:111','run','python','import gdb','from pathlib import Path','pid=gdb.selected_inferior().pid']
        for name in ['maps','numa_maps']:
            commands += [f"Path({str(stem.with_suffix('.'+name))!r}).write_text(Path('/proc',str(pid),{name!r}).read_text())"]
        commands += ['end','delete breakpoints','continue']
        gdbfile=stem.with_suffix('.gdb');gdbfile.write_text('\n'.join(commands)+'\n')
        workload=['--keys',str(args.keys),'--hot',str(args.hot),'--threads',str(args.threads),'--reads',str(args.reads),'--operations',str(args.operations),'--seed',str(1728+repeat)]
        launch=[str(binary),*workload] if args.plain else ['gdb','-nx','-q','-batch','-x',str(gdbfile),'--args',str(binary),*workload]
        command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=64G','-p','MemorySwapMax=0','--','/usr/bin/time','-f','%M %W','-o',str(stem.with_suffix('.time')),'timeout','--kill-after=10','300','numactl','--cpunodebind=0','--membind=0',*launch]
        stem.with_suffix('.command.json').write_text(json.dumps(dict(command=command,env={k:env[k] for k in ['ARBITER_TARGET_NODE','ARBITER_ARENA_REPORT']}),indent=2)+'\n')
        start=time.monotonic()
        with stem.with_suffix('.log').open('w') as f:
            if not args.plain:run=subprocess.run(command,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=320)
            else:
                run=subprocess.Popen(command,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
                def target(parent):
                    try:
                        if Path(f'/proc/{parent}/exe').resolve()==binary:return parent
                        for child in Path(f'/proc/{parent}/task/{parent}/children').read_text().split():
                            found=target(int(child))
                            if found:return found
                    except (FileNotFoundError,ProcessLookupError):pass
                    return None
                try:
                    pid=None
                    while not pid and run.poll() is None and time.monotonic()-start<30:
                        pid=target(run.pid);time.sleep(.005)
                    assert pid,'Benchmark descendant missing'
                    while len(list(Path(f'/proc/{pid}/task').iterdir()))<args.threads+1:
                        assert run.poll() is None and time.monotonic()-start<60
                        time.sleep(.001)
                    for name in ['maps','numa_maps']:
                        stem.with_suffix('.'+name).write_text(Path(f'/proc/{pid}/{name}').read_text())
                    run.wait(timeout=320)
                finally:
                    if run.poll() is None:
                        os.killpg(run.pid,signal.SIGTERM);run.wait(timeout=15)
        log=stem.with_suffix('.log').read_text()
        assert run.returncode==0 and (args.plain or 'exited normally' in log),(stem,log[-1500:])
        data=json.loads(next(line for line in log.splitlines() if line.startswith('{"keys":')))
        assert data['valid'] and not data['failures'] and data['value_sum']==data['updates']
        assert data['reads']+data['updates']==args.threads*args.operations
        sites=[dict(re.findall(r'(\w+)=(-?\d+)',line)) for line in log.splitlines() if line.startswith('arbiter-arena-site ')]
        wanted={'lock':{26},'bucket':{13},'both':{13,26}}[variant]
        assert {int(s['site']) for s in sites}==wanted and all(int(s['allocations'])==1 for s in sites),(stem,sites)
        for s in sites:
            assert int(s['object_bytes'])==(4194304 if s['site']=='26' else 72*(1<<(args.keys*2-1).bit_length())//4),(stem,s)
        assert 'fallback_allocations=0' in log
        lines=stem.with_suffix('.numa_maps').read_text().splitlines()
        selected=[line for line in lines if f'bind:{node} ' in line and 'anon=' in line]
        for line in selected:
            counts={int(k):int(v) for k,v in re.findall(r'\bN(\d+)=(\d+)',line)}
            assert set(counts)<={node},(stem,line)
        total_pages=sum(sum(int(v) for _,v in re.findall(r'\bN(\d+)=(\d+)',line)) for line in selected)
        assert total_pages*4096>=sum(int(s['object_bytes']) for s in sites),(stem,total_pages,sites)
        rss,swaps=map(int,stem.with_suffix('.time').read_text().split());assert swaps==0
        row=dict(round=repeat,variant=variant,node=node,mops=data['mops'],seconds=data['seconds'],reads=data['reads'],writes=data['updates'],live_bound_pages=total_pages,rss_kib=rss,wall_seconds=time.monotonic()-start,valid=True)
        rows.append(row)
        with (out/'runs.csv').open('w') as f:w=csv.DictWriter(f,fieldnames=list(row));w.writeheader();w.writerows(rows)
        print(args.name,repeat,variant,node,round(row['mops'],3),flush=True)

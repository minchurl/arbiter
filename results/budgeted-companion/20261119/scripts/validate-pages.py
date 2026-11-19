"""Separate physical-placement diagnostics; excluded from throughput results."""
import json,os,re,subprocess,sys
from pathlib import Path
from host_guard import wait_quiet
base=Path('build/budgeted-companion').resolve();out=base/'page-validation';out.mkdir(exist_ok=False)
binary=base/'micro/expanded';waits=[];summary=[]
companions=json.loads((base/'variants.json').read_text())['records']['micro']['companions']
assert len(companions)==1
for strategy,percent,cap in [('local',0,0),('half',50,2**64-1),('cap1g',100,1024**3),('cap4g',100,4*1024**3)]:
    wait_quiet(waits);stem=out/strategy
    plan=stem.with_suffix('.plan');plan.write_text(f'{companions[0]} 0 {percent} {cap}\n')
    env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','MALLOC_CONF'))};env.update(ARBITER_TARGET_NODE='2',ARBITER_ARENA_REPORT='1',ARBITER_EXPERIMENT_PLAN=str(plan))
    commands=['set pagination off','set confirm off','set print thread-events off','set disable-randomization off','break coherence_noise.cpp:338','run']
    def query(phase):
        args=[str(base/'scripts/query-pages.py'),'PID',str(binary),str(stem),phase]
        return ['python','import gdb,runpy,sys','sys.argv='+repr(args),"sys.argv[1]=str(gdb.selected_inferior().pid)","runpy.run_path(sys.argv[0],run_name='__main__')",'end']
    commands+=query('before')+['delete breakpoints','break coherence_noise.cpp:413','continue']+query('after')+['delete breakpoints','continue']
    gdb=stem.with_suffix('.gdb');gdb.write_text('\n'.join(commands)+'\n')
    command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=64G','-p','MemorySwapMax=0','--','timeout','240','numactl','--cpunodebind=0','--membind=0','gdb','-nx','-q','-batch','-x',str(gdb),'--args',str(binary),'--victims','32','--noise','0','--mode','none','--duration','30','--table-size','16','--ballast-mb','8192','--read-pct','50']
    stem.with_suffix('.command.json').write_text(json.dumps(dict(command=command,environment={k:v for k,v in env.items() if k.startswith('ARBITER_')}),indent=2)+'\n')
    with stem.with_suffix('.log').open('w') as f:subprocess.run(command,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
    log=stem.with_suffix('.log').read_text();assert 'status=ok' in log and 'exited normally' in log and 'Traceback' not in log
    d=json.loads(stem.with_suffix('.after.json').read_text())
    assert set(d['objects']['table']['nodes'])=={'2'}
    ballast=d['objects']['ballast'];remote=ballast['nodes'].get('2',0)
    if strategy=='half':assert abs(remote/ballast['pages']-.5)<.00001
    elif strategy=='local':assert remote==0
    else:assert 0<remote*4096<=cap
    assigned=int(re.search(r'target_assigned_bytes=(\d+)',log)[1]);assert assigned<=cap
    summary.append(dict(strategy=strategy,objects=d['objects'],target_limit_bytes=cap,target_assigned_bytes=assigned,unchanged_before_after=True,note='All 4 KiB pages intersecting each object, including partial boundary pages. Query-only diagnostics, excluded from performance results.'))
    print(strategy,ballast['nodes'],'PASS unchanged before/after',flush=True)
(out/'waits.json').write_text(json.dumps(waits,indent=2)+'\n')
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')

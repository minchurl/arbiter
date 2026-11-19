"""Untraced, same-process ballast crossover using existing progress counters.

The benchmark already publishes one epoch per completed operation. Read-only
snapshots provide phase throughput without changing its code or contents.
"""
import argparse,collections,csv,ctypes,hashlib,json,os,random,re,signal,struct,subprocess,time
from pathlib import Path
root=Path.cwd();base=root/'build/companion-placement'
p=argparse.ArgumentParser();p.add_argument('--wait-pid',type=int);args=p.parse_args()
if args.wait_pid:
    while Path(f'/proc/{args.wait_pid}/cmdline').exists():
        if b'companion-placement/scripts/refine.py' not in Path(f'/proc/{args.wait_pid}/cmdline').read_bytes():break
        time.sleep(1)
    assert 'REFINEMENT COMPLETE' in (base/'refine.console').read_text()
out=base/'crossover-micro';out.mkdir(exist_ok=False)
binary=(root/'build/libcuckoo-rmw/micro/micro-placed').resolve()
fractions=[0,50,0,75,0,100,0,50,0];step=35;warmup=10;duration=warmup+step*len(fractions)+5
env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','MALLOC_CONF'))}
env.update(ARBITER_TARGET_NODE='2',ARBITER_ARENA_REPORT='1')
command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=64G','-p','MemorySwapMax=0','--','/usr/bin/time','-f','%M %W','-o',str(out/'usage.time'),'timeout','--kill-after=10',str(duration+90),'numactl','--cpunodebind=0','--membind=0',str(binary),'--victims','32','--noise','0','--mode','none','--duration',str(duration),'--table-size','16','--ballast-mb','8192','--read-pct','50']
manifest=dict(command=command,environment={k:v for k,v in env.items() if k.startswith('ARBITER_')},binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),fractions=fractions,step=step,warmup=warmup,duration=duration,page_seed=381119,
    measurement='Same process and table mapping throughout. Ballast page migration only. Read existing per-worker epochs around a 15-second perf window, after migration and 3 seconds of warmup. Counter/op ratios use the enclosing epoch interval; attach/detach timing makes them approximate. No debugger or benchmark data writes.')
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
symbols=subprocess.check_output(['nm',str(binary)],text=True)
names=['_ZL7g_start.0','_ZL7g_table','_ZL9g_ballast','_ZL15g_ballast_elems','_ZL8g_epochs']
offsets={name:int(re.search(r'^([0-9a-f]+) \w '+re.escape(name)+r'$',symbols,re.M)[1],16) for name in names}
lib=ctypes.CDLL('libnuma.so.1',use_errno=True)
lib.numa_move_pages.argtypes=[ctypes.c_int,ctypes.c_ulong,ctypes.POINTER(ctypes.c_void_p),ctypes.POINTER(ctypes.c_int),ctypes.POINTER(ctypes.c_int),ctypes.c_int]
perf='/usr/lib/linux-hwe-6.8-tools-6.8.0-149/perf'
events='cycles:u,instructions:u,mem_inst_retired.lock_loads:u,mem_load_retired.l3_miss:u,ocr.demand_rfo.l3_hit.snoop_hitm:u,ocr.demand_data_rd.l3_hit.snoop_hitm:u'
log=(out/'output.log').open('w');proc=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
memory=None;pid=None;rows=[];started=time.monotonic()
def target(parent):
    try:
        if Path(f'/proc/{parent}/exe').resolve()==binary:return parent
        for child in Path(f'/proc/{parent}/task/{parent}/children').read_text().split():
            found=target(int(child))
            if found:return found
    except (FileNotFoundError,ProcessLookupError):pass
    return None
def page_status(pages,nodes=None):
    result=[]
    for offset in range(0,len(pages),4096):
        batch=pages[offset:offset+4096]
        addresses=(ctypes.c_void_p*len(batch))(*batch)
        wanted=None if nodes is None else (ctypes.c_int*len(batch))(*nodes[offset:offset+4096])
        states=(ctypes.c_int*len(batch))(*([-999]*len(batch)))
        ret=lib.numa_move_pages(pid,len(batch),addresses,wanted,states,0 if wanted is None else 2)
        assert ret==0 and min(states)>=0,(ret,ctypes.get_errno(),collections.Counter(states))
        if wanted is not None:assert list(states)==list(wanted)
        result.extend(states)
    return result
def sleep_until(deadline):
    while time.monotonic()<deadline:
        assert proc.poll() is None
        time.sleep(max(0,min(.05,deadline-time.monotonic())))
try:
    while not pid and proc.poll() is None and time.monotonic()-started<15:
        pid=target(proc.pid);time.sleep(.005)
    assert pid
    maps=Path(f'/proc/{pid}/maps').read_text()
    load=int(next(line for line in maps.splitlines() if str(binary) in line and line.split()[2]=='00000000').split('-')[0],16)
    memory=os.open(f'/proc/{pid}/mem',os.O_RDONLY)
    def read64(address):return struct.unpack('<Q',os.pread(memory,8,address))[0]
    while not os.pread(memory,1,load+offsets['_ZL7g_start.0'])[0]:
        assert proc.poll() is None and time.monotonic()-started<120;time.sleep(.005)
    run_start=time.monotonic()
    table=read64(load+offsets['_ZL7g_table']);ballast=read64(load+offsets['_ZL9g_ballast']);size=read64(load+offsets['_ZL15g_ballast_elems'])*8
    assert size==8192*1024*1024
    pages=list(range(ballast//4096*4096,(ballast+size+4095)//4096*4096,4096))
    table_pages=list(range(table//4096*4096,(table+16*64+4095)//4096*4096,4096))
    assert set(page_status(pages))=={0} and set(page_status(table_pages))=={2}
    indices=list(range(len(pages)));random.Random(381119).shuffle(indices)
    manifest.update(pid=pid,run_start_monotonic=run_start,table=hex(table),ballast=hex(ballast),ballast_bytes=size,ballast_pages=len(pages),table_pages=table_pages)
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    def epochs():
        before=time.monotonic();data=os.pread(memory,32*64,load+offsets['_ZL8g_epochs']);after=time.monotonic()
        values=[struct.unpack_from('<Q',data,i*64)[0] for i in range(32)]
        return dict(time=(before+after)/2,read_seconds=after-before,values=values,total=sum(values))
    for number,fraction in enumerate(fractions):
        sleep_until(run_start+warmup+number*step)
        phase_start=time.monotonic();selected=set(indices[:len(pages)*fraction//100]);wanted=[2 if i in selected else 0 for i in range(len(pages))]
        before=page_status(pages);changed=[p for p,a,b in zip(pages,before,wanted) if a!=b];targets=[b for a,b in zip(before,wanted) if a!=b]
        if changed:page_status(changed,targets)
        after=page_status(pages);assert after==wanted and set(page_status(table_pages))=={2}
        migrated=time.monotonic();sleep_until(migrated+3)
        assert time.monotonic()+16<run_start+warmup+(number+1)*step,'Insufficient stable interval'
        tids_before=sorted(int(p.name) for p in Path(f'/proc/{pid}/task').iterdir());assert len(tids_before)==33
        epoch_before=epochs()
        stat=[perf,'stat','-p',str(pid),'--timeout','15000','-x,','-e',events,'-o',str(out/f'phase-{number}.perf.csv')]
        with (out/f'phase-{number}.perf.stderr').open('w') as f:subprocess.run(stat,stdout=f,stderr=f,check=True)
        epoch_after=epochs();assert all(b>a for a,b in zip(epoch_before['values'],epoch_after['values']))
        tids_after=sorted(int(p.name) for p in Path(f'/proc/{pid}/task').iterdir());assert tids_after==tids_before
        counts={}
        for row in csv.reader((out/f'phase-{number}.perf.csv').open()):
            if len(row)>=5 and row[2] in events.split(','):
                assert float(row[4])>99.5,row;counts[row[2]]=float(row[0])
        assert len(counts)==6
        operations=epoch_after['total']-epoch_before['total'];seconds=epoch_after['time']-epoch_before['time']
        detail=dict(phase=number,fraction=fraction,migration_seconds=migrated-phase_start,cxl_pages=after.count(2),changed_pages=len(changed),page_index_sha256=hashlib.sha256(b''.join(struct.pack('<I',i) for i in sorted(selected))).hexdigest(),epoch_before=epoch_before,epoch_after=epoch_after,perf_command=stat,counts=counts,tids=tids_after)
        (out/f'phase-{number}.json').write_text(json.dumps(detail,indent=2)+'\n')
        record=dict(phase=number,ballast_percent=fraction,start_elapsed=epoch_before['time']-run_start,seconds=seconds,operations=operations,mops=operations/seconds/1e6,migration_seconds=migrated-phase_start,cxl_pages=after.count(2),**{k:v/operations for k,v in counts.items()})
        rows.append(record)
        with (out/'phases.csv').open('w') as f:w=csv.DictWriter(f,fieldnames=list(record),lineterminator='\n');w.writeheader();w.writerows(rows)
        print('PHASE',number,fraction,round(record['mops'],3),'Mops/s',flush=True)
    proc.wait(timeout=duration+90);log.close();assert proc.returncode==0
    text=(out/'output.log').read_text();assert 'status=ok' in text and 'fallback_allocations=0' in text
    operations=int(re.search(r'total_ops=(\d+)',text)[1]);assert rows[-1]['operations']<operations
    assert epoch_after['total']<=operations
    rss,swaps=map(int,(out/'usage.time').read_text().split());assert swaps==0
    for name,digest in json.loads((base/'frozen.json').read_text())['files'].items():assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,name
    (out/'checks.json').write_text(json.dumps(dict(valid=True,phase_count=len(rows),source_and_binary_unchanged=True,all_workers_active=True,all_page_moves_verified=True,final_ballast_node=0,benchmark_operations=operations,max_rss_kib=rss,reported_swaps=swaps),indent=2)+'\n')
    print('CROSSOVER COMPLETE',flush=True)
finally:
    if memory is not None:os.close(memory)
    if proc.poll() is None:os.killpg(proc.pid,signal.SIGTERM);proc.wait(timeout=15)
    log.close()

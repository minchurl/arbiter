"""Same frozen binary for every treatment; GDB stops only outside the timer."""
import argparse, csv, hashlib, json, os, re, subprocess, sys, time
from pathlib import Path

root=Path.cwd();base=root/'build/companion-placement'
p=argparse.ArgumentParser();p.add_argument('name');p.add_argument('--rounds',type=int,default=2);p.add_argument('--seconds',type=int,default=20);p.add_argument('--table',type=int,default=256);p.add_argument('--threads',type=int,default=32);p.add_argument('--reads',type=int,default=50);p.add_argument('--table-nodes',type=int,nargs='+',default=[0,2]);p.add_argument('--fractions',type=int,nargs='+',default=[0,1,5,10]);p.add_argument('--profile',action='store_true');p.add_argument('--binary',type=Path);args=p.parse_args()
out=base/args.name;out.mkdir(exist_ok=False)
binary=(args.binary or root/'build/libcuckoo-rmw/micro/micro-placed').resolve()
manifest=dict(args=vars(args),binary=str(binary),sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),method='Random nested subsets of ballast 4KiB pages, moved before worker creation; full object residency verified before and after timer. All treatments within this run use the same binary and GDB protocol.')
(out/'manifest.json').write_text(json.dumps(manifest,indent=2,default=str)+'\n')
rows=[]
choices=[(node,percent) for node in args.table_nodes for percent in args.fractions]
for repeat in range(1,args.rounds+1):
    order=choices if repeat%2 else list(reversed(choices))
    for table_node,percent in order:
        stem=out/f'{repeat}-table{table_node}-ballast{percent}'
        env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','MALLOC_CONF'))}
        env.update(ARBITER_TARGET_NODE='0',ARBITER_ARENA_REPORT='1')
        commands=['set pagination off','set confirm off','set print thread-events off','set disable-randomization off',
                  'break coherence_noise.cpp:338','run']
        def action(kind):
            call=[sys.executable,str(base/'scripts/micro-pages.py'),'PID',str(binary),str(stem),kind,str(percent),str(table_node),str(381119+repeat)]
            return ['python','import gdb, runpy, sys','args='+repr(call),"args[2]=str(gdb.selected_inferior().pid)","sys.argv=args[1:]","runpy.run_path(args[1],run_name='__main__')",'end']
        commands+=action('place')
        if args.profile:
            # All worker tasks exist here, before perf_window(true) and t0.
            commands+=['delete breakpoints','break coherence_noise.cpp:379','continue']
            ctl=stem.with_suffix('.ctl');ack=stem.with_suffix('.ack');os.mkfifo(ctl);os.mkfifo(ack)
            env.update(ARBITER_MICRO_PERF_CONTROL=str(ctl),ARBITER_MICRO_PERF_ACK=str(ack))
            events='cycles:u,instructions:u,mem_inst_retired.lock_loads:u,mem_load_retired.l3_miss:u,ocr.demand_rfo.l3_hit.snoop_hitm:u,ocr.demand_data_rd.l3_hit.snoop_hitm:u'
            perf=['/usr/lib/linux-hwe-6.8-tools-6.8.0-149/perf','stat','-D','-1','--control',f'fifo:{ctl},{ack}','-x,','-e',events,'-o',str(stem.with_suffix('.perf.csv')),'-p','PID']
            commands+=['python','import subprocess, time, signal, json','from pathlib import Path','perf_args='+repr(perf),"perf_args[-1]=str(gdb.selected_inferior().pid)","perf_info=dict(command=perf_args,tids=sorted(int(p.name) for p in Path('/proc',perf_args[-1],'task').iterdir()))",f"assert len(perf_info['tids'])=={args.threads+1}",f"Path({str(stem.with_suffix('.perf-command.json'))!r}).write_text(json.dumps(perf_info))",f"perf_log=open({str(stem.with_suffix('.perf.stderr'))!r},'w')",'prof=subprocess.Popen(perf_args,stdout=perf_log,stderr=perf_log)','time.sleep(0.2)','assert prof.poll() is None','end']
            stem.with_suffix('.perf-command.json').write_text(json.dumps(perf)+'\n')
        commands+=['delete breakpoints','break coherence_noise.cpp:413','continue']+action('verify')
        if args.profile:
            commands+=['python','prof.send_signal(signal.SIGINT)','perf_exit=prof.wait(timeout=10)','assert perf_exit in [0,130,-2], perf_exit','perf_log.close()','end']
        commands+=['delete breakpoints','continue']
        gdbfile=stem.with_suffix('.gdb');gdbfile.write_text('\n'.join(commands)+'\n')
        workload=['--victims',str(args.threads),'--noise','0','--mode','none','--duration',str(args.seconds),'--table-size',str(args.table),'--ballast-mb','8192','--read-pct',str(args.reads)]
        command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=64G','-p','MemorySwapMax=0','--','/usr/bin/time','-f','%M %W','-o',str(stem.with_suffix('.time')),'timeout','--kill-after=10','240','numactl','--cpunodebind=0','--membind=0','gdb','-nx','-q','-batch','-x',str(gdbfile),'--args',str(binary),*workload]
        stem.with_suffix('.command.json').write_text(json.dumps(dict(command=command,env={k:v for k,v in env.items() if k.startswith('ARBITER_')}),indent=2)+'\n')
        start=time.monotonic()
        with stem.with_suffix('.log').open('w') as stream:
            run=subprocess.run(command,env=env,stdout=stream,stderr=subprocess.STDOUT,timeout=260)
        log=stem.with_suffix('.log').read_text()
        assert run.returncode==0 and 'exited normally' in log and 'status=ok' in log,(stem,log[-2000:])
        assert 'fallback_allocations=0' in log
        for action_name in ['place','verify']:assert stem.with_suffix('.'+action_name+'.json').exists()
        ops=int(re.search(r'total_ops=(\d+)',log)[1]);seconds=float(re.search(r'elapsed=([\d.]+)',log)[1])
        validation=dict(re.findall(r'(\w+)=([^\s]+)',re.search(r'validation: (.*)',log)[1]))
        assert int(validation['reads'])+int(validation['writes'])==ops and validation['writes']==validation['versions']
        rss,swaps=map(int,stem.with_suffix('.time').read_text().split());assert swaps==0
        row=dict(round=repeat,table_node=table_node,ballast_percent=percent,ops=ops,seconds=seconds,mops=ops/seconds/1e6,wall_seconds=time.monotonic()-start,rss_kib=rss,valid=True)
        if args.profile:
            counts={}
            for record in csv.reader(stem.with_suffix('.perf.csv').open()):
                if len(record)>=5 and record[2] in events.split(','):
                    assert float(record[4])>99.5,(stem,record)
                    counts[record[2]]=float(record[0])
            assert len(counts)==6
            assert counts['mem_inst_retired.lock_loads:u']>=int(validation['writes'])*.99
            stem.with_suffix('.counters.json').write_text(json.dumps(dict(ops=ops,writes=int(validation['writes']),counts=counts,per_operation={k:v/ops for k,v in counts.items()}),indent=2)+'\n')
            ctl.unlink();ack.unlink()
        rows.append(row)
        with (out/'runs.csv').open('w') as f:
            w=csv.DictWriter(f,fieldnames=list(row));w.writeheader();w.writerows(rows)
        print(args.name,repeat,table_node,percent,round(row['mops'],3),flush=True)

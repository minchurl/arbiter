import argparse,csv,hashlib,json,os,re,select,subprocess,time
from pathlib import Path
root=Path.cwd();base=root/'build/placement-diagnosis';perf='/usr/lib/linux-hwe-6.8-tools-6.8.0-149/perf'
p=argparse.ArgumentParser();p.add_argument('workload',choices=['xindex','micro']);p.add_argument('name');p.add_argument('--node',type=int,default=0);p.add_argument('--group',default='basic');p.add_argument('--binary',type=Path);p.add_argument('--record',choices=['cycles','memory','locks','hitm','branches','instructions']);p.add_argument('--seconds',type=int,default=15);p.add_argument('--fg',type=int,default=31);p.add_argument('--bg',type=int,default=1);p.add_argument('--victims',type=int,default=32);p.add_argument('--table',type=int,default=256);p.add_argument('--ballast',type=int,default=8192);p.add_argument('--reads',type=int,default=50);p.add_argument('--membind',default='0');args=p.parse_args()
out=base/args.name;out.mkdir(exist_ok=False)
binary=args.binary or root/('build/libcuckoo-rmw/xindex/ycsb_bench-arbiter' if args.workload=='xindex' else 'build/libcuckoo-rmw/micro/micro-placed');binary=binary.resolve()
groups={
'basic':'cycles:u,instructions:u,mem_load_retired.l1_miss:u,mem_load_retired.l3_miss:u,mem_inst_retired.lock_loads:u,mem_load_l3_hit_retired.xsnp_fwd:u',
'stall':'cycles:u,instructions:u,cycle_activity.stalls_total:u,memory_activity.stalls_l1d_miss:u,memory_activity.stalls_l2_miss:u,memory_activity.stalls_l3_miss:u',
'tlb':'cycles:u,instructions:u,ref-cycles:u,dtlb_load_misses.walk_active:u,dtlb_load_misses.walk_completed:u,mem_load_retired.l2_miss:u',
'offcore':'cycles:u,instructions:u,ocr.demand_data_rd.any_response:u,ocr.demand_data_rd.l3_hit.snoop_hitm:u',
'rfo':'cycles:u,instructions:u,ocr.demand_rfo.any_response:u,ocr.demand_rfo.l3_hit.snoop_hitm:u',
}
env={k:v for k,v in os.environ.items() if not k.startswith('ARBITER_')}
env.update(ARBITER_TARGET_NODE=str(args.node),ARBITER_ARENA_REPORT='1',XINDEX_VALIDATE='1',LD_LIBRARY_PATH='/opt/intel/oneapi/mkl/latest/lib:'+env.get('LD_LIBRARY_PATH',''))
ctl=out/'ctl';ack=out/'ack';os.mkfifo(ctl);os.mkfifo(ack)
if args.workload=='xindex':
 workload=['--fg',str(args.fg),'--bg',str(args.bg),'--iteration','1','--ycsb_type','a','--ycsb-load',str(root/'benchmark/xindex/YCSB/xindex_dat/xindex_load_ycsb_a.dat'),'--ycsb-tx',str(root/'benchmark/xindex/YCSB/xindex_dat/xindex_transaction_ycsb_a.dat')]
else:
 workload=['--victims',str(args.victims),'--noise','0','--mode','none','--duration',str(args.seconds),'--table-size',str(args.table),'--ballast-mb',str(args.ballast),'--read-pct',str(args.reads)]
 env.update(ARBITER_MICRO_PERF_CONTROL=str(ctl),ARBITER_MICRO_PERF_ACK=str(ack))
common=[perf,'record' if args.record else 'stat','-D','-1','--control',f'fifo:{ctl},{ack}']
if args.record:
 event=['-e','cycles:u','-F','499'] if args.record=='cycles' else ['-e','{cpu/mem-loads-aux,period=1000000000000/u,cpu/event=0xcd,umask=0x1,ldlat=128,period=1003/upp}','-c','1003','-d','-W']
 if args.record=='locks':event=['-e','mem_inst_retired.lock_loads:upp','-c','100003','-d']
 if args.record=='hitm':event=['-e','mem_load_l3_hit_retired.xsnp_fwd:upp','-c','10003','-d']
 if args.record=='branches':event=['-e','br_inst_retired.cond_taken:upp','-c','100003']
 if args.record=='instructions':event=['-e','instructions:u','-F','499']
 common+=event+['-o',str(out/'perf.data')]
else:common+=['-x,','-e',groups[args.group],'-o',str(out/'perf.csv')]
command=common+['--','numactl','--cpunodebind=0','--membind='+args.membind,str(binary),*workload]
manifest={'args':vars(args),'command':command,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'env':{k:v for k,v in env.items() if k.startswith(('ARBITER_','XINDEX_','LD_LIBRARY','MALLOC_CONF'))},'time_start':time.time()}
(out/'manifest.json').write_text(json.dumps(manifest,default=str,indent=2)+'\n')
log=(out/'output.log').open('w');error=(out/'perf.stderr').open('w')
proc=subprocess.Popen(command,env=env,stdout=log,stderr=error)
def target_pid():
 for tid in Path('/proc',str(proc.pid),'task').iterdir():
  for value in (tid/'children').read_text().split():
   try:
    pid=int(value)
    if Path('/proc',value,'exe').resolve()==binary:return pid
   except FileNotFoundError:pass
 return None
pid=None;started=time.monotonic()
while proc.poll() is None and not pid and time.monotonic()-started<10:
 pid=target_pid();time.sleep(.01)
if not pid:raise RuntimeError('No benchmark child; '+(out/'perf.stderr').read_text())
manifest['pid']=pid

def snapshot(label):
 for name in ['stat','status','smaps_rollup','numa_maps','maps']+(['smaps'] if args.workload=='micro' else []):
  try:(out/(label+'.'+name)).write_text(Path('/proc',str(pid),name).read_text())
  except FileNotFoundError:pass
 for name in ['stat','interrupts','softirqs','vmstat']:
  (out/(label+'.system-'+name)).write_text(Path('/proc',name).read_text())

def control(fd,reply_fd,enable):
 os.write(fd,b'enable\n' if enable else b'disable\n')
 ready=select.select([reply_fd],[],[],5)[0]
 if not ready:raise RuntimeError('perf did not acknowledge')
 assert os.read(reply_fd,32).startswith(b'ack\n')

if args.workload=='xindex':
 symbols=subprocess.check_output(['nm',str(binary)],text=True)
 offset=int(re.search(r'^([0-9a-f]+) \w run_control$',symbols,re.M)[1],16)
 maps=Path('/proc',str(pid),'maps').read_text()
 load=next(line for line in maps.splitlines() if str(binary) in line and line.split()[2]=='00000000')
 address=int(load.split('-')[0],16)+offset
 memory=os.open('/proc/'+str(pid)+'/mem',os.O_RDONLY)
 fd=os.open(ctl,os.O_WRONLY);reply_fd=os.open(ack,os.O_RDONLY|os.O_NONBLOCK)
 active=False
 while proc.poll() is None:
  value=int.from_bytes(os.pread(memory,8,address),'little')
  if value&1 and not active:
   control(fd,reply_fd,True);manifest['enable_time']=time.time();active=True;snapshot('start')
  if active and 'xindex-operation-count executed=' in (out/'output.log').read_text():
   control(fd,reply_fd,False);manifest['disable_time']=time.time();snapshot('end');break
  if time.monotonic()-started>900:raise RuntimeError('XIndex phase timeout')
  time.sleep(.001 if active else .01)
 os.close(memory);os.close(fd);os.close(reply_fd)
else:
 # Existing microbenchmark FIFO commands define the exact counting window.
 # Snapshot after setup, during steady state. No counter commands from monitor.
 time.sleep(min(12,args.seconds/2+4));snapshot('middle')
code=proc.wait(timeout=900);log.close();error.close();ctl.unlink();ack.unlink();manifest['exit_code']=code
text=(out/'output.log').read_text()+(out/'perf.stderr').read_text()
assert code==0,(out,text[-1000:],(out/'perf.stderr').read_text())
residency=re.search(r'arbiter-arena-residency (.*)',text)
assert residency and 'fallback_allocations=0' in text
fields=dict(re.findall(r'(\w+)=(-?\d+)',residency[1]));assert fields['resident_pages']==fields['node'+str(args.node)+'_pages']
assert fields['query_error_pages']==fields['mincore_error_batches']=='0'
if args.workload=='xindex':
 ops=int(re.search(r'xindex-operation-count executed=(\d+)',text)[1]);seconds=float(re.search(r'Time\(sec\) : ([\d.]+)',text)[1])
 assert ops==400000000 and 'digest=0x7474b8e9d3962859' in text
else:
 ops=int(re.search(r'total_ops=(\d+)',text)[1]);seconds=float(re.search(r'elapsed=([\d.]+)',text)[1]);assert 'status=ok' in text
manifest.update(operations=ops,seconds=seconds,mops=ops/seconds/1e6,valid=True)
if not args.record:
 counters={}
 for row in csv.reader((out/'perf.csv').open()):
  if len(row)<5:continue
  assert float(row[4])>99.5,(out,row)
  counters[row[2]]=float(row[0])
 manifest['counters']=counters
(out/'manifest.json').write_text(json.dumps(manifest,default=str,indent=2)+'\n')
print(args.name,round(manifest['mops'],3),manifest.get('counters',{}),flush=True)

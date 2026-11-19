"""Change only physical page placement in an unchanged running XIndex binary."""
import argparse,bisect,ctypes,hashlib,json,os,re,signal,struct,subprocess,time
from pathlib import Path

root=Path.cwd();base=root/'build/xindex-contention-cause-20261119'
p=argparse.ArgumentParser();p.add_argument('name');p.add_argument('--node',type=int,default=0);p.add_argument('--binary',choices=['auto','buffer','leaf','data-array'],default='auto');p.add_argument('--phases',default='baseline,leaf,baseline,buffer,baseline,both,baseline');p.add_argument('--step',type=int,default=20);p.add_argument('--warmup',type=int,default=10);p.add_argument('--fg',type=int,default=31);p.add_argument('--top',type=int,default=1);args=p.parse_args()
phases=args.phases.split(',');duration=args.warmup+len(phases)*args.step+5
out=base/args.name;out.mkdir(exist_ok=False)
binary=(root/'build/placement-diagnosis/placements'/('xindex-'+args.binary)/'binary').resolve()
env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','XINDEX_','MALLOC_CONF'))}
env.update(ARBITER_TARGET_NODE=str(args.node),ARBITER_ARENA_REPORT='1',XINDEX_VALIDATE='1',XINDEX_THROUGHPUT_SAMPLE_SECONDS='1',LD_LIBRARY_PATH='/opt/intel/oneapi/mkl/latest/lib:'+env.get('LD_LIBRARY_PATH',''))
workload=['numactl','--cpunodebind=0','--membind=0',str(binary),'--fg',str(args.fg),'--bg','0','--duration',str(duration),'--ycsb_type','a','--ycsb-load',str(root/'benchmark/xindex/YCSB/xindex_dat/xindex_load_ycsb_a.dat'),'--ycsb-tx',str(root/'benchmark/xindex/YCSB/xindex_dat/xindex_transaction_ycsb_a.dat')]
command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=64G','-p','MemorySwapMax=0','--','timeout','--kill-after=10',str(duration+300),*workload]
manifest=dict(args=vars(args),duration=duration,command=command,env={k:v for k,v in env.items() if k.startswith(('ARBITER_','XINDEX_','LD_LIBRARY'))},binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),start=time.time(),scope='Duration replay and existing one-second throughput sampling; not fixed-count primary throughput. Migration transition intervals are excluded. No benchmark memory contents or instructions are written.')
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
lib=ctypes.CDLL('libnuma.so.1',use_errno=True);lib.numa_move_pages.argtypes=[ctypes.c_int,ctypes.c_ulong,ctypes.POINTER(ctypes.c_void_p),ctypes.POINTER(ctypes.c_int),ctypes.POINTER(ctypes.c_int),ctypes.c_int]
mathlib=ctypes.CDLL('libm.so.6');mathlib.fma.argtypes=[ctypes.c_double]*3;mathlib.fma.restype=ctypes.c_double
symbols=subprocess.check_output(['nm',str(binary)],text=True);control_offset=int(re.search(r'^([0-9a-f]+) \w run_control$',symbols,re.M)[1],16)
logpath=out/'output.log';stream=logpath.open('w');proc=subprocess.Popen(command,env=env,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)

def find_target(pid):
 try:
  if Path('/proc',str(pid),'exe').resolve()==binary:return pid
  for child in Path('/proc',str(pid),'task',str(pid),'children').read_text().split():
   found=find_target(int(child))
   if found:return found
 except (FileNotFoundError,ProcessLookupError):pass
 return None

pid=None;started=time.monotonic();memory=None
try:
 while proc.poll() is None and not pid and time.monotonic()-started<10:
  pid=find_target(proc.pid);time.sleep(.01)
 assert pid,'Target process missing'
 maps=Path('/proc',str(pid),'maps').read_text();load=int(next(line for line in maps.splitlines() if str(binary) in line and line.split()[2]=='00000000').split('-')[0],16)
 memory=os.open(f'/proc/{pid}/mem',os.O_RDONLY)
 def read(address,size):
  value=os.pread(memory,size,address);assert len(value)==size;return value
 def u64(address):return struct.unpack('<Q',read(address,8))[0]
 def predict(address,key):
  slope,bias=struct.unpack('<dd',read(address,16));return max(0,int(mathlib.fma(slope,float(key),bias)))
 def resolve(table,key):
  rt=u64(table);groups=u64(rt+16);group_n=u64(rt+24);table_size=u64(rt+32)
  assert 0<group_n<100000 and table_size==100000000,(group_n,table_size)
  gi=min(predict(rt,key)*group_n//table_size,group_n-1);group=u64(groups+8*gi)
  array_size=struct.unpack('<I',read(group+16,4))[0];assert 0<array_size<=table_size
  slot=min(predict(group,key),array_size-1);array=u64(group+24);record=array+32*slot
  primary=u64(record);buffer=u64(record+24)
  row=dict(key=key,root=rt,group=group,group_index=gi,array=array,array_size=array_size,record=record,record_key=primary,buffer=buffer,leaf=0,node_path=[],leaf_keys=[])
  if primary==key:return row
  assert buffer,('Missing chain',key,gi,slot,primary)
  node=u64(buffer)
  for _ in range(32):
   data=read(node,104);leaf,locked,n=struct.unpack_from('<BBB',data);assert leaf in [0,1] and n<=3
   keys=list(struct.unpack_from('<QQQ',data,16))[:n];row['node_path'].append(node)
   if leaf:
    assert key in keys,('Key missing',key,node,keys,gi,slot)
    row.update(leaf=node,leaf_keys=keys,value_slot=keys.index(key));return row
   idx=bisect.bisect_right(keys,key);node=struct.unpack_from('<Q',data,48+8*idx)[0]
  raise RuntimeError('Unexpected tree depth')
 def pages_status(pages,nodes=None):
  addresses=(ctypes.c_void_p*len(pages))(*pages);status=(ctypes.c_int*len(pages))(*([-999]*len(pages)));targets=None if nodes is None else (ctypes.c_int*len(pages))(*nodes)
  ctypes.set_errno(0);ret=lib.numa_move_pages(pid,len(pages),addresses,targets,status,0 if nodes is None else 2)
  err=ctypes.get_errno();result=dict(return_code=ret,errno=err,status=list(status))
  assert ret==0 and all(n>=0 for n in status),(pages,nodes,result)
  if nodes is not None:assert list(status)==nodes,(nodes,result)
  return result
 table=None
 while proc.poll() is None and time.monotonic()-started<240:
  match=re.search(r'^table: (0x[0-9a-f]+)',logpath.read_text(),re.M)
  if match:table=int(match[1],16);break
  time.sleep(.05)
 assert table,'Training did not finish'
 keys=[key for key,count in json.loads((root/'build/placement-diagnosis/trace-sample.json').read_text())['top_keys']]
 objects=[resolve(table,key) for key in keys]
 (out/'objects.json').write_text(json.dumps(objects,indent=2)+'\n')
 hot=[row for row in objects if row['leaf']][:args.top];assert hot
 groups={kind:sorted({row[kind]//4096*4096 for row in hot}) for kind in ['leaf','buffer','record']}
 allpages=sorted(set(sum(groups.values(),[])))
 original=pages_status(allpages)['status'];origin=dict(zip(allpages,original))
 manifest.update(pid=pid,table=hex(table),selected_hot_keys=[r['key'] for r in hot],target_pages=groups,initial_nodes={hex(k):v for k,v in origin.items()})
 while not (u64(load+control_offset)&1):
  assert proc.poll() is None and time.monotonic()-started<240
  time.sleep(.001)
 start_run=time.monotonic();manifest['run_observed_monotonic']=start_run
 (out/'start.maps').write_text(Path('/proc',str(pid),'maps').read_text());(out/'start.numa_maps').write_text(Path('/proc',str(pid),'numa_maps').read_text())
 records=[]
 print(args.name,'READY',[(r['key'],hex(r['leaf'])) for r in hot],flush=True)
 for index,phase in enumerate(phases):
  deadline=start_run+args.warmup+index*args.step
  while time.monotonic()<deadline:
   assert proc.poll() is None
   time.sleep(min(.05,max(.001,deadline-time.monotonic())))
  kinds=[] if phase=='baseline' else ['leaf','buffer'] if phase=='both' else [phase]
  assert set(kinds)<=set(groups)
  changed=set(page for kind in kinds for page in groups[kind])
  nodes=[(2 if origin[page]==0 else 0) if page in changed else origin[page] for page in allpages]
  before=pages_status(allpages);begin=time.monotonic();moved=pages_status(allpages,nodes);end=time.monotonic();after=pages_status(allpages)
  assert after['status']==nodes
  current=[resolve(table,key) for key in keys];assert current==objects,'Structure changed during existing-key replay'
  record=dict(phase=index,name=phase,start_elapsed=begin-start_run,stable_from_elapsed=end-start_run+2,end_elapsed=args.warmup+(index+1)*args.step,migration_seconds=end-begin,pages=[hex(p) for p in allpages],desired_nodes=nodes,before=before,migration=moved,after=after)
  records.append(record);(out/'phases.json').write_text(json.dumps(records,indent=2)+'\n')
  print(args.name,'PHASE',index,phase,'nodes',nodes,flush=True)
 # Restore original placement while the benchmark still has time to run.
 deadline=start_run+args.warmup+len(phases)*args.step
 while time.monotonic()<deadline:
  assert proc.poll() is None;time.sleep(.05)
 manifest['restore']=pages_status(allpages,original)
 manifest['final_query']=pages_status(allpages)
 os.close(memory);memory=None
 proc.wait(timeout=60);stream.close();assert proc.returncode==0
 text=logpath.read_text();assert 'digest=0x7474b8e9d3962859' in text and 'failed_reads=0' in text and 'fallback_allocations=0' in text
 residency=dict(re.findall(r'(\w+)=(-?\d+)',re.search(r'arbiter-arena-residency (.*)',text)[1]))
 assert residency['resident_pages']==residency[f'node{args.node}_pages'] and residency['query_error_pages']==residency['mincore_error_batches']=='0'
 manifest.update(valid=True,finish=time.time(),operations=int(re.search(r'xindex-operation-count executed=(\d+)',text)[1]))
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 print(args.name,'COMPLETE',flush=True)
except BaseException:
 if memory is not None:os.close(memory)
 try:os.killpg(proc.pid,signal.SIGTERM)
 except ProcessLookupError:pass
 proc.wait(timeout=15);stream.close();raise

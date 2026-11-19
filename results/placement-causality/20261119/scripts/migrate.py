"""Change only physical page placement in an unchanged running XIndex binary."""
import argparse,bisect,collections,ctypes,gzip,hashlib,json,os,random,re,signal,struct,subprocess,time
from pathlib import Path

root=Path.cwd();base=root/'build/xindex-contention-cause-20261119'
p=argparse.ArgumentParser();p.add_argument('name');p.add_argument('--node',type=int,default=0);p.add_argument('--alternate-node',type=int,choices=[0,1,2]);p.add_argument('--binary',choices=['auto','buffer','leaf','data-array'],default='auto');p.add_argument('--phases',default='baseline,leaf,baseline,buffer,baseline,both,baseline');p.add_argument('--step',type=int,default=20);p.add_argument('--warmup',type=int,default=10);p.add_argument('--fg',type=int,default=31);p.add_argument('--top',type=int,default=1);p.add_argument('--bulk',action='store_true');p.add_argument('--profile',action='store_true');p.add_argument('--phase-stat',action='store_true');p.add_argument('--profile-kind',choices=['retry','memory'],default='retry');args=p.parse_args()
assert not args.bulk or args.binary=='buffer', 'Bulk extent interpretation requires buffer-only selection'
phases=args.phases.split(',');duration=args.warmup+len(phases)*args.step+5
out=base/args.name;out.mkdir(exist_ok=False)
(out/'driver.py').write_bytes(Path(__file__).read_bytes())
binary=(root/'build/placement-diagnosis/placements'/('xindex-'+args.binary)/'binary').resolve()
env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','XINDEX_','MALLOC_CONF'))}
env.update(ARBITER_TARGET_NODE=str(args.node),ARBITER_ARENA_REPORT='1',XINDEX_VALIDATE='1',XINDEX_THROUGHPUT_SAMPLE_SECONDS='1',LD_LIBRARY_PATH='/opt/intel/oneapi/mkl/latest/lib:'+env.get('LD_LIBRARY_PATH',''))
workload=['numactl','--cpunodebind=0','--membind=0',str(binary),'--fg',str(args.fg),'--bg','0','--duration',str(duration),'--ycsb_type','a','--ycsb-load',str(root/'benchmark/xindex/YCSB/xindex_dat/xindex_load_ycsb_a.dat'),'--ycsb-tx',str(root/'benchmark/xindex/YCSB/xindex_dat/xindex_transaction_ycsb_a.dat')]
if args.bulk:workload=['strace','-qq','-f','--seccomp-bpf','-e','trace=mbind','-o',str(out/'mbind.log'),*workload]
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

pid=None;started=time.monotonic();memory=None;prof=None;profile_log=None
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
 def pages_status(pages,nodes=None,allow_absent=False):
  statuses=[]
  for off in range(0,len(pages),4096):
   batch=pages[off:off+4096];wanted=None if nodes is None else nodes[off:off+4096]
   addresses=(ctypes.c_void_p*len(batch))(*batch);status=(ctypes.c_int*len(batch))(*([-999]*len(batch)));targets=None if wanted is None else (ctypes.c_int*len(batch))(*wanted)
   ctypes.set_errno(0);ret=lib.numa_move_pages(pid,len(batch),addresses,targets,status,0 if wanted is None else 2)
   err=ctypes.get_errno();values=list(status)
   assert ret==0 and all(n>=0 or (allow_absent and n in [-2,-14]) for n in values),(off,ret,err,collections.Counter(values))
   if wanted is not None:assert values==wanted,(off,collections.Counter(values),collections.Counter(wanted))
   statuses.extend(values)
  return dict(return_code=0,errno=0,status=statuses)
 def compact(result):
  values=result['status']
  return dict(return_code=result['return_code'],errno=result['errno'],status_counts=dict(collections.Counter(values)),status_sha256=hashlib.sha256(struct.pack('<'+'i'*len(values),*values)).hexdigest(),**({'status':values} if len(values)<100 else {}))
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
 if args.bulk:
  ranges=[]
  for line in (out/'mbind.log').read_text().splitlines():
   m=re.search(r'mbind\((0x[0-9a-f]+),\s*(\d+),',line)
   if m and re.search(r'= 0\s*$',line):ranges.append((int(m[1],16),int(m[2])))
  assert ranges
  candidates=sorted({page for start,size in ranges for page in range(start,start+size,4096)})
  status=pages_status(candidates,allow_absent=True)['status']
  groups['bulkbuffer']=[page for page,node in zip(candidates,status) if node>=0]
  excluded={r['buffer']//4096*4096 for r in objects if r['buffer']}
  groups['coldbuffer']=[page for page in groups['bulkbuffer'] if page not in excluded]
  if 'halfbuffer' in phases:
   groups['halfbuffer']=sorted(random.Random(381119).sample(groups['coldbuffer'],len(groups['coldbuffer'])//2))
   manifest['partial_page_selection']=dict(fraction=0.5,seed=381119,method='Python random.sample without replacement over sorted cold-buffer pages, then sort selected addresses')
  assert set(groups['buffer'])<=set(groups['bulkbuffer']) and not set(groups['leaf'])&set(groups['bulkbuffer'])
  (out/'extent-discovery.json').write_text(json.dumps(dict(ranges=ranges,candidate_pages=len(candidates),resident_pages=len(groups['bulkbuffer']),status_counts=dict(collections.Counter(status)),excluded_hot_buffer_pages=sorted(excluded)),indent=2)+'\n')
 allpages=sorted(set(sum(groups.values(),[])))
 original=pages_status(allpages)['status'];origin=dict(zip(allpages,original))
 (out/'page-sets.json.gz').write_bytes(gzip.compress(json.dumps(dict(groups=groups,initial_nodes=origin)).encode(),mtime=0))
 manifest.update(pid=pid,table=hex(table),selected_hot_keys=[r['key'] for r in hot],page_sets_file='page-sets.json.gz',page_set_counts={k:len(v) for k,v in groups.items()},initial_node_counts=dict(collections.Counter(original)))
 while not (u64(load+control_offset)&1):
  assert proc.poll() is None and time.monotonic()-started<240
  time.sleep(.001)
 observed=time.monotonic()
 with (out/'clock-alignment.console').open('w') as clocklog:subprocess.run(['python3',str(base/'align-clock.py'),str(out)],stdout=clocklog,stderr=subprocess.STDOUT,check=True)
 start_run=json.loads((out/'clock-alignment.json').read_text())['start_estimate']
 manifest.update(run_observed_monotonic=observed,phase_clock_monotonic=start_run)
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 (out/'start.maps').write_text(Path('/proc',str(pid),'maps').read_text());(out/'start.numa_maps').write_text(Path('/proc',str(pid),'numa_maps').read_text())
 records=[]
 if args.profile:
  perf='/usr/lib/linux-hwe-6.8-tools-6.8.0-149/perf'
  profile_command=[perf,'record','--clockid','mono','-p',str(pid),'-c','100003','-e','br_inst_retired.cond_taken:upp,mem_inst_retired.lock_loads:upp,cpu/event=0x3c,umask=0,period=30000003/u','-d','-m','128','-o',str(out/'perf.data')]
  if args.profile_kind=='memory':
   profile_command=[perf,'record','--clockid','mono','-p',str(pid),'-e','{cpu/mem-loads-aux,period=1000000000000/u,cpu/event=0xcd,umask=0x1,ldlat=128,period=10007/upp}','-c','10007','-d','-W','-m','128','-o',str(out/'perf.data')]
  (out/'profile-command.json').write_text(json.dumps(profile_command)+'\n')
  profile_log=(out/'perf.stderr').open('w');prof=subprocess.Popen(profile_command,stdout=profile_log,stderr=subprocess.STDOUT)
 print(args.name,'READY',[(r['key'],hex(r['leaf'])) for r in hot],flush=True)
 for index,phase in enumerate(phases):
  deadline=start_run+args.warmup+index*args.step
  while time.monotonic()<deadline:
   assert proc.poll() is None
   time.sleep(min(.05,max(.001,deadline-time.monotonic())))
  kinds=[] if phase=='baseline' else ['leaf','buffer'] if phase=='both' else [phase]
  assert set(kinds)<=set(groups)
  changed=set(page for kind in kinds for page in groups[kind])
  nodes=[(args.alternate_node if args.alternate_node is not None else (2 if origin[page]==0 else 0)) if page in changed else origin[page] for page in allpages]
  before=pages_status(allpages);begin=time.monotonic();moved=pages_status(allpages,nodes);end=time.monotonic();after=pages_status(allpages)
  assert after['status']==nodes
  current=[resolve(table,key) for key in keys];assert current==objects,'Structure changed during existing-key replay'
  assert end-start_run+2<args.warmup+(index+1)*args.step-5,'Insufficient steady interval after migration'
  record=dict(phase=index,name=phase,start_elapsed=begin-start_run,stable_from_elapsed=end-start_run+2,end_elapsed=args.warmup+(index+1)*args.step,migration_seconds=end-begin,page_count=len(allpages),changed_page_count=len(changed),desired_node_counts=dict(collections.Counter(nodes)),before=compact(before),migration=compact(moved),after=compact(after))
  records.append(record);(out/'phases.json').write_text(json.dumps(records,indent=2)+'\n')
  print(args.name,'PHASE',index,phase,'nodes',dict(collections.Counter(nodes)),'migration_seconds',round(end-begin,3),flush=True)
  if args.phase_stat:
   while time.monotonic()<end+2:time.sleep(.01)
   events='cycles:u,instructions:u,mem_inst_retired.all_loads:u,mem_load_retired.l3_miss:u,mem_inst_retired.lock_loads:u'
   stat_command=['/usr/lib/linux-hwe-6.8-tools-6.8.0-149/perf','stat','-p',str(pid),'--timeout','5000','-x,','-e',events,'-o',str(out/f'phase-{index}.perf.csv')]
   stat_manifest=dict(command=stat_command,start_monotonic=time.monotonic(),phase=index,name=phase,tids_before=sorted(int(t.name) for t in Path(f'/proc/{pid}/task').iterdir()))
   with (out/f'phase-{index}.perf.stderr').open('w') as statlog:subprocess.run(stat_command,stdout=statlog,stderr=subprocess.STDOUT,check=True)
   stat_manifest['end_monotonic']=time.monotonic()
   stat_manifest['tids_after']=sorted(int(t.name) for t in Path(f'/proc/{pid}/task').iterdir())
   assert stat_manifest['tids_before']==stat_manifest['tids_after'] and len(stat_manifest['tids_after'])>=args.fg+1
   (out/f'phase-{index}.stat.json').write_text(json.dumps(stat_manifest,indent=2)+'\n')

 # Restore original placement while the benchmark still has time to run.
 deadline=start_run+args.warmup+len(phases)*args.step
 while time.monotonic()<deadline:
  assert proc.poll() is None;time.sleep(.05)
 if prof is not None:
  prof.send_signal(signal.SIGINT);prof.wait(timeout=20);profile_log.close();manifest["profile_returncode"]=prof.returncode;assert prof.returncode in [0,-signal.SIGINT]
 manifest['restore']=compact(pages_status(allpages,original))
 manifest['final_query']=compact(pages_status(allpages))
 os.close(memory);memory=None
 proc.wait(timeout=60);stream.close();assert proc.returncode==0
 text=logpath.read_text();assert 'digest=0x7474b8e9d3962859' in text and 'failed_reads=0' in text and 'fallback_allocations=0' in text
 residency=dict(re.findall(r'(\w+)=(-?\d+)',re.search(r'arbiter-arena-residency (.*)',text)[1]))
 assert residency['resident_pages']==residency[f'node{args.node}_pages'] and residency['query_error_pages']==residency['mincore_error_batches']=='0'
 manifest.update(valid=True,finish=time.time(),operations=int(re.search(r'xindex-operation-count executed=(\d+)',text)[1]))
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 print(args.name,'COMPLETE',flush=True)
except BaseException as error:
 manifest.update(valid=False,error=repr(error),failed_at=time.time())
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 if prof is not None and prof.poll() is None:prof.send_signal(signal.SIGINT);prof.wait(timeout=15);profile_log.close()
 if memory is not None:os.close(memory)
 try:os.killpg(proc.pid,signal.SIGTERM)
 except ProcessLookupError:pass
 proc.wait(timeout=15);stream.close();raise

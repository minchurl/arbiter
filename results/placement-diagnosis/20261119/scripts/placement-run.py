"""Uninstrumented placement comparisons with frozen benchmarks and full checks."""
import argparse,csv,hashlib,json,os,re,signal,subprocess,time
from pathlib import Path
root=Path.cwd();base=root/'build/placement-diagnosis'
p=argparse.ArgumentParser();p.add_argument('workload',choices=['micro','xindex']);p.add_argument('name');p.add_argument('--binary',type=Path);p.add_argument('--nodes',type=int,nargs='+',default=[0,2]);p.add_argument('--rounds',type=int,default=3);p.add_argument('--seconds',type=int,default=20);p.add_argument('--victims',type=int,default=32);p.add_argument('--fg',type=int,default=31);p.add_argument('--bg',type=int,default=1);p.add_argument('--table',type=int,default=256);p.add_argument('--ballast',type=int,default=8192);p.add_argument('--reads',type=int,default=50);p.add_argument('--objects',default='table');p.add_argument('--alignment',type=int,default=64);p.add_argument('--malloc-conf',default='');p.add_argument('--membind',default='0');p.add_argument('--noise',type=int,default=0);p.add_argument('--noise-mode',default='none');p.add_argument('--interleaved',action='store_true',help='Validate isolated diagnostic runtime: selected extents interleave nodes 0 and target');args=p.parse_args()
out=base/args.name;out.mkdir(exist_ok=False)
binary=(args.binary or root/('build/libcuckoo-rmw/micro/micro-placed' if args.workload=='micro' else 'build/libcuckoo-rmw/xindex/ycsb_bench-arbiter')).resolve()
manifest={'args':vars(args),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'start':time.time()};(out/'manifest.json').write_text(json.dumps(manifest,default=str,indent=2)+'\n');rows=[]
if args.interleaved:
 symbols=subprocess.check_output(['nm',str(binary)],text=True)
 offsets={name:int(re.search(r'^([0-9a-f]+) \w '+re.escape(name)+r'$',symbols,re.M)[1],16) for name in ['_ZL7g_start.0','_ZL7g_table','_ZL9g_ballast']}

def live_interleave_snapshot(process,stem,node):
 """Observe fully initialized live mappings once; never change the child."""
 def find_target(pid):
  try:
   if Path('/proc',str(pid),'exe').resolve()==binary:return pid
   for child in Path('/proc',str(pid),'task',str(pid),'children').read_text().split():
    target=find_target(int(child))
    if target:return target
  except (FileNotFoundError,ProcessLookupError):pass
  return None
 started=time.monotonic();pid=None
 while not pid and process.poll() is None and time.monotonic()-started<15:
  pid=find_target(process.pid);time.sleep(.01)
 assert pid,'No benchmark descendant'
 maps=Path('/proc',str(pid),'maps').read_text()
 mapping=next(line for line in maps.splitlines() if str(binary) in line and line.split()[2]=='00000000')
 load=int(mapping.split('-')[0],16);memory=os.open('/proc/'+str(pid)+'/mem',os.O_RDONLY)
 try:
  while not (os.pread(memory,1,load+offsets['_ZL7g_start.0'])[0]&1):
   assert process.poll() is None and time.monotonic()-started<120
   time.sleep(.01)
  snapshot_start=time.monotonic()
  pointers={name:int.from_bytes(os.pread(memory,8,load+offsets[symbol]),'little') for name,symbol in [('table','_ZL7g_table'),('ballast','_ZL9g_ballast')]}
 finally:os.close(memory)
 maps=Path('/proc',str(pid),'maps').read_text();numa=Path('/proc',str(pid),'numa_maps').read_text()
 stem.with_suffix('.live.maps').write_text(maps);stem.with_suffix('.live.numa_maps').write_text(numa)
 numa_lines={int(line.split()[0],16):line for line in numa.splitlines()};objects={};selected=args.objects.split(',')
 for obj,size in [('table',args.table*64),('ballast',args.ballast*1024*1024)]:
  if not size:continue
  address=pointers[obj]
  line=next(line for line in maps.splitlines() if int(line.split('-')[0],16)<=address<int(line.split()[0].split('-')[1],16))
  begin,end=[int(x,16) for x in line.split()[0].split('-')];assert address+size<=end
  numa_line=numa_lines[begin];nodes={int(k):int(v) for k,v in re.findall(r'\bN(\d+)=(\d+)',numa_line)}
  pages=sum(nodes.values());assert pages*4096>=size,(obj,pages,size)
  expected={0,node} if obj in selected else {int(args.membind)}
  assert set(nodes)<=expected and set(nodes)==expected,(obj,nodes,expected)
  if obj in selected and node:assert abs(nodes[0]-nodes[node])<=max(4,pages*.01),(obj,nodes)
  objects[obj]=dict(address=hex(address),bytes=size,mapping=line,numa_mapping=numa_line,resident_pages=pages,nodes=nodes)
 stem.with_suffix('.live.json').write_text(json.dumps(dict(pid=pid,snapshot_seconds=time.monotonic()-snapshot_start,objects=objects),indent=2)+'\n')

for repeat in range(1,args.rounds+1):
 nodes=args.nodes if repeat%2 else list(reversed(args.nodes))
 if len(args.nodes)>2:
  shift=(repeat-1)%len(args.nodes);nodes=args.nodes[shift:]+args.nodes[:shift]
 for node in nodes:
  stem=out/f'{repeat}-node{node}';env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','XINDEX_','MALLOC_CONF'))}
  env.update(ARBITER_TARGET_NODE=str(node),ARBITER_ARENA_REPORT='1',ARBITER_ARENA_SLOT_ALIGNMENT=str(args.alignment),XINDEX_VALIDATE='1',LD_LIBRARY_PATH='/opt/intel/oneapi/mkl/latest/lib:'+env.get('LD_LIBRARY_PATH',''))
  if args.malloc_conf:env['MALLOC_CONF']=args.malloc_conf
  if args.workload=='micro':workload=['--victims',str(args.victims),'--noise',str(args.noise),'--mode',args.noise_mode,'--duration',str(args.seconds),'--table-size',str(args.table),'--ballast-mb',str(args.ballast),'--read-pct',str(args.reads)]
  else:workload=['--fg',str(args.fg),'--bg',str(args.bg),'--iteration','1','--ycsb_type','a','--ycsb-load',str(root/'benchmark/xindex/YCSB/xindex_dat/xindex_load_ycsb_a.dat'),'--ycsb-tx',str(root/'benchmark/xindex/YCSB/xindex_dat/xindex_transaction_ycsb_a.dat')]
  command=['/usr/bin/time','-f','%M %W','-o',str(stem.with_suffix('.time')),'timeout','--kill-after=10','900','numactl','--cpunodebind=0','--membind='+args.membind,str(binary),*workload]
  stem.with_suffix('.command.json').write_text(json.dumps({'command':command,'environment':{k:v for k,v in env.items() if k.startswith(('ARBITER_','XINDEX_','MALLOC_CONF','LD_LIBRARY'))}},indent=2)+'\n')
  start=time.monotonic()
  with stem.with_suffix('.log').open('w') as f:
   if args.interleaved:
    run=subprocess.Popen(command,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
    try:
     live_interleave_snapshot(run,stem,node)
     run.wait(timeout=920)
    except BaseException:
     try:os.killpg(run.pid,signal.SIGTERM)
     except ProcessLookupError:pass
     run.wait(timeout=10);raise
   else:run=subprocess.run(command,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=920)
  log=stem.with_suffix('.log').read_text();assert run.returncode==0,(stem,log[-1000:]);assert 'Invalid conf' not in log and 'Invalid configuration' not in log
  if args.workload=='micro':
   ops=int(re.search(r'total_ops=(\d+)',log)[1]);seconds=float(re.search(r'elapsed=([\d.]+)',log)[1]);assert 'status=ok' in log
   validation=dict(re.findall(r'(\w+)=([^\s]+)',re.search(r'validation: (.*)',log)[1]));assert int(validation['reads'])+int(validation['writes'])==ops and validation['writes']==validation['versions']
   selected=args.objects.split(',') if args.objects else []
   for obj in ['table']+(['ballast'] if args.ballast else []):
    match=re.search(r'placement object='+obj+r' .*?nodes=([^\s]+)',log);assert match,(stem,obj)
    expected=node if obj in selected else int(args.membind)
    actual=list(map(int,match[1].split(',')))
    if args.interleaved and obj in selected:
     assert len(actual)==3 and set(actual)<={0,node},(stem,obj,actual)
    else:assert actual==[expected]*3,(stem,obj,actual,expected)
  else:
   ops=int(re.search(r'xindex-operation-count executed=(\d+)',log)[1]);seconds=float(re.search(r'Time\(sec\) : ([\d.]+)',log)[1]);assert ops==400000000 and 'digest=0x7474b8e9d3962859' in log
  residency=re.search(r'arbiter-arena-residency (.*)',log);assert residency and 'fallback_allocations=0' in log
  fields=dict(re.findall(r'(\w+)=(-?\d+)',residency[1]));resident=int(fields['resident_pages']);assert resident>0
  if args.interleaved and node:
   local=int(fields.get('node0_pages',0));other=int(fields.get('node'+str(node)+'_pages',0))
   # Freed large objects may be purged; the live snapshot proves balance.
   assert local+other==resident,(stem,fields)
  else:assert fields['resident_pages']==fields['node'+str(node)+'_pages']
  assert fields['query_error_pages']==fields['mincore_error_batches']=='0'
  rss,swaps=map(int,stem.with_suffix('.time').read_text().split());assert swaps==0
  row={'round':repeat,'node':node,'ops':ops,'seconds':seconds,'mops':ops/seconds/1e6,'wall_seconds':time.monotonic()-start,'rss_kib':rss,'resident_pages':int(fields['resident_pages']),'valid':True};rows.append(row)
  with (out/'runs.csv').open('w') as f:w=csv.DictWriter(f,fieldnames=list(row),lineterminator='\n');w.writeheader();w.writerows(rows)
  print(args.name,repeat,node,round(row['mops'],3),flush=True)

"""Rewrites only allocation/deallocation from frozen input IR; no C++ rebuild."""
import hashlib,json,os,subprocess,sys
from pathlib import Path
root=Path.cwd();base=root/'build/placement-diagnosis'
subprocess.run([sys.executable,str(base/'analyze-samples.py')],check=True)
subprocess.run([sys.executable,str(base/'trace-sample.py')],check=True)
out=base/'placements';out.mkdir(exist_ok=False)
clang=root/'.tools/llvm-18.1.8/bin/clang++';opt=root/'.tools/llvm18-apt-root/usr/bin/opt-18';plugin=root/'build/libcuckoo-rmw/compiler/lib/ArbiterLLVMPlugin.so';runtime=root/'build/libcuckoo-rmw/compiler/runtime/libarbiter_runtime.a'
env=dict(os.environ,LD_LIBRARY_PATH=str(root/'.tools/libtinfo5-root/lib/x86_64-linux-gnu')+':'+str(root/'.tools/libllvm18-root/usr/lib/x86_64-linux-gnu'),LIBRARY_PATH=str(root/'.tools/libstdcxx')+':'+str(root/'.tools/libllvm18-root/usr/lib/x86_64-linux-gnu'))
records=[]
for workload in ['micro','xindex']:
 source=root/('build/libcuckoo-rmw/micro/micro-native.bc' if workload=='micro' else 'build/libcuckoo-rmw/xindex/ycsb_bench.bc')
 options=root/('build/libcuckoo-rmw/micro/micro-native.hitm-seed-effective.opt-args' if workload=='micro' else 'build/libcuckoo-rmw/xindex/ycsb_bench.hitm-seed-effective.opt-args')
 choices=[('table','4'),('ballast','5'),('both','4,5')] if workload=='micro' else [('auto','68,71,74,90,97,98,99,100'),('buffer','68'),('leaf','71'),('buffer-leaf','68,71'),('rcu','2'),('data-array','38'),('auto-plus-data','38,68,71,74,90,97,98,99,100')]
 for name,ids in choices:
  directory=out/(workload+'-'+name);directory.mkdir();rewritten=directory/'placed.bc'
  args=[a for a in options.read_text().splitlines() if not a.startswith(('-arbiter-hitm-seed-report-path=','-arbiter-hitm-seed-site-ids='))]
  args+=['-arbiter-hitm-seed-site-ids='+ids,'-arbiter-hitm-seed-report-path='+str(directory/'selection.csv')]
  command=[str(opt),'-load-pass-plugin',str(plugin),'-passes=arbiter-experiment-hitm-seed-rewrite',*args,str(source),'-o',str(rewritten)]
  subprocess.run(command,env=env,check=True)
  if workload=='micro':
   command2=[str(clang),'-std=c++17','-O2','-gline-tables-only','-march=native','-pthread',str(rewritten),str(runtime),'-Wl,--no-as-needed','-ljemalloc','-lnuma','-o',str(directory/'binary')]
  else:
   command2=[str(clang),'-O3',str(rewritten),str(runtime),'-L/opt/intel/oneapi/mkl/latest/lib','-Wl,-rpath,/opt/intel/oneapi/mkl/latest/lib','-ljemalloc','-lmkl_rt','-lpthread','-lnuma','-ljemalloc','-o',str(directory/'binary')]
  subprocess.run(command2,env=env,check=True)
  record={'workload':workload,'selection':ids,'name':name,'commands':[command,command2],'input_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'rewritten_sha256':hashlib.sha256(rewritten.read_bytes()).hexdigest(),'binary_sha256':hashlib.sha256((directory/'binary').read_bytes()).hexdigest()};records.append(record)
  (directory/'manifest.json').write_text(json.dumps(record,indent=2)+'\n');print('BUILT',directory.name,flush=True)
(out/'manifest.json').write_text(json.dumps(records,indent=2)+'\n')

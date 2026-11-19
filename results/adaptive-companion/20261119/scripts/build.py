import hashlib,json,os,subprocess
from pathlib import Path
root=Path.cwd();base=root/'build/adaptive-companion';build=base/'compiler'
env={**os.environ,**json.loads((base/'build.json').read_text())['environment']}
opt=root/'.tools/llvm18-apt-root/usr/bin/opt-18';clang=root/'.tools/llvm-18.1.8/bin/clang++';plugin=build/'lib/ArbiterLLVMPlugin.so'
commands=[];records={}
def run(cmd):
 cmd=list(map(str,cmd));r=subprocess.run(cmd,env=env,text=True,capture_output=True)
 commands.append(dict(command=cmd,stdout=r.stdout,stderr=r.stderr,returncode=r.returncode))
 assert r.returncode==0,r.stderr
 return r
for name,folder,stem in [('micro','micro','micro-native'),('xindex','xindex','ycsb_bench'),('cuckoo','bench-final','contention')]:
 src=root/'build/libcuckoo-rmw'/folder;out=base/name;out.mkdir(exist_ok=True)
 opts=src/(stem+'.hitm-seed-effective.opt-args')
 if not opts.exists():opts=root/'build/libcuckoo-rmw/micro/micro-native.hitm-seed-effective.opt-args'
 args=[x for x in opts.read_text().splitlines() if not x.startswith(('-arbiter-hitm-seed-report-path=','-arbiter-hitm-seed-site-ids='))]
 bc=src/(stem+'.bc');output=out/'adaptive.bc'
 result=run([opt,'-load-pass-plugin',plugin,'-passes=arbiter-experiment-adaptive-rewrite',*args,bc,'-o',output])
 run([opt,'-passes=verify','-disable-output',output])
 binary=out/'adaptive'
 link=[clang,'-std=c++17','-O2','-gline-tables-only','-march=native','-pthread',output,build/'runtime/libarbiter_adaptive_experiment.a',build/'runtime/libarbiter_runtime.a','-Wl,--no-as-needed','-ljemalloc','-lnuma']
 if name=='xindex':link+=['-L/opt/intel/oneapi/mkl/latest/lib','-Wl,-rpath,/opt/intel/oneapi/mkl/latest/lib','-lmkl_rt','-ldl','-lm']
 run([*link,'-o',binary])
 records[name]=dict(binary=str(binary),binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),input_sha256=hashlib.sha256(bc.read_bytes()).hexdigest(),instrumentation=result.stderr)
 if name in ['xindex','cuckoo']:
  seed=out/'seed.bc';run([opt,'-load-pass-plugin',plugin,'-passes=arbiter-experiment-hitm-seed-rewrite',*args,bc,'-o',seed])
  records[name]['seed_ir_identical']=seed.read_bytes()==output.read_bytes()
  assert records[name]['seed_ir_identical']
 print(name,records[name],flush=True)
# Same runtime and worker instructions without progress hooks: deployment control.
# Linking changes addresses/layout, so this does not isolate observer CPU cost.
out=base/'micro'
run([clang,'-std=c++17','-O2','-gline-tables-only','-march=native','-pthread',root/'build/budgeted-companion/micro/expanded.bc',root/'build/budgeted-companion/plan-loader.o',build/'runtime/libarbiter_runtime.a','-Wl,--no-as-needed','-ljemalloc','-lnuma','-o',out/'plain'])
(out/'local.plan').write_text('5 0 0 0\n')
records['micro']['plain']=dict(path=str(out/'plain'),sha256=hashlib.sha256((out/'plain').read_bytes()).hexdigest())
(base/'variants.json').write_text(json.dumps(dict(records=records,commands=commands),indent=2)+'\n')

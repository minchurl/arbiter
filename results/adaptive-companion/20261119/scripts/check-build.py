import json,os,subprocess
from pathlib import Path
p=Path('build/adaptive-companion');env={**os.environ,**json.loads((p/'build.json').read_text())['environment']}
checks=[]
def run(cmd,name,extra=None):
 with (p/(name+'.log')).open('w') as f:subprocess.run(cmd,env={**env,**(extra or {})},stdout=f,stderr=subprocess.STDOUT,check=True)
 checks.append(dict(name=name,passed=True));print('PASS',name,flush=True)
run(['cmake','--build',str(p/'compiler'),'--target','ArbiterLLVMPlugin','arbiter_adaptive_experiment','arbiter-adaptive-counter-smoke','arbiter-placement-policy','arbiter-runtime-smoke','arbiter-slab-arena-boundary-smoke','-j','4'],'build-v4')
run(['python3',str(p/'scripts/build.py')],'variants-build')
run(['python3','scripts/test-hitm-analysis.py','--build-dir',str((p/'compiler').resolve()),'--opt',str(Path('.tools/llvm18-apt-root/usr/bin/opt-18').resolve()),'--clangxx',str(Path('.tools/llvm-18.1.8/bin/clang++').resolve()),'--filecheck','/usr/bin/FileCheck-14'],'analysis-tests')
for target in ['arbiter-placement-policy','arbiter-runtime-smoke','arbiter-slab-arena-boundary-smoke']:
 run(['numactl','--cpunodebind=0','--membind=0',str(p/'compiler/bin'/target)],target,dict(ARBITER_TARGET_NODE='2',ARBITER_ARENA_REPORT='1'))
for mode,value,invalid in [('owned',1234,0),('borrow',100,0),('duplicate',100,1),('reset',50,1)]:
 name='counter-'+mode
 run(['numactl','--cpunodebind=0','--membind=0',str(p/'compiler/bin/arbiter-adaptive-counter-smoke'),mode],name,dict(ARBITER_TARGET_NODE='2'))
 events=[json.loads(x[len('arbiter-adaptive '):]) for x in (p/(name+'.log')).read_text().splitlines() if x.startswith('arbiter-adaptive ')]
 assert len(events)==1 and events[0]['event']=='finish' and events[0]['progress']==value and events[0]['invalid_progress']==invalid,events
(p/'build-checks.json').write_text(json.dumps(checks,indent=2)+'\n')
print('BUILD CHECKS FINISHED',flush=True)

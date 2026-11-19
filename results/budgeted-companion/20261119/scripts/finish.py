"""Post-measurement checks, with no compiler/test load during throughput runs."""
import hashlib,json,os,subprocess,sys,time
from pathlib import Path
root=Path.cwd();base=root/'build/budgeted-companion'
while Path('/proc/'+sys.argv[1]).exists():time.sleep(2)
assert 'QUEUE FINISHED' in (base/'queue.console').read_text()
env={**os.environ,**json.loads((base/'build-tools.json').read_text())['environment']}
checks=[]
def run(command,name,extra=None):
    print('START',name,flush=True)
    with (base/(name+'.log')).open('w') as f:subprocess.run(command,env={**env,**(extra or {})},stdout=f,stderr=subprocess.STDOUT,check=True)
    checks.append(dict(name=name,command=command,passed=True));print('PASS',name,flush=True)
if (base/'page-validation/summary.json').exists():
    page_checks=json.loads((base/'page-validation/summary.json').read_text())
    assert len(page_checks)==4 and all(r['unchanged_before_after'] for r in page_checks)
    checks.append(dict(name='page-validation',passed=True,reused='Completed query-only diagnostics; benchmark binaries unchanged.'))
else:run([sys.executable,str(base/'scripts/validate-pages.py')],'page-validation')
before={name:(base/(name+'-companions.csv')).read_bytes() for name in ['micro','xindex','cuckoo']}
run([sys.executable,str(base/'scripts/build-tools.py')],'final-build')
assert all((base/(name+'-companions.csv')).read_bytes()==text for name,text in before.items()),'Final analysis changed candidate reports'
run([sys.executable,'scripts/test-hitm-analysis.py','--build-dir',str(base/'compiler'),'--opt',str(root/'.tools/llvm18-apt-root/usr/bin/opt-18'),'--clangxx',str(root/'.tools/llvm-18.1.8/bin/clang++'),'--filecheck','/usr/bin/FileCheck-14'],'final-analysis-tests')
run(['cmake','--build',str(base/'compiler'),'--target','arbiter-placement-policy','arbiter-runtime-smoke','arbiter-slab-arena-boundary-smoke','-j','4'],'final-test-build')
for name in ['arbiter-placement-policy','arbiter-runtime-smoke','arbiter-slab-arena-boundary-smoke']:
    run(['numactl','--cpunodebind=0','--membind=0',str(base/'compiler/bin'/name)],'final-'+name,dict(ARBITER_TARGET_NODE='2',ARBITER_ARENA_REPORT='1'))
# Rebuild from final sources in a separate directory; keep measured binaries intact.
verify=base/'reproduction';verify.mkdir(exist_ok=False);reproduced=[]
for record in json.loads((base/'variants.json').read_text())['commands']:
    command=record['command']
    if '-o' not in command:continue
    output=Path(command[command.index('-o')+1]);relative=output.relative_to(base);target=verify/relative;target.parent.mkdir(parents=True,exist_ok=True)
    changed=[str(verify/Path(x).relative_to(base)) if str(x).startswith(str(base)) and (x.endswith('.bc') or x.endswith('plan-loader.o')) else x for x in command]
    changed[changed.index('-o')+1]=str(target)
    run(changed,'reproduce-'+relative.as_posix().replace('/','-'))
    expected=hashlib.sha256(output.read_bytes()).hexdigest();actual=hashlib.sha256(target.read_bytes()).hexdigest()
    reproduced.append(dict(path=str(relative),original=expected,rebuilt=actual,identical=expected==actual))
assert all(r['identical'] for r in reproduced),reproduced
(base/'reproduction.json').write_text(json.dumps(reproduced,indent=2)+'\n')
for name in ['audit','summarize','emit-plans','plot']:run([sys.executable,str(base/'scripts'/(name+'.py'))],'final-'+name)
(base/'checks.json').write_text(json.dumps(checks,indent=2)+'\n')
print('FINISHED CHECKS',flush=True)

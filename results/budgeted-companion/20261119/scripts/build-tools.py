import json,os,subprocess
from pathlib import Path
root=Path.cwd();base=root/'build/budgeted-companion'
env=dict(os.environ,LD_LIBRARY_PATH=str(root/'.tools/libtinfo5-root/lib/x86_64-linux-gnu')+':'+str(root/'.tools/libllvm18-root/usr/lib/x86_64-linux-gnu'),LIBRARY_PATH=str(root/'.tools/libstdcxx')+':'+str(root/'.tools/libllvm18-root/usr/lib/x86_64-linux-gnu'),CPLUS_INCLUDE_PATH='/usr/include/c++/11/backward:/usr/include/x86_64-linux-gnu/c++/11:/usr/include/c++/11')
commands=[]
def run(command,name):
    with (base/(name+'.log')).open('w') as f:result=subprocess.run(command,env=env,stdout=f,stderr=subprocess.STDOUT)
    commands.append(dict(command=command,returncode=result.returncode));assert result.returncode==0,name
run(['cmake','--build',str(base/'compiler'),'--target','ArbiterLLVMPlugin','arbiter_runtime','-j','4'],'build-tools')
for name,folder,stem in [('micro','micro','micro-native'),('cuckoo','bench-final','contention'),('xindex','xindex','ycsb_bench')]:
    source=root/'build/libcuckoo-rmw'/folder
    option_file=source/(stem+'.hitm-seed-effective.opt-args')
    if not option_file.exists():option_file=root/'build/libcuckoo-rmw/micro/micro-native.hitm-seed-effective.opt-args'
    args=[a for a in option_file.read_text().splitlines() if not a.startswith('-arbiter-hitm-seed-report-path=')]
    run([str(root/'.tools/llvm18-apt-root/usr/bin/opt-18'),'-load-pass-plugin',str(base/'compiler/lib/ArbiterLLVMPlugin.so'),'-passes=arbiter-report-companion-sites',*args,'-arbiter-hitm-seed-report-path='+str(base/(name+'-companions.csv')),'-disable-output',str(source/(stem+'.bc'))],name+'-companions')
    print(name,(base/(name+'-companions.csv')).read_text()[:4000],flush=True)
(base/'build-tools.json').write_text(json.dumps(dict(commands=commands,environment={k:env[k] for k in ['LD_LIBRARY_PATH','LIBRARY_PATH','CPLUS_INCLUDE_PATH']}),indent=2)+'\n')

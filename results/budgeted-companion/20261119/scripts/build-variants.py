import csv,hashlib,json,os,re,subprocess
from pathlib import Path
root=Path.cwd();base=root/'build/budgeted-companion';build=base/'compiler'
env={**os.environ,**json.loads((base/'build-tools.json').read_text())['environment']}
loader=base/'plan-loader.cpp'
loader.write_text(r'''#include "arbiter_runtime_site.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
__attribute__((constructor)) static void configure() {
 const char *path=std::getenv("ARBITER_EXPERIMENT_PLAN");
 if(!path)return;
 FILE *file=std::fopen(path,"r");if(!file){std::perror("placement plan");std::abort();}
 unsigned site,percent;int local;unsigned long long cap;
 for(;;){int n=std::fscanf(file,"%u %d %u %llu",&site,&local,&percent,&cap);
  if(n==EOF)break;
  if(n!=4||arbiter_set_site_placement(site,local,percent,cap)){
   std::perror("configure placement plan");std::abort();
  }
 }
 if(std::ferror(file))std::abort();std::fclose(file);
}
''')
commands=[];records={}
def run(command):
    r=subprocess.run(command,env=env,text=True,capture_output=True);commands.append(dict(command=command,stderr=r.stderr));assert r.returncode==0,r.stderr
opt=str(root/'.tools/llvm18-apt-root/usr/bin/opt-18');clang=str(root/'.tools/llvm-18.1.8/bin/clang++')
run([clang,'-O2','-std=c++17','-I'+str(root/'runtime/include'),'-c',str(loader),'-o',str(base/'plan-loader.o')])
for name,folder,stem,old in [('micro','micro','micro-native','micro-placed'),('xindex','xindex','ycsb_bench','ycsb_bench-arbiter')]:
    src=root/'build/libcuckoo-rmw'/folder;out=base/name;out.mkdir(exist_ok=True)
    args=[a for a in (src/(stem+'.hitm-seed-effective.opt-args')).read_text().splitlines() if not a.startswith(('-arbiter-hitm-seed-report-path=','-arbiter-hitm-seed-site-ids='))]
    bc=src/(stem+'.bc');plugin=build/'lib/ArbiterLLVMPlugin.so'
    for label,used in [('old',root/'build/libcuckoo-rmw/compiler/lib/ArbiterLLVMPlugin.so'),('new',plugin)]:
        run([opt,'-load-pass-plugin',str(used),'-passes=arbiter-report-hitm-seed-sites',*args,'-arbiter-hitm-seed-report-path='+str(out/(label+'-seeds.csv')),'-disable-output',str(bc)])
    assert (out/'old-seeds.csv').read_bytes()==(out/'new-seeds.csv').read_bytes()
    seeds=[int(r['site_id']) for r in csv.DictReader((out/'new-seeds.csv').open()) if r['selected']=='yes']
    legacy=[int(r['site_id']) for r in csv.DictReader((base/'historical'/(name+'.csv')).open()) if r['role']=='member']
    loop=[int(r['companion_id']) for r in csv.DictReader((base/(name+'-companions.csv')).open())]
    companions=sorted((set(legacy)|set(loop))-set(seeds))
    binaries={}
    for variant,ids in [('seed',seeds),('expanded',sorted(seeds+companions))]:
        output=out/(variant+'.bc')
        run([opt,'-load-pass-plugin',str(plugin),'-passes=arbiter-experiment-hitm-seed-rewrite',*args,'-arbiter-hitm-seed-site-ids='+','.join(map(str,ids)),str(bc),'-o',str(output)])
        link=[clang,'-std=c++17','-O2','-gline-tables-only','-march=native','-pthread',str(output),str(base/'plan-loader.o'),str(build/'runtime/libarbiter_runtime.a'),'-Wl,--no-as-needed','-ljemalloc','-lnuma']
        if name=='xindex':link+=['-L/opt/intel/oneapi/mkl/latest/lib','-Wl,-rpath,/opt/intel/oneapi/mkl/latest/lib','-lmkl_rt','-ldl','-lm']
        binary=out/variant;run([*link,'-o',str(binary)])
        binaries[variant]=dict(path=str(binary),sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),bitcode_sha256=hashlib.sha256(output.read_bytes()).hexdigest())
    if name=='micro':
        symbol='_ZL13victim_threadi6ConfigP12VictimResult';workers={}
        for label,path in [('original',src/old)]+[(v,Path(b['path'])) for v,b in binaries.items()]:
            text=subprocess.run(['objdump','-d','--no-show-raw-insn','--disassemble='+symbol,str(path)],text=True,capture_output=True,check=True).stdout
            lines=[]
            for line in text.splitlines():
                match=re.match(r'\s*[0-9a-f]+:\s*(.*)',line)
                if match:
                    x=re.sub(r'-?0x[0-9a-f]+\(%rip\)','RIP',match[1]);lines.append(re.sub(r'\b[0-9a-f]+ (?=<)','ADDR ',x))
            workers[label]=dict(instructions=len(lines),sha256=hashlib.sha256('\n'.join(lines).encode()).hexdigest())
        assert len({v['sha256'] for v in workers.values()})==1 and workers['original']['instructions']==149,workers
        (out/'worker-equivalence.json').write_text(json.dumps(workers,indent=2)+'\n')
    records[name]=dict(seeds=seeds,legacy_members=legacy,loop_companions=loop,companions=companions,binaries=binaries,original_binary=str(src/old),source_sha256=hashlib.sha256(bc.read_bytes()).hexdigest())
    print(name,'seeds',seeds,'companions',companions,flush=True)
(base/'variants.json').write_text(json.dumps(dict(records=records,commands=commands),indent=2)+'\n')

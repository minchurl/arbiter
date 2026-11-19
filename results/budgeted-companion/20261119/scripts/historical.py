"""Run the removed member-expansion algorithm with today's frozen seed policy."""
import json,os,re,shlex,subprocess
from pathlib import Path
root=Path.cwd();base=root/'build/budgeted-companion';out=base/'historical';out.mkdir(exist_ok=True)
env=json.loads((base/'build-tools.json').read_text())['environment'];env={**os.environ,**env}
source_ref='046a8033dc7184e2b3e6595ee2b1c002b1603859'
for name in ['UseBasedHotSet.h','UseBasedHotSet.cpp']:
    original=subprocess.check_output(['git','show',source_ref+':compiler/llvm/lib/hotset/'+name],text=True)
    (base/('historical-'+name)).write_text(original)
    text=original.replace('arbiter::llvm::hotset','arbiter::llvm::hitm_seed')
    (out/name).write_text(text)
source=(root/'compiler/llvm/lib/hitm_seed/HITMSeedPasses.cpp').read_text()
factory=source[source.index('HITMSeedPolicy hitmSeedPolicyFromOptions()'):source.index('[[noreturn]]')]
adapter='''#include "UseBasedHotSet.h"
#include "HITMSeedOptions.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/raw_ostream.h"
using namespace llvm;
using namespace arbiter::llvm::hitm_seed;
'''+factory+'''
struct LegacyPass : PassInfoMixin<LegacyPass> {
 PreservedAnalyses run(Module &m,ModuleAnalysisManager &) {
  auto sites=arbiter::llvm::collectAllocationSites(m);
  auto seeds=selectHITMSeeds(m,sites,hitmSeedPolicyFromOptions());
  auto selected=discoverUseBasedHotSet(m,seeds,HotSetPolicy{});
  outs()<<"site_id,role,group_id,affinity,access,depth\\n";
  for(auto &r:selected.records)
   outs()<<r.site->id<<','<<hotSetRoleName(r.role)<<','<<r.groupId<<','<<r.memberAffinity<<','<<r.memberAccessKind<<','<<r.memberAccessDepth<<'\\n';
  return PreservedAnalyses::all();
 }
};
extern "C" LLVM_ATTRIBUTE_WEAK PassPluginLibraryInfo llvmGetPassPluginInfo() {
 return {LLVM_PLUGIN_API_VERSION,"LegacyCompanions",LLVM_VERSION_STRING,[](PassBuilder &b) {
  b.registerPipelineParsingCallback([](StringRef n,ModulePassManager &m,ArrayRef<PassBuilder::PipelineElement>) {
   if(n!="arbiter-report-legacy-companions")return false;m.addPass(LegacyPass());return true;
  });
 }};
}
'''
(out/'adapter.cpp').write_text(adapter)
build=base/'compiler';target='compiler/llvm/lib/CMakeFiles/ArbiterLLVM.dir/hitm_seed/CompanionAnalysis.cpp.o'
template=shlex.split(subprocess.check_output(['ninja','-C',str(build),'-t','commands',target],text=True).strip());commands=[]
for name in ['UseBasedHotSet','adapter']:
    command=[arg.replace(target,str(out/(name+'.o'))).replace(str(root/'compiler/llvm/lib/hitm_seed/CompanionAnalysis.cpp'),str(out/(name+'.cpp'))) for arg in template]
    command+=['-I'+str(root/'compiler/llvm/lib/hitm_seed'),'-I'+str(out)]
    subprocess.run(command,env=env,cwd=build,check=True);commands.append(command)
plugin=out/'LegacyCompanions.so'
command=[str(root/'.tools/llvm-18.1.8/bin/clang++'),'-shared','-fPIC',str(out/'adapter.o'),str(out/'UseBasedHotSet.o'),str(build/'lib/libArbiterLLVM.a'),'-lLLVM','-o',str(plugin)]
subprocess.run(command,env=env,check=True);commands.append(command)
for name,folder,stem in [('micro','micro','micro-native'),('cuckoo','bench-final','contention'),('xindex','xindex','ycsb_bench')]:
    input=root/'build/libcuckoo-rmw'/folder
    args=[a for a in (root/'build/libcuckoo-rmw/micro/micro-native.hitm-seed-effective.opt-args').read_text().splitlines() if not a.startswith('-arbiter-hitm-seed-report-path=')]
    command=[str(root/'.tools/llvm18-apt-root/usr/bin/opt-18'),'-load-pass-plugin',str(plugin),'-passes=arbiter-report-legacy-companions',*args,'-disable-output',str(input/(stem+'.bc'))]
    with (out/(name+'.csv')).open('w') as f:subprocess.run(command,env=env,stdout=f,check=True)
    commands.append(command)
(out/'manifest.json').write_text(json.dumps(dict(source_ref=source_ref,located_on_branch='experiment/hotset-migration',introduced_by='046a803',removed_by='47d700a',adaptation='Namespace renamed only; original member algorithm and defaults. Uses current frozen seed policy.',commands=commands),indent=2)+'\n')

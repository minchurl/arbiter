"""Held-out algorithm confirmations, interleaving implementations per round."""
import csv,json,shutil,subprocess,sys
from pathlib import Path
root=Path.cwd();out=root/'build/libcuckoo-rmw'
parts=out/'interleaved-parts';parts.mkdir(exist_ok=False)
def run(name,args):
 print('START',name,flush=True)
 with (out/(name+'.console.log')).open('w') as stream:
  subprocess.run(args,stdout=stream,stderr=subprocess.STDOUT,check=True)
 print('DONE',name,flush=True)
# Fixed before examining the confirmation results. Same operations/seed across
# algorithms and modes. Every case includes a fresh baseline and native control.
for reads,hot,ops in [(0,64,24000000),(0,256,80000000),(0,65536,250000000),(0,1048576,250000000),(50,64,24000000)]:
 groups={}
 for repeat in range(1,4):
  variants=[('baseline','bench-final'),('ttas','variant-ttas'),('ttas-padded','variant-ttas-padded')]
  variants=variants[repeat-1:]+variants[:repeat-1]
  for variant,folder in variants:
   name=f'variant-confirm-{variant}-r{reads}-h{hot}'
   part=parts/(name+f'-repeat{repeat}')
   modes=['native','local','cxl'] if repeat%2 else ['cxl','local','native']
   run(part.name,[sys.executable,'scripts/run-libcuckoo.py','--bin-dir',str(out/folder),'--result-dir',str(part),'--rounds','1','--reads',str(reads),'--hot',str(hot),'--operations',str(ops),'--seed',str(310119+repeat-1),'--modes',*modes])
   groups.setdefault(name,[]).append(part)
 for name,components in groups.items():
  directory=out/name;directory.mkdir(exist_ok=False);rows=[]
  manifest=json.loads((components[0]/'manifest.json').read_text());manifest.update(rounds=3,result_dir=str(directory),interleaved_components=[str(p) for p in components])
  (directory/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
  for repeat,component in enumerate(components,1):
   for row in csv.DictReader((component/'runs.csv').open()):
    row['round']=str(repeat);rows.append(row)
    for suffix in ['.json','.stderr','.command.json']:
     shutil.copyfile(component/('1-'+row['mode']+suffix),directory/(str(repeat)+'-'+row['mode']+suffix))
  with (directory/'runs.csv').open('w') as f:
   w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
# Disjoint-key operations can still collide on bucket locks; single-thread is
# the uncontended control. Both use the unmodified library.
for label,extra in [('singlethread',['--threads','1','--hot','64','--operations','500000000']),('partitioned',['--threads','32','--hot','1048576','--operations','250000000','--partitioned'])]:
 name='control-confirm-'+label
 run(name,[sys.executable,'scripts/run-libcuckoo.py','--bin-dir',str(out/'bench-final'),'--result-dir',str(out/name),'--rounds','3','--reads','0','--seed','310119',*extra])
for reads in [0,10,50,100]:
 name=f'universal-repeat-r{reads}'
 run(name,[sys.executable,'scripts/run-libcuckoo.py','--bin-dir',str(out/'bench-final'),'--result-dir',str(out/name),'--benchmark','universal','--rounds','5','--reads',str(reads),'--initial-capacity','23','--prefill','75','--total-ops','50000','--seed','191119'])
run('lock-profiles',[sys.executable,str(out/'profile-locks.py')])

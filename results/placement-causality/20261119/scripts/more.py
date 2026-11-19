import subprocess,sys
from pathlib import Path
base=Path('build/xindex-contention-cause-20261119')
cases=[('profile-cold-local-r2',['--binary','buffer','--node','0','--bulk','--warmup','20','--step','30','--phases','baseline,coldbuffer,baseline,coldbuffer,baseline','--profile']),('confirm-hot-local',['--node','0','--top','20','--step','20','--phases','baseline,both,baseline,both,baseline']),('confirm-hot-cxl',['--node','2','--top','20','--step','20','--phases','baseline,both,baseline,both,baseline']),('profile-cold-memory',['--binary','buffer','--node','0','--bulk','--warmup','20','--step','35','--phases','baseline,coldbuffer,baseline,coldbuffer,baseline','--profile','--profile-kind','memory'])]
for name,options in cases:
 print('START',name,flush=True)
 with (base/(name+'.console')).open('w') as f:subprocess.run([sys.executable,str(base/'migrate.py'),name,*options],stdout=f,stderr=subprocess.STDOUT,check=True)
 subprocess.run([sys.executable,str(base/'summarize-phases.py'),str(base/name)],check=True)
 print('DONE',name,flush=True)

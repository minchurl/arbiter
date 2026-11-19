import subprocess,sys
from pathlib import Path
base=Path('build/xindex-contention-cause-20261119')
for name,node,profile in [('confirm-cold-local',0,False),('confirm-cold-cxl',2,False),('profile-cold-local',0,True)]:
 command=[sys.executable,str(base/'migrate.py'),name,'--binary','buffer','--node',str(node),'--bulk','--warmup','20','--step','30','--phases','baseline,coldbuffer,baseline,coldbuffer,baseline']
 if profile:command.append('--profile')
 print('START',name,flush=True)
 with (base/(name+'.console')).open('w') as f:subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,check=True)
 subprocess.run([sys.executable,str(base/'summarize-phases.py'),str(base/name)],check=True)
 print('DONE',name,flush=True)

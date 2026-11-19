import subprocess,sys
from pathlib import Path
base=Path('build/xindex-contention-cause-20261119')
name='confirm-cold-node1'
with (base/(name+'.console')).open('w') as stream:
 subprocess.run([sys.executable,str(base/'migrate.py'),name,'--binary','buffer','--node','0','--alternate-node','1','--bulk','--warmup','20','--step','30','--phases','baseline,coldbuffer,baseline,coldbuffer,baseline'],stdout=stream,stderr=subprocess.STDOUT,check=True)
subprocess.run([sys.executable,str(base/'summarize-phases.py'),str(base/name)],check=True)
name='confirm-cold-16fg'
with (base/(name+'.console')).open('w') as stream:
 subprocess.run([sys.executable,str(base/'migrate.py'),name,'--binary','buffer','--node','0','--fg','16','--bulk','--warmup','20','--step','30','--phases','baseline,coldbuffer,baseline'],stdout=stream,stderr=subprocess.STDOUT,check=True)
subprocess.run([sys.executable,str(base/'summarize-phases.py'),str(base/name)],check=True)
name='profile-cold-counters'
with (base/(name+'.console')).open('w') as stream:
 subprocess.run([sys.executable,str(base/'migrate.py'),name,'--binary','buffer','--node','0','--bulk','--warmup','20','--step','25','--phases','baseline,coldbuffer,baseline','--phase-stat'],stdout=stream,stderr=subprocess.STDOUT,check=True)
subprocess.run([sys.executable,str(base/'summarize-phases.py'),str(base/name)],check=True)
subprocess.run([sys.executable,str(base/'cuckoo-cache.py')],check=True)

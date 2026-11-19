"""Sequential screens; never run benchmarks concurrently."""
import subprocess,sys
from pathlib import Path
base=Path('build/companion-placement')
jobs=[('run-micro.py','screen-micro-default','--rounds','2'),
      ('run-cuckoo.py','screen-cuckoo-hot64','--hot','64','--operations','8000000'),
      ('run-cuckoo.py','screen-cuckoo-hot65536','--hot','65536','--operations','128000000'),
      ('run-cuckoo.py','screen-cuckoo-hot1m','--hot','1048576','--operations','32000000'),
      ('run-cuckoo.py','screen-cuckoo-hot8m','--keys','8388608','--hot','8388608','--operations','16000000'),
      ('run-cuckoo.py','screen-cuckoo-hot32m','--keys','33554432','--hot','33554432','--operations','8000000')]
for hot in [4,16,64]:
    jobs.append(('run-micro.py',f'screen-micro-hot{hot}','--table',str(hot),'--rounds','2','--table-nodes','2'))
for job in jobs:
    print('START',job[1],flush=True)
    with (base/(job[1]+'.console')).open('w') as f:
        subprocess.run([sys.executable,str(base/'scripts'/job[0]),*job[1:]],stdout=f,stderr=subprocess.STDOUT,check=True)
    print((base/(job[1]+'.console')).read_text(),flush=True)

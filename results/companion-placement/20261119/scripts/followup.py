"""After the first screen finishes, run extra conditions and XIndex regression."""
import json,os,subprocess,sys,time
from pathlib import Path
base=Path('build/companion-placement')
pid=int(sys.argv[1])
while Path(f'/proc/{pid}/cmdline').exists():
    command=Path(f'/proc/{pid}/cmdline').read_bytes()
    if b'companion-placement/scripts/screen.py' not in command:break
    time.sleep(1)
assert (base/'screen-micro-hot64/runs.csv').exists(),'Screen failed; inspect logs'
assert len((base/'screen-micro-hot64/runs.csv').read_text().splitlines())==9
jobs=[('run-micro.py','screen-micro-hot1','--table','1','--rounds','2','--table-nodes','2'),
      ('run-micro.py','screen-micro-write100','--reads','0','--rounds','2','--table-nodes','2'),
      ('run-micro.py','screen-micro-write100-hot4','--reads','0','--table','4','--rounds','2','--table-nodes','2')]
for job in jobs:
    print('START',job[1],flush=True)
    with (base/(job[1]+'.console')).open('w') as f:
        subprocess.run([sys.executable,str(base/'scripts'/job[0]),*job[1:]],stdout=f,stderr=subprocess.STDOUT,check=True)
    print((base/(job[1]+'.console')).read_text(),flush=True)
print('START full XIndex YCSB-A regression',flush=True)
with (base/'xindex-regression.console').open('w') as f:
    subprocess.run([sys.executable,'results/placement-diagnosis/20261119/scripts/placement-run.py','xindex','companion-xindex-regression','--rounds','3'],stdout=f,stderr=subprocess.STDOUT,check=True)
print((base/'xindex-regression.console').read_text(),flush=True)
print('FOLLOWUP COMPLETE',flush=True)

"""Additional structural-write controls, unchanged binaries and selection."""
import csv
import json
import os
from pathlib import Path
import subprocess
import sys

root=Path.cwd()
base=root/'build/libcuckoo-write-heavy-20261119'
cases=[
 dict(name='insert50-erase50-large',benchmark='universal',capacity=23,prefill=50,inserts=50,erases=50,confirmation_count=29,rounds=3,rationale='Larger bucket working set, beyond the 60 MiB LLC; same request count as the smaller churn case.'),
 dict(name='insert100-reserved',benchmark='universal',capacity=28,prefill=0,inserts=100,erases=0,confirmation_count=27,rounds=3,rationale='Reserve enough capacity to avoid timed resize; same 134217728 successful insert requests as the growth case.')]
(base/'extra-cases.json').write_text(json.dumps(cases,indent=2)+'\n')
env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','MALLOC_CONF','XINDEX_'))}
for case in cases:
 directory=base/('confirm-'+case['name'])
 command=[sys.executable,str(root/'scripts/run-libcuckoo.py'),'--bin-dir',str(root/'build/libcuckoo-rmw/bench-final'),'--result-dir',str(directory),'--benchmark','universal','--reads','0','--updates','0','--inserts',str(case['inserts']),'--erases',str(case['erases']),'--initial-capacity',str(case['capacity']),'--prefill',str(case['prefill']),'--total-ops',str(100*(1<<case['confirmation_count'])//(1<<case['capacity'])),'--threads','32','--rounds',str(case['rounds']),'--seed','420001','--modes','local','cxl']
 print('START',case['name'],flush=True)
 with (base/(directory.name+'.console')).open('w') as f:subprocess.run(command,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
 rows=list(csv.DictReader((directory/'runs.csv').open()))
 print('DONE',case['name'],[(r['round'],r['mode'],round(float(r['mops']),3)) for r in rows],flush=True)
print('EXTRA RUNS COMPLETE',flush=True)

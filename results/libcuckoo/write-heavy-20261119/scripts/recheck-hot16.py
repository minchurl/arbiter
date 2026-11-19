"""Fresh-seed recheck of the small +2% initial hot-16 result; retain both stages."""
import json
import os
import subprocess
import sys
from pathlib import Path
root=Path.cwd();base=root/'build/libcuckoo-write-heavy-20261119'
case=dict(name='update100-hot16-recheck',benchmark='contention',hot=16,confirmation_count=2200000,rounds=5,rationale='Initial hot-16 mean was +2.04%, with four of five positive pairs. Retest the same fixed count on fresh seeds, reversing the initial placement order. Do not pool this follow-up into the original result.')
path=base/'extra-cases.json';cases=json.loads(path.read_text());assert not any(c['name']==case['name'] for c in cases)
cases.append(case);path.write_text(json.dumps(cases,indent=2)+'\n')
command=[sys.executable,str(root/'scripts/run-libcuckoo.py'),'--bin-dir',str(root/'build/libcuckoo-rmw/bench-final'),'--result-dir',str(base/('confirm-'+case['name'])),'--benchmark','contention','--reads','0','--keys','1048576','--hot','16','--operations','2200000','--threads','32','--rounds','5','--seed','470001','--modes','cxl','local']
env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','MALLOC_CONF','XINDEX_'))}
subprocess.run(command,env=env,check=True)

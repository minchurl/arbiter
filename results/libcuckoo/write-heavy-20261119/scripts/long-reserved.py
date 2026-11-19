"""Longer reserved-insert confirmation after the initial sub-second control."""
import json
import os
import subprocess
import sys
from pathlib import Path
root=Path.cwd();base=root/'build/libcuckoo-write-heavy-20261119'
case=dict(name='insert100-reserved-long',benchmark='universal',capacity=30,prefill=0,inserts=100,erases=0,confirmation_count=29,rounds=3,rationale='The capacity-28, 134M-request reserved control lasted under one second. Increase both capacity and count fourfold; retain the short control separately. This is not a count-matched comparison to the growth case.')
path=base/'extra-cases.json';cases=json.loads(path.read_text());assert not any(c['name']==case['name'] for c in cases)
cases.append(case);path.write_text(json.dumps(cases,indent=2)+'\n')
command=[sys.executable,str(root/'scripts/run-libcuckoo.py'),'--bin-dir',str(root/'build/libcuckoo-rmw/bench-final'),'--result-dir',str(base/('confirm-'+case['name'])),'--benchmark','universal','--reads','0','--inserts','100','--initial-capacity','30','--prefill','0','--total-ops','50','--threads','32','--rounds','3','--seed','460001','--modes','local','cxl']
env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','MALLOC_CONF','XINDEX_'))}
subprocess.run(command,env=env,check=True)

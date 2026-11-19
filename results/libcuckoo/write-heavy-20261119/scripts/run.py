"""Fresh write-heavy comparisons using unchanged benchmark executables."""
import csv
import json
import math
import os
from pathlib import Path
import subprocess
import sys

root=Path.cwd();base=root/'build/libcuckoo-write-heavy-20261119'
runner=root/'scripts/run-libcuckoo.py';binaries=root/'build/libcuckoo-rmw/bench-final'
cases=[dict(name=f'update100-hot{hot}',benchmark='contention',hot=hot,initial_operations=count,rounds=5) for hot,count in [(1,100000),(16,500000),(64,2000000),(65536,40000000)]]
cases += [dict(name='insert50-erase50',benchmark='universal',capacity=20,prefill=50,inserts=50,erases=50,initial_power=24,max_power=29,rounds=5),dict(name='insert100-growth',benchmark='universal',capacity=12,prefill=0,inserts=100,erases=0,initial_power=24,max_power=27,rounds=3)]
env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','MALLOC_CONF','XINDEX_'))}

def launch(case,phase,operations,rounds,seed,modes):
    directory=base/(phase+'-'+case['name'])
    command=[sys.executable,str(runner),'--bin-dir',str(binaries),'--result-dir',str(directory),'--benchmark',case['benchmark'],'--reads','0','--threads','32','--rounds',str(rounds),'--seed',str(seed),'--modes',*modes]
    if case['benchmark']=='contention':command += ['--keys','1048576','--hot',str(case['hot']),'--operations',str(operations)]
    else:command += ['--initial-capacity',str(case['capacity']),'--prefill',str(case['prefill']),'--inserts',str(case['inserts']),'--erases',str(case['erases']),'--total-ops',str(100*(1<<operations)//(1<<case['capacity']))]
    print('START',phase,case['name'],'count',operations,flush=True)
    with (base/(directory.name+'.console')).open('w') as stream:subprocess.run(command,env=env,stdout=stream,stderr=subprocess.STDOUT,check=True)
    rows=list(csv.DictReader((directory/'runs.csv').open()))
    print('DONE',phase,case['name'],[(r['round'],r['mode'],round(float(r['mops']),3)) for r in rows],flush=True)
    return rows

for case in cases:
    initial=case.get('initial_operations',case.get('initial_power'))
    rows=launch(case,'calibrate',initial,1,410001,['local','cxl'])
    fast=max(float(row['mops']) for row in rows)
    if case['benchmark']=='contention':
        count=math.ceil(fast*1e6*12/32/100000)*100000
    else:
        count=min(case['max_power'],max(case['initial_power'],math.ceil(math.log2(fast*1e6*12))))
    case['confirmation_count']=count
    case['calibration_fast_mops']=fast
    case['target_fast_mode_seconds']=12
    (base/'cases.json').write_text(json.dumps(cases,indent=2)+'\n')

for case in cases:
    launch(case,'confirm',case['confirmation_count'],case['rounds'],420001,['local','cxl'])

for case in cases:
    if case['name'] in ['update100-hot64','update100-hot65536','insert50-erase50']:
        launch(case,'native',case['confirmation_count'],3,420001,['native'])
print('WRITE-HEAVY RUNS COMPLETE',flush=True)

"""Exercise forwarded upstream flags and reject invalid mixes before execution."""
import csv
import json
import os
import subprocess
import sys
from pathlib import Path

root=Path.cwd(); base=root/'build/libcuckoo-write-heavy-20261119'
validation=base/'validation'; validation.mkdir(exist_ok=False)
runner=str(root/'scripts/run-libcuckoo.py')
env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','MALLOC_CONF','XINDEX_'))}
checks=[]
for name,options in [
 ('invalid-sum',['--benchmark','universal','--reads','10','--updates','90','--inserts','50']),
 ('negative-mix',['--benchmark','universal','--reads','0','--updates','101','--erases','-1']),
 ('wrong-driver',['--updates','100']),
 ('truncated-count',['--benchmark','universal','--initial-capacity','2','--total-ops','100','--threads','32']),
 ('zero-count',['--benchmark','universal','--initial-capacity','0','--total-ops','1'])]:
 result=validation/name
 command=[sys.executable,runner,'--result-dir',str(result),*options]
 run=subprocess.run(command,env=env,capture_output=True,text=True)
 assert run.returncode==2 and not result.exists(),(name,run.returncode,run.stderr)
 checks.append(dict(name=name,command=command,exit_code=run.returncode,stderr=run.stderr,result_directory_created=False))
for name,options,expected in [
 ('legacy',['--reads','60'],dict(reads=60,updates=40,inserts=0,erases=0,upserts=0)),
 ('updates',['--reads','0','--updates','100'],dict(reads=0,updates=100,inserts=0,erases=0,upserts=0)),
 ('upserts',['--reads','0','--upserts','100'],dict(reads=0,updates=0,inserts=0,erases=0,upserts=100)),
 ('mixed',['--reads','20','--updates','20','--inserts','20','--erases','20','--upserts','20'],dict(reads=20,updates=20,inserts=20,erases=20,upserts=20))]:
 directory=validation/name
 command=[sys.executable,runner,'--bin-dir',str(root/'build/libcuckoo-rmw/bench-final'),'--benchmark','universal','--result-dir',str(directory),'--initial-capacity','12','--prefill','50','--total-ops','10000','--threads','8','--rounds','1','--seed','450001',*options]
 run=subprocess.run(command,env=env,capture_output=True,text=True,check=True)
 raw=[]
 for row in csv.DictReader((directory/'runs.csv').open()):
  stem=directory/('1-'+row['mode']);data=json.loads(stem.with_suffix('.json').read_text())
  args=data['args'].split();flags=dict(zip(args[::2],map(int,args[1::2])))
  assert all(flags['--'+key]==value for key,value in expected.items())
  assert data['output']['total_ops']['value']==409600
  raw.append(dict(mode=row['mode'],stdout=data,stderr=stem.with_suffix('.stderr').read_text(),command=json.loads(stem.with_suffix('.command.json').read_text())))
 checks.append(dict(name=name,command=command,exit_code=run.returncode,expected_mix=expected,raw=raw))
(base/'runner-checks.json').write_text(json.dumps(dict(all_passed=True,negative_cases=5,smoke_processes=12,cases=checks),indent=2)+'\n')
print('RUNNER CHECKS PASSED: five rejection cases and twelve real upstream processes',flush=True)

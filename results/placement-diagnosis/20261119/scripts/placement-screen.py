import subprocess,sys
from pathlib import Path
base=Path('build/placement-diagnosis')
def run(workload,name,extra):
 print('START',name,flush=True)
 subprocess.run([sys.executable,str(base/'placement-run.py'),workload,name,'--rounds','1',*extra],check=True)
# Same fixed microbenchmark workload throughout. Different selection is an
# explicit causal ablation; no candidate site IDs are added to production policy.
run('micro','screen-micro-table',['--nodes','0','2','1'])
for placement in ['ballast','both']:
 run('micro','screen-micro-'+placement,['--binary',str(base/'placements'/('micro-'+placement)/'binary'),'--objects','ballast' if placement=='ballast' else 'table,ballast','--nodes','0','2','1'])
# Page-policy control: affects jemalloc globally; do not call it a CXL speedup.
run('micro','screen-micro-thp',['--malloc-conf','thp:always','--nodes','0','2'])
for alignment in [128,4096]:run('micro','screen-micro-align'+str(alignment),['--alignment',str(alignment)])
# XIndex allocation ablations keep original source, trace and operation counts.
for placement in ['buffer','leaf','buffer-leaf','rcu','data-array','auto-plus-data']:
 run('xindex','screen-xindex-'+placement,['--binary',str(base/'placements'/('xindex-'+placement)/'binary')])
run('xindex','screen-xindex-node1',['--nodes','1'])
print('PLACEMENT SCREEN DONE',flush=True)

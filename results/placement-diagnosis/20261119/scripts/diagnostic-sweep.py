import subprocess,sys,os
from pathlib import Path
base=Path('build/placement-diagnosis')
def run(workload,name,extra):
 print('START',name,flush=True)
 subprocess.run([sys.executable,str(base/'placement-run.py'),workload,name,'--rounds','1','--seconds','12',*extra],check=True)
# Indirect placement control: only read-mostly buffer metadata moves; leaf locks
# remain in ordinary memory. Test whether leaf CAS amplification still changes.
for event in ['basic','locks']:
 for mode,node in [('local',0),('cxl',2)]:
  name=f'xindex-buffer-'+('samples-locks' if event=='locks' else 'basic')+f'-{mode}'
  print('START',name,flush=True)
  options=['--record','locks'] if event=='locks' else ['--group','basic']
  subprocess.run([sys.executable,str(base/'profile.py'),'xindex',name,'--node',str(node),'--binary',str(base/'placements/xindex-buffer/binary'),*options],check=True)
# Fixed workload page-policy counters are separate from workload sweeps.
for group in ['tlb','stall']:
 for mode,node in [('local',0),('cxl',2)]:
  name=f'micro-thp-{group}-{mode}'
  print('START',name,flush=True)
  subprocess.run([sys.executable,str(base/'profile.py'),'micro',name,'--node',str(node),'--group',group],env=dict(os.environ,MALLOC_CONF='thp:always'),check=True)
# Attribute retired taken branches to retry instructions in frozen executables.
for workload in ['xindex','micro']:
 for mode,node in [('local',0),('cxl',2)]:
  name=f'{workload}-samples-branches-{mode}'
  print('START',name,flush=True)
  subprocess.run([sys.executable,str(base/'profile.py'),workload,name,'--node',str(node),'--record','branches'],check=True)
for mode,node in [('local',0),('cxl',2)]:
 name=f'xindex-samples-instructions-{mode}'
 print('START',name,flush=True)
 subprocess.run([sys.executable,str(base/'profile.py'),'xindex',name,'--node',str(node),'--record','instructions'],check=True)
# Diagnostic workload arguments only. Each Local/CXL pair uses identical args;
# these rows are not pooled with the fixed workload's placement confirmations.
for threads in [1,8,16]:
 run('micro',f'diagnostic-micro-threads{threads}',['--victims',str(threads)])
for table in [1,4,16,64,4096,32768,262144,1048576]:
 run('micro',f'diagnostic-micro-table{table}',['--table',str(table)])
for reads in [0,100]:run('micro',f'diagnostic-micro-reads{reads}',['--reads',str(reads)])
for reads in [0,50,100]:run('micro',f'diagnostic-micro-no-ballast-r{reads}',['--ballast','0','--reads',str(reads)])
run('micro','diagnostic-micro-maint',['--victims','30','--noise','2','--noise-mode','maint'])
run('micro','diagnostic-micro-spin',['--victims','31','--noise','1','--noise-mode','spin'])
run('micro','diagnostic-micro-combined',['--victims','30','--noise','2','--noise-mode','combined'])
for threads in [31,32]:run('xindex',f'diagnostic-xindex-bg0-fg{threads}',['--fg',str(threads),'--bg','0'])
for threads in [8,1]:run('xindex',f'diagnostic-xindex-threads{threads}',['--fg',str(threads)])
print('DIAGNOSTIC SWEEP DONE',flush=True)

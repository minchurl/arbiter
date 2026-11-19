import subprocess,sys
from pathlib import Path
base=Path('build/placement-diagnosis')
for event in ['cycles','memory','locks']:
 for workload in ['xindex','micro']:
  for mode,node in [('local',0),('cxl',2)]:
   name=f'{workload}-samples-{event}-{mode}'
   print('START',name,flush=True)
   subprocess.run([sys.executable,str(base/'profile.py'),workload,name,'--node',str(node),'--record',event],check=True)
print('SAMPLING DONE',flush=True)

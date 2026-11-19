import subprocess,sys
from pathlib import Path
base=Path('build/placement-diagnosis')
for group in ['basic','stall','tlb','offcore','rfo']:
    for workload in ['xindex','micro']:
        modes=[('local',0),('cxl',2)] if group in ['basic','offcore'] else [('cxl',2),('local',0)]
        for mode,node in modes:
            name=f'{workload}-{group}-{mode}-r2'
            print('START',name,flush=True)
            subprocess.run([sys.executable,str(base/'profile.py'),workload,name,'--node',str(node),'--group',group],check=True)
print('ALL INITIAL PROFILES DONE',flush=True)

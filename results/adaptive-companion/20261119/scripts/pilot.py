import subprocess,sys
from pathlib import Path
base=Path('build/adaptive-companion')
for name,table,seconds,modes in [('pilot-v2-control',16,20,['plain','observe']),('pilot-v2-h16',16,120,['adapt']),('pilot-v2-h256',256,100,['adapt'])]:
 cmd=[sys.executable,str(base/'scripts/run.py'),name,'--table',str(table),'--seconds',str(seconds),'--modes',*modes]
 print('START',name,flush=True);subprocess.run(cmd,check=True)
print('PILOTS FINISHED',flush=True)

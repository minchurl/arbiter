import subprocess,sys
from pathlib import Path
base=Path('build/adaptive-companion')
print('RESUME: prior confirmation/neighbor cases retained; interrupted short-h16 excluded in full.',flush=True)
for case,table,seconds,modes,phase in [('short-h16',16,30,['plain','observe','adapt'],0),('short-h256',256,30,['plain','observe','adapt'],0),('phase-affinity',16,180,['observe','adapt'],90)]:
 print('START',case,flush=True)
 cmd=[sys.executable,str(base/'scripts/run.py'),case,'--table',str(table),'--seconds',str(seconds),'--rounds','1','--modes',*modes]
 if phase:cmd+=['--phase-after',str(phase)]
 subprocess.run(cmd,check=True)
print('QUEUE FINISHED',flush=True)

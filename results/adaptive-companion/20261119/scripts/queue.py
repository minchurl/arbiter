import subprocess,sys
from pathlib import Path
base=Path('build/adaptive-companion')
cases=[('smoke-final',16,6,1,['observe'],0),('confirm-h16',16,120,3,['plain','observe','adapt'],0),('confirm-h256',256,120,3,['plain','observe','adapt'],0),('neighbor-h8',8,90,1,['observe','adapt'],0),('neighbor-h32',32,90,1,['observe','adapt'],0),('short-h16',16,30,1,['plain','observe','adapt'],0),('short-h256',256,30,1,['plain','observe','adapt'],0),('phase-affinity',16,180,1,['observe','adapt'],90)]
for case,table,seconds,rounds,modes,phase in cases:
 print('START',case,flush=True)
 cmd=[sys.executable,str(base/'scripts/run.py'),case,'--table',str(table),'--seconds',str(seconds),'--rounds',str(rounds),'--modes',*modes]
 if phase:cmd+=['--phase-after',str(phase)]
 subprocess.run(cmd,check=True)
print('QUEUE FINISHED',flush=True)

import subprocess,sys,time
from pathlib import Path
base=Path('build/adaptive-companion')
while 'FOLLOWUPS FINISHED' not in (base/'after.console').read_text():
 if 'Traceback' in (base/'after.console').read_text():raise RuntimeError('Follow-up failed')
 time.sleep(5)
subprocess.run([sys.executable,str(base/'scripts/run.py'),'holdout-readonly','--table','16','--reads','100','--seconds','90','--rounds','2','--modes','observe','adapt'],check=True)
subprocess.run([sys.executable,str(base/'scripts/summarize.py')],check=True)
print('HOLDOUT FINISHED',flush=True)

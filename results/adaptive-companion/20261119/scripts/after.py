import subprocess,sys,time
from pathlib import Path
base=Path('build/adaptive-companion')
while 'QUEUE FINISHED' not in (base/'queue.console').read_text():
 if 'Traceback' in (base/'queue.console').read_text():raise RuntimeError('Queue failed; do not launch follow-ups')
 time.sleep(5)
for script in ['xindex-check','validate-pages','summarize','plot']:
 print('START',script,flush=True);subprocess.run([sys.executable,str(base/'scripts'/(script+'.py'))],check=True)
print('FOLLOWUPS FINISHED',flush=True)

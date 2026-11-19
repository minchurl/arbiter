"""Separate one-entry diagnostics: distinguish pause waiting from CAS retries."""
import subprocess
import sys
from pathlib import Path

base=Path('build/placement-diagnosis')
for group in ['basic','branches']:
    for mode,node in [('local',0),('cxl',2)]:
        name='micro-hot1-'+('samples-branches' if group=='branches' else 'basic')+'-'+mode
        options=['--record','branches'] if group=='branches' else ['--group','basic']
        subprocess.run([sys.executable,str(base/'profile.py'),'micro',name,'--node',str(node),'--table','1',*options],check=True)

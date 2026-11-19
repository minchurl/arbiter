"""Continue serially after sampling; never overlap benchmark processes."""
import subprocess
import sys
import time
from pathlib import Path

base = Path('build/placement-diagnosis')
while True:
    progress = (base / 'sampling-stage.console').read_text()
    if 'Traceback' in progress:
        raise RuntimeError(progress[-4000:])
    if 'SAMPLING DONE' in progress:
        break
    time.sleep(2)

for workload, event in [('xindex', 'memory'), ('xindex', 'hitm'), ('micro', 'hitm')]:
    for mode, node in [('local', 0), ('cxl', 2)]:
        name = f'{workload}-samples-{event}-{mode}-r2'
        print('START', name, flush=True)
        subprocess.run([sys.executable, str(base / 'profile.py'), workload, name, '--node', str(node), '--record', event], check=True)

# Build only when the machine has no measured workload running.
for script in ['build-placements.py', 'placement-screen.py', 'diagnostic-sweep.py']:
    print('STAGE', script, flush=True)
    subprocess.run([sys.executable, str(base / script)], check=True)
print('NEXT STAGES DONE', flush=True)

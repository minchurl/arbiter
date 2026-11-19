"""Record selections and replace the inactive out-of-line RCU control."""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

base = Path('build/placement-diagnosis')
root = Path.cwd()
env = dict(os.environ, LD_LIBRARY_PATH=str(root / '.tools/libtinfo5-root/lib/x86_64-linux-gnu') + ':' + str(root / '.tools/libllvm18-root/usr/lib/x86_64-linux-gnu'), LIBRARY_PATH=str(root / '.tools/libstdcxx') + ':' + str(root / '.tools/libllvm18-root/usr/lib/x86_64-linux-gnu'))
records = json.loads((base / 'placements/manifest.json').read_text())
old = json.loads((base / 'placements/xindex-rcu/manifest.json').read_text())
active = json.loads(json.dumps(old).replace('xindex-rcu/', 'xindex-rcu-active/').replace('-arbiter-hitm-seed-site-ids=2', '-arbiter-hitm-seed-site-ids=25'))
active.update(name='rcu-active', selection='25')
directory = base / 'placements/xindex-rcu-active'
directory.mkdir(exist_ok=False)
for command in active['commands']:
    subprocess.run(command, env=env, check=True)
active.update(rewritten_sha256=hashlib.sha256((directory / 'placed.bc').read_bytes()).hexdigest(), binary_sha256=hashlib.sha256((directory / 'binary').read_bytes()).hexdigest())
records.append(active)
for record in records:
    command = record['commands'][0][:-2] + ['-disable-output']
    command = ['-passes=arbiter-report-hitm-seed-sites' if part.startswith('-passes=') else part for part in command]
    subprocess.run(command, env=env, check=True)
    record['report_command'] = command
    target = base / 'placements' / (record['workload'] + '-' + record['name']) / 'manifest.json'
    target.write_text(json.dumps(record, indent=2) + '\n')
(base / 'placements/manifest.json').write_text(json.dumps(records, indent=2) + '\n')
for placement in ['rcu-active', 'data-array', 'auto-plus-data']:
    subprocess.run([sys.executable, str(base / 'placement-run.py'), 'xindex', 'screen-xindex-' + placement, '--rounds', '1', '--binary', str(base / 'placements' / ('xindex-' + placement) / 'binary')], check=True)
subprocess.run([sys.executable, str(base / 'placement-run.py'), 'xindex', 'screen-xindex-node1', '--rounds', '1', '--nodes', '1'], check=True)
for script in ['diagnostic-sweep.py', 'confirm-fixed.py']:
    print('STAGE', script, flush=True)
    subprocess.run([sys.executable, str(base / script)], check=True)
print('RESUMED STAGES DONE', flush=True)

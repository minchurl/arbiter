"""Confirm, on fresh runs, up to two pre-screened indirect-placement cases."""
import json
import subprocess
import sys
from pathlib import Path

base = Path('build/placement-diagnosis')
screen = json.loads((base / 'cross-hotset-screen.json').read_text())
eligible = [row for row in screen if row['ratio'] >= 1.10]
# Include the strongest effect and the widest qualifying hot set, if different.
choices = []
if eligible:
    choices = list(dict.fromkeys([max(eligible, key=lambda row: row['ratio'])['table'], max(row['table'] for row in eligible)]))
for table in choices:
    case = f'confirm-micro-ballast-hot{table}'
    print('START', case, flush=True)
    subprocess.run([sys.executable, str(base / 'placement-run.py'), 'micro', case, '--binary', str(base / 'placements/micro-ballast/binary'), '--objects', 'ballast', '--table', str(table), '--rounds', '5', '--seconds', '30'], check=True)
(base / 'cross-hotset-confirmation-rule.json').write_text(json.dumps(dict(screen_threshold=1.10, selected_tables=choices, rounds=5, seconds=30, selection_rule='Strongest screen effect and widest qualifying hot set; never claim improvement for unchanged 256-entry baseline.'), indent=2) + '\n')

if choices:
 table=choices[0]
 for group in ['basic','branches']:
  for mode,node in [('local',0),('cxl',2)]:
   name=f'micro-ballast-hot{table}-'+('samples-branches' if group=='branches' else 'basic')+f'-{mode}'
   options=['--record','branches'] if group=='branches' else ['--group','basic']
   subprocess.run([sys.executable,str(base/'profile.py'),'micro',name,'--node',str(node),'--binary',str(base/'placements/micro-ballast/binary'),'--table',str(table),*options],check=True)

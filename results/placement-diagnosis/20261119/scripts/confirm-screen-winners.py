"""Retest the two largest apparent table-placement gains on fresh runs."""
import csv
import json
import subprocess
import sys
from pathlib import Path

base = Path('build/placement-diagnosis')
eligible = []
for path in base.glob('diagnostic-micro-*/runs.csv'):
    values = {int(row['node']): float(row['mops']) for row in csv.DictReader(path.open())}
    if 0 in values and 2 in values and values[2] / values[0] >= 1.03:
        eligible.append((values[2] / values[0], path.parent))
choices = sorted(eligible, reverse=True)[:2]
for ratio, directory in choices:
    args = json.loads((directory / 'manifest.json').read_text())['args']
    case = directory.name.replace('diagnostic-', 'confirm-', 1)
    command = [sys.executable, str(base / 'placement-run.py'), 'micro', case, '--rounds', '5', '--seconds', '30']
    for option in ['victims', 'table', 'ballast', 'reads', 'noise', 'noise_mode']:
        command += ['--' + option.replace('_', '-'), str(args[option])]
    print('START', case, 'screen ratio', ratio, flush=True)
    subprocess.run(command, check=True)
(base / 'table-confirmation-rule.json').write_text(json.dumps(dict(screen_threshold=1.03, selected_cases=[path.name for _, path in choices], rounds=5, seconds=30, rule='At most two highest table-placement ratios; changed input conditions are separate from the fixed 256-entry/32-worker baseline.'), indent=2) + '\n')

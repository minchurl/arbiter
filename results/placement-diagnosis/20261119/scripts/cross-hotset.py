"""Hypothesis test: cold-read delay may moderate a severely contended hot set.

Benchmark code, write mix, ballast size and workers stay frozen. These are
separate input-size cases, never pooled with the 256-entry default workload.
"""
import csv
import json
import subprocess
import sys
from pathlib import Path

base = Path('build/placement-diagnosis')
results = []
for table in [1, 4, 16, 64]:
    case = f'screen-micro-ballast-hot{table}'
    command = [sys.executable, str(base / 'placement-run.py'), 'micro', case, '--binary', str(base / 'placements/micro-ballast/binary'), '--objects', 'ballast', '--table', str(table), '--rounds', '1', '--seconds', '20']
    print('START', case, flush=True)
    subprocess.run(command, check=True)
    values = {int(row['node']): float(row['mops']) for row in csv.DictReader((base / case / 'runs.csv').open())}
    results.append(dict(table=table, local=values[0], cxl=values[2], ratio=values[2] / values[0]))
(base / 'cross-hotset-screen.json').write_text(json.dumps(results, indent=2) + '\n')

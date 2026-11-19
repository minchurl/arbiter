"""Plot retained unprofiled same-process placement interventions."""
import argparse, csv, json, re
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
matplotlib.rcParams['svg.hashsalt'] = 'placement-causality-20261119'
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

parser = argparse.ArgumentParser()
parser.add_argument('--directory', type=Path, default=Path('results/placement-causality/20261119'))
args = parser.parse_args()
base = args.directory
cases = [
    ('confirm-cold-local', 'Cold buffers: DRAM → CXL → DRAM → CXL → DRAM'),
    ('confirm-cold-cxl', 'Cold buffers: CXL → DRAM → CXL → DRAM → CXL'),
    ('confirm-hot-local', 'Hot leaf/buffer pages only; remaining objects in DRAM'),
    ('confirm-hot-cxl', 'Hot leaf/buffer pages only; remaining selected objects in CXL'),
    ('confirm-cold-node1', 'Cold buffers: DRAM ↔ other memory node 1'),
    ('confirm-cold-16fg', '16 workers: DRAM → cold-buffer CXL → DRAM'),
]
colors = {0: '#b76b20', 1: '#7851a9', 2: '#156eab'}
fig, axes = plt.subplots(3, 2, figsize=(12, 10.5), constrained_layout=True)
for ax, (name, title) in zip(axes.flat, cases):
    directory = base / name
    manifest = json.loads((directory / 'manifest.json').read_text())
    assert manifest['valid']
    phases = json.loads((directory / 'phases.json').read_text())
    rows = list(csv.DictReader((directory / 'phase-summary.csv').open()))
    points = []
    for match in re.finditer(r'Throughput sample (elapsed_sec=.*)', (directory / 'output.log').read_text()):
        points.append({k: float(v) for k, v in re.findall(r'(\w+)=([^\s]+)', match[1])})
    ax.plot([p['elapsed_sec'] for p in points], [p['interval_ops_per_sec'] / 1e6 for p in points], color='#525b66', linewidth=.9, alpha=.8)
    for phase, row in zip(phases, rows):
        node = manifest['args']['node']
        if phase['name'] != 'baseline':
            node = manifest['args'].get('alternate_node') if manifest['args'].get('alternate_node') is not None else (2 if node == 0 else 0)
        lo, hi = phase['stable_from_elapsed'], phase['end_elapsed']
        ax.axvspan(lo, hi, color=colors[node], alpha=.12)
        ax.axvspan(phase['start_elapsed'], lo, color='#999999', alpha=.23)
        mops = float(row['mops'])
        ax.hlines(mops, lo, hi, color=colors[node], linewidth=2.7)
        ax.text((lo + hi) / 2, mops + 1.3, f'{mops:.1f}', ha='center', fontsize=9, color=colors[node])
    ax.set_title(title, fontsize=10, loc='left', pad=10)
    ax.set_xlabel('Seconds after workload start')
    ax.set_ylabel('Throughput (Mops/s)')
    ax.set_xlim(phases[0]['start_elapsed'] - 2, phases[-1]['end_elapsed'] + 1)
    ax.set_ylim(0, 66)
    ax.spines[['top', 'right']].set_visible(False)
    ax.grid(axis='y', alpha=.2)
fig.suptitle('XIndex: reversible page placement in the same running process', fontsize=15)
fig.legend(handles=[Line2D([0], [0], color=colors[0], lw=3, label='Intervention pages in DRAM'), Line2D([0], [0], color=colors[2], lw=3, label='Intervention pages in CXL'), Line2D([0], [0], color=colors[1], lw=3, label='Intervention pages in node 1'), Line2D([0], [0], color='#999999', lw=6, alpha=.4, label='Migration + 2 s excluded')], loc='outside lower center', ncol=2, frameon=False, fontsize=9)
fig.savefig(base / 'placement-crossover.png', dpi=180)
fig.savefig(base / 'placement-crossover.svg', metadata={'Date': None})
svg = base / 'placement-crossover.svg'
svg.write_text('\n'.join(line.rstrip() for line in svg.read_text().splitlines()) + '\n')
plt.close(fig)

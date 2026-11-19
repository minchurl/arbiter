"""Regenerate the scientific figure from retained CSVs, without perf binaries."""
import csv
import statistics
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

out = Path('results/placement-diagnosis/20261119')
rows = list(csv.DictReader((out / 'runs.csv').open()))
positions = list(csv.DictReader((out / 'sample-positions.csv').open()))
colors = ['#2468a0', '#d97820']
plt.rcParams.update({'font.size': 10, 'axes.spines.top': False, 'axes.spines.right': False, 'svg.fonttype': 'none', 'svg.hashsalt': 'arbiter-placement-diagnosis-20261119'})


def values(case, node):
    return [float(row['mops']) for row in rows if row['case'] == case and int(row['node']) == node]


def paired_ratios(case):
    by_round = {}
    for row in rows:
        if row['case'] == case:
            by_round.setdefault(row['round'], {})[int(row['node'])] = float(row['mops'])
    return [modes[2] / modes[0] for modes in by_round.values() if 0 in modes and 2 in modes]


def branch(case, function, offset):
    return sum(float(row['period_per_operation']) for row in positions if row['case'] == case and function in row['symbol_offset'] and row['symbol_offset'].endswith(offset))


fig, axes = plt.subplots(2, 2, figsize=(12.8, 8.6), constrained_layout=True)
ax = axes[0, 0]
cases = ['confirm-xindex-baseline', 'confirm-micro-baseline']
labels = []
for index, case in enumerate(cases):
    local, cxl = values(case, 0), values(case, 2)
    ratio = statistics.mean(cxl) / statistics.mean(local)
    pairs = paired_ratios(case)
    ax.bar(index, ratio, color=colors[1], width=.5)
    ax.errorbar(index, ratio, yerr=[[ratio-min(pairs)], [max(pairs)-ratio]], color='#333333', capsize=5)
    ax.text(index, max(pairs) + .06, f'{ratio:.3f}x', ha='center', fontweight='bold')
    labels.append(('XIndex A' if 'xindex' in case else 'Micro, 256 entries') + f'\n{statistics.mean(local):.1f} -> {statistics.mean(cxl):.1f} Mops/s\n{len(local)} paired runs')
ax.axhline(1, color='#888888', linestyle='--', linewidth=1)
ax.set_xticks([0, 1], labels)
ax.set_ylim(0, max(2.2, ax.get_ylim()[1] + .15))
ax.set_ylabel('CXL / Local throughput')
ax.set_title('A. Fixed workloads, no performance counters', loc='left')
ax.text(.02, .98, 'Bars: ratio of means; whiskers: paired min/max', transform=ax.transAxes, va='top', fontsize=8, color='#555555')

ax = axes[0, 1]
categories = [('xindex', '::put(', '+0x279'), ('xindex', '::get(', '+0x141'), ('micro', 'victim_thread(', '+0x18a')]
for shift, mode, color in [(-.18, 'local', colors[0]), (.18, 'cxl', colors[1])]:
    numbers = [branch(f'{workload}-samples-branches-{mode}', function, offset) for workload, function, offset in categories]
    ax.bar(np.arange(3) + shift, numbers, width=.34, label='Local' if mode=='local' else 'CXL', color=color)
    for i, number in enumerate(numbers):
        ax.text(i + shift, number + .016, f'{number:.3f}', ha='center', fontsize=9)
ax.set_xticks(range(3), ['XIndex leaf\nCAS failure', 'XIndex reader\nleaf retry', 'Micro\nCAS failure'])
ax.set_ylim(0, 1.08)
ax.set_ylabel('Estimated taken branches / operation')
ax.set_title('B. Retired retry branches in unchanged code', loc='left')
ax.legend(frameon=False)
ax.text(.02, .98, 'Separate PEBS diagnostic pair; period 100,003', transform=ax.transAxes, va='top', fontsize=8, color='#555555')

ax = axes[1, 0]
for node, label, color in [(0, 'Local', colors[0]), (2, 'CXL', colors[1])]:
    points = [(1, statistics.mean(values('diagnostic-xindex-threads1', node))), (8, statistics.mean(values('diagnostic-xindex-threads8', node))), (31, statistics.mean(values('confirm-xindex-baseline', node)))]
    ax.plot([p[0] for p in points], [p[1] for p in points], 'o-', label=label, color=color)
ax.set_xticks([1, 8, 16, 24, 31])
ax.set_xlabel('XIndex foreground workers (--bg 1)')
ax.set_ylabel('Throughput (Mops/s)')
ax.set_ylim(bottom=0)
ax.set_title('C. Concurrency changes the placement tradeoff', loc='left')
ax.legend(frameon=False, loc='upper left', bbox_to_anchor=(.01,.93))
ax.text(.02, .98, '1 and 8 workers: single diagnostic pair each', transform=ax.transAxes, va='top', fontsize=8, color='#555555')

ax = axes[1, 1]
sizes = [1, 4, 16, 64, 256, 4096, 32768, 262144, 1048576]
for node, label, color in [(0, 'Local table', colors[0]), (2, 'CXL table', colors[1])]:
    numbers = []
    for size in sizes:
        case = 'confirm-micro-baseline' if size == 256 else ('confirm-micro-table1' if size == 1 and values('confirm-micro-table1', node) else f'diagnostic-micro-table{size}')
        numbers.append(statistics.mean(values(case, node)))
    ax.plot(sizes, numbers, 'o-', label=label, color=color)
ax.set_xscale('log', base=2)
ax.set_xticks([1, 16, 256, 4096, 65536, 1048576], ['1', '16', '256', '4K', '64K', '1M'])
ax.set_xlabel('Micro table entries (64 bytes each); 8 GiB Local ballast')
ax.set_ylabel('Throughput (Mops/s)')
ax.set_ylim(bottom=0)
ax.set_title('D. Separate hot-set diagnostic workloads', loc='left')
ax.legend(frameon=False, loc='upper left', bbox_to_anchor=(.01,.93))
ax.text(.02, .98, 'Single screen pair per size, except 1 and 256 entries', transform=ax.transAxes, va='top', fontsize=8, color='#555555')
fig.suptitle('Frozen benchmark code: XIndex CXL gain tracks fewer retries; micro shows no repeatable placement gain', fontsize=13, fontweight='bold')
fig.savefig(out / 'performance.png', dpi=170)
fig.savefig(out / 'performance.svg', metadata={'Date': None})
plt.close(fig)

# Conditional indirect-placement results are explicitly separated from default.
conditional = sorted({row['case'] for row in rows if row['case'].startswith('confirm-micro-ballast-hot')})
if conditional:
    fig, ax = plt.subplots(figsize=(8, 4.8), constrained_layout=True)
    for i, case in enumerate(conditional):
        local, cxl = values(case, 0), values(case, 2)
        for shift, numbers, color in [(-.18, local, colors[0]), (.18, cxl, colors[1])]:
            mean = statistics.mean(numbers)
            ax.bar(i+shift, mean, width=.34, color=color, label=('Local ballast' if shift<0 else 'CXL ballast') if i==0 else None)
            ax.errorbar(i+shift, mean, yerr=[[mean-min(numbers)],[max(numbers)-mean]], capsize=4, color='#333333')
    ax.set_xticks(range(len(conditional)), [f"{case.split('hot')[-1]} entries\n{len(values(case,0))} runs per mode" for case in conditional])
    ax.set_ylabel('Throughput (Mops/s)')
    ax.set_title('Conditional ballast placement: separate tiny hot-set workloads', loc='left')
    ax.legend(frameon=False)
    ax.text(.02,.98,'Table stays on node 0. These are not the 256-entry baseline.',transform=ax.transAxes,va='top',fontsize=9)
    fig.savefig(out / 'conditional-placement.png', dpi=170)
    fig.savefig(out / 'conditional-placement.svg', metadata={'Date': None})

for path in out.glob('*.svg'):
    path.write_text('\n'.join(line.rstrip() for line in path.read_text().splitlines())+'\n')

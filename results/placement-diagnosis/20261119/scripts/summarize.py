"""Summarize retained tables; profile throughput never enters placement means."""
import csv
import json
from pathlib import Path
import statistics

base = Path('results/placement-diagnosis/20261119')
rows = list(csv.DictReader((base / 'runs.csv').open()))
positions = list(csv.DictReader((base / 'sample-positions.csv').open()))
symbols = list(csv.DictReader((base / 'sample-symbols.csv').open()))
objects = list(csv.DictReader((base / 'sample-objects.csv').open()))

def position(case, function, offset):
    matches = [row for row in positions if row['case'] == case and function in row['symbol_offset'] and row['symbol_offset'].endswith(offset)]
    assert len(matches) == 1, (case, function, offset, matches)
    return dict(samples=int(matches[0]['samples']), estimated_events_per_operation=float(matches[0]['period_per_operation']))

branches = {}
for mode in ['local', 'cxl']:
    branches[mode] = {
        'xindex_leaf_cas_failure': position('xindex-samples-branches-' + mode, '::put(', '+0x279'),
        'xindex_reader_locked_leaf': position('xindex-samples-branches-' + mode, '::get(', '+0x141'),
        'micro_cas_failure': position('micro-samples-branches-' + mode, 'victim_thread(', '+0x18a'),
        'micro_reader_lock_wait': position('micro-samples-branches-' + mode, 'victim_thread(', '+0x149'),
        'micro_writer_lock_wait': position('micro-samples-branches-' + mode, 'victim_thread(', '+0x179'),
        'micro_reader_version_retry': position('micro-samples-branches-' + mode, 'victim_thread(', '+0x155'),
    }
instructions = {}
hotset_branches = {}
for mode in ['local','cxl']:
    hotset_branches[mode] = dict(writer_pause_wait=position('micro-hot1-samples-branches-'+mode,'victim_thread(','+0x179'),reader_pause_wait=position('micro-hot1-samples-branches-'+mode,'victim_thread(','+0x149'),cas_failure=position('micro-hot1-samples-branches-'+mode,'victim_thread(','+0x18a'))
for mode in ['local', 'cxl']:
    found = [row for row in symbols if row['case'] == 'xindex-samples-instructions-' + mode]
    total = sum(float(row['period_per_operation']) for row in found)
    coordinator = sum(float(row['period_per_operation']) for row in found if '::background(' in row['symbol'])
    maintenance = sum(float(row['period_per_operation']) for row in found if '::do_maintenance(' in row['symbol'])
    instructions[mode] = dict(total=total, background_coordinator=coordinator, maintenance=maintenance, remaining_symbols=total-coordinator-maintenance)

confirmations = []
for case in sorted({row['case'] for row in rows if row['phase'] == 'confirm'}):
    found = [row for row in rows if row['case'] == case]
    groups = {}
    pairs = {}
    for row in found:
        groups.setdefault(row['node'], []).append(float(row['mops']))
        pairs.setdefault(row['round'], {})[row['node']] = float(row['mops'])
    local = statistics.mean(groups['0'])
    for node, values in groups.items():
        ratios = [modes[node] / modes['0'] for modes in pairs.values() if node in modes and '0' in modes]
        confirmations.append(dict(case=case, node=int(node), n=len(values), mean_mops=statistics.mean(values), min_mops=min(values), max_mops=max(values), ratio_to_local=statistics.mean(values)/local, paired_ratio_min=min(ratios), paired_ratio_max=max(ratios)))

result = dict(confirmations=confirmations, retired_branch_samples=branches, one_entry_micro_branch_control=hotset_branches, xindex_instruction_samples_per_operation=instructions, micro_hitm_object_attribution=[row for row in objects if row['case'].startswith('micro-samples-hitm-')], interpretation_limits=['Branch values are PEBS period-weighted estimates, not software operation counters.', 'Remaining instruction symbols are not exclusively foreground instructions.', 'Fresh uninstrumented confirmations are separate from diagnostic profiles and screens.', 'Changed CLI inputs are separate workloads; they do not establish gains for the fixed baseline.'])
(base / 'mechanism-summary.json').write_text(json.dumps(result, indent=2) + '\n')
for row in confirmations:
    if row['node'] != 0:
        print(row['case'], 'node', row['node'], f"{row['mean_mops']:.3f} Mops/s, {(row['ratio_to_local']-1)*100:+.2f}%", 'paired range', f"{row['paired_ratio_min']:.4f}..{row['paired_ratio_max']:.4f}")

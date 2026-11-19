"""Regenerate cross-workload diagnostic summaries from archived measurements."""
import argparse, collections, csv, json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--directory', type=Path, default=Path('results/placement-causality/20261119'))
args = parser.parse_args()
base = args.directory

def write_csv(name, rows):
    if not rows:
        return
    with (base / name).open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)

summary = {}
retry = base / 'profile-cold-local-r2'
phase_rows = {int(r['phase']): r for r in csv.DictReader((retry / 'phase-summary.csv').open())}
events = list(csv.DictReader((retry / 'phase-events.csv').open()))
for mode, phases in [('cold_in_dram', [0, 2, 4]), ('cold_in_cxl', [1, 3])]:
    operations = sum(int(phase_rows[p]['operations']) for p in phases)
    seconds = sum(float(phase_rows[p]['seconds']) for p in phases)
    selected = [r for r in events if int(r['phase']) in phases]
    counts = collections.Counter()
    for row in selected:
        counts[row['event'], row['category']] += int(row['estimated_events'])
    total_cycles = sum(value for (event, _), value in counts.items() if event == 'cycles')
    summary[mode] = dict(operations=operations, seconds=seconds, mops=operations / seconds / 1e6,
        failed_leaf_cas_per_op=counts['branch', 'failed_leaf_cas'] / operations,
        reader_locked_leaf_retry_per_op=counts['branch', 'reader_locked_leaf_retry'] / operations,
        leaf_cas_attempt_per_op=counts['locks', 'leaf_cas_attempt'] / operations,
        hottest_leaf_cas_attempt_per_op=counts['locks', 'hottest_leaf_cas_attempt'] / operations,
        value_cas_per_op=counts['locks', 'value_cas'] / operations,
        total_locked_loads_per_op=sum(value for (event, category), value in counts.items() if event == 'locks' and category != 'hottest_leaf_cas_attempt') / operations,
        cycles_per_op=total_cycles / operations,
        leaf_tas_loop_cycle_fraction=counts['cycles', 'leaf_tas_loop'] / total_cycles)

latency_rows = list(csv.DictReader((base / 'profile-cold-memory/phase-latencies.csv').open()))
memory_summary = []
for mode, phases in [('cold_in_dram', [0, 2, 4]), ('cold_in_cxl', [1, 3])]:
    for obj, metric in sorted({(r['object'],r['metric']) for r in latency_rows}):
        rows = [r for r in latency_rows if int(r['phase']) in phases and r['object'] == obj and r['metric'] == metric]
        count = sum(int(r['samples']) for r in rows)
        if count:
            memory_summary.append(dict(mode=mode, object=obj, metric=metric, samples=count, conditional_mean_cycles=sum(int(r['samples']) * float(r['conditional_mean_cycles']) for r in rows) / count))
write_csv('memory-summary.csv', memory_summary)

cache_rows = []
counter_events = ['cycles:u', 'instructions:u', 'mem_inst_retired.all_loads:u', 'mem_load_retired.l3_miss:u', 'mem_inst_retired.lock_loads:u']
def counters(path):
    result = {}
    for row in csv.reader(path.open()):
        if len(row) >= 5 and row[2] in counter_events:
            assert float(row[4]) > 99.5, row
            result[row[2]] = float(row[0])
    assert len(result) == 5
    return result

for path in sorted((base / 'profile-cold-counters').glob('phase-*.stat.json')):
    m = json.loads(path.read_text())
    assert m['tids_before'] == m['tids_after'] and len(m['tids_after']) == 32
    count = counters(path.with_name(path.name.replace('.stat.json', '.perf.csv')))
    cache_rows.append(dict(workload='xindex_buffer_only', mode='cold_in_dram' if m['name'] == 'baseline' else 'cold_in_cxl', phase=m['phase'], all_workers_active=True, window_seconds=5, retired_loads=count['mem_inst_retired.all_loads:u'], l3_misses=count['mem_load_retired.l3_miss:u'], l3_misses_per_1000_loads=1000 * count['mem_load_retired.l3_miss:u'] / count['mem_inst_retired.all_loads:u'], cycles=count['cycles:u'], instructions=count['instructions:u'], locked_loads=count['mem_inst_retired.lock_loads:u']))
for path in sorted((base / 'cuckoo-cache').glob('*.manifest.json')):
    m = json.loads(path.read_text())
    assert m['valid'] and m['all_workers_active']
    count = m['counters']
    cache_rows.append(dict(workload='libcuckoo_hot' + str(m['hot']), mode=m['mode'], phase='', all_workers_active=m['all_workers_active'], window_seconds=5, retired_loads=count['mem_inst_retired.all_loads:u'], l3_misses=count['mem_load_retired.l3_miss:u'], l3_misses_per_1000_loads=m['llc_misses_per_1000_loads'], cycles=count['cycles:u'], instructions=count['instructions:u'], locked_loads=count['mem_inst_retired.lock_loads:u']))
write_csv('cache-summary.csv', cache_rows)
(base / 'mechanism-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
print('Memory:', memory_summary)
print('Cache:', [(r['workload'], r['mode'], r['l3_misses_per_1000_loads']) for r in cache_rows])

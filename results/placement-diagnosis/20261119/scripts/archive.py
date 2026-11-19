"""Archive completed diagnostics compactly; execute after benchmark processes exit."""
import csv
import gzip
import hashlib
import json
import shutil
import statistics
from pathlib import Path

BASE = Path('build/placement-diagnosis')
OUT = Path('results/placement-diagnosis/20261119')
OUT.mkdir(parents=True, exist_ok=True)


def csv_file(path, rows):
    if not rows:
        return
    fields = list(dict.fromkeys(key for row in rows for key in row))
    opener = gzip.open if path.suffix == '.gz' else open
    with opener(path, 'wt') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)


def json_file(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def json_lines(path, rows):
    opener = gzip.open if path.suffix == '.gz' else open
    with opener(path, 'wt') as stream:
        for row in rows:
            stream.write(json.dumps(row) + '\n')


runs, experiments, raw_runs, profiles, counters, perf_hashes = [], [], [], [], [], []
rejected_runs = []
symbols, positions, objects = [], [], []
for directory in sorted(BASE.iterdir()):
    manifest_path = directory / 'manifest.json'
    if not directory.is_dir() or not manifest_path.exists() or directory.name in {'placements', 'interleave-runtime'}:
        continue
    manifest = json.loads(manifest_path.read_text())
    case = directory.name
    args = manifest.get('args', {})
    if (directory / 'runs.csv').exists():
        phase = case.split('-')[0]
        experiments.append(dict(case=case, phase=phase, **manifest))
        for row in csv.DictReader((directory / 'runs.csv').open()):
            interleaved = args.get('interleaved', False)
            selected_nodes = sorted({0, int(row['node'])}) if interleaved else [int(row['node'])]
            result = dict(case=case, phase=phase, workload=args['workload'], extent_policy='interleave' if interleaved else 'bind', selected_node_mask=','.join(map(str,selected_nodes)), **row)
            runs.append(result)
            stem = directory / f"{row['round']}-node{row['node']}"
            live = {path.name: path.read_text() for path in directory.glob(stem.name+'.live.*')}
            raw_runs.append(dict(case=case, round=row['round'], node=row['node'], command=json.loads(stem.with_suffix('.command.json').read_text()), output=stem.with_suffix('.log').read_text(), time=stem.with_suffix('.time').read_text(), live_mapping_snapshots=live))
    elif 'command' in manifest:
        files = {}
        for path in directory.iterdir():
            if path.is_file() and path.name != 'perf.data' and path.suffix != '.gz':
                files[path.name] = path.read_text()
        profiles.append(dict(case=case, manifest=manifest, files=files))
        if manifest.get('valid') and not args.get('record'):
            for event, count in manifest['counters'].items():
                counters.append(dict(case=case, workload=args['workload'], node=args['node'], group=args['group'], operations=manifest['operations'], seconds=manifest['seconds'], event=event, count=count, per_operation=count / manifest['operations'], fraction_of_cycles=count / manifest['counters']['cycles:u']))
        if (directory / 'perf.data').exists():
            path = directory / 'perf.data'
            perf_hashes.append(dict(case=case, path=str(path), bytes=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        for name, destination in [('symbol-summary.csv', symbols), ('ip-summary.csv', positions), ('object-summary.csv', objects)]:
            path = directory / name
            if path.exists():
                for row in csv.DictReader(path.open()):
                    destination.append(dict(case=case, workload=args['workload'], record=args['record'], node=args['node'], **row))
    else:
        # Preserve placement attempts rejected before the first validated row.
        files = {path.name: path.read_text() for path in directory.iterdir() if path.is_file()}
        rejected_runs.append(dict(case=case, manifest=manifest, files=files))

csv_file(OUT / 'runs.csv', runs)
json_lines(OUT / 'experiments.jsonl', experiments)
json_lines(OUT / 'raw-runs.jsonl.gz', raw_runs)
json_lines(OUT / 'profiles.jsonl.gz', profiles)
json_lines(OUT / 'rejected-runs.jsonl.gz', rejected_runs)
csv_file(OUT / 'counters.csv', counters)
csv_file(OUT / 'perf-file-hashes.csv', perf_hashes)
csv_file(OUT / 'sample-symbols.csv', symbols)
csv_file(OUT / 'sample-positions.csv', positions)
csv_file(OUT / 'sample-objects.csv', objects)

# Stream the full decoded samples; avoid materializing all recordings together.
fields = ['case', 'period', 'event', 'ip', 'symbol_offset', 'address', 'latency_cycles', 'data_source', 'data_source_raw', 'symbol', 'object']
with gzip.open(OUT / 'samples.csv.gz', 'wt') as stream:
    writer = csv.DictWriter(stream, fieldnames=fields, lineterminator='\n')
    writer.writeheader()
    for path in sorted(BASE.glob('*/samples.csv.gz')):
        with gzip.open(path, 'rt') as source:
            for row in csv.DictReader(source):
                writer.writerow(dict(case=path.parent.name, **row))

groups = {}
for row in runs:
    groups.setdefault((row['case'], row['node']), []).append(float(row['mops']))
summary = []
for (case, node), values in groups.items():
    local = groups.get((case, '0'))
    summary.append(dict(case=case, node=node, n=len(values), mean_mops=statistics.mean(values), min_mops=min(values), max_mops=max(values), ratio_to_same_case_local=statistics.mean(values) / statistics.mean(local) if local else ''))
csv_file(OUT / 'placement-summary.csv', summary)

for name in ['environment.json', 'frozen-inputs.json', 'neutral-rewrite-check.json', 'micro-worker-equivalence.json', 'trace-sample.json', 'checks.json', 'xindex-address-attribution.csv', 'hot-leaf-samples.csv', 'cross-hotset-screen.json', 'cross-hotset-confirmation-rule.json', 'table-confirmation-rule.json', 'interleave-screen.json', 'manifest.json', 'mechanism-summary.json']:
    path = BASE / name
    if path.exists():
        shutil.copy2(path, OUT / name)
for path in BASE.glob('micro-worker-*.asm'):
    shutil.copy2(path, OUT / path.name)
if (BASE / 'interleave-runtime/manifest.json').exists():
    shutil.copy2(BASE / 'interleave-runtime/manifest.json', OUT / 'interleave-runtime.json')
    shutil.copy2(BASE / 'interleave-runtime/runtime.patch', OUT / 'interleave-runtime.patch')
shutil.copy2(BASE / 'placements/manifest.json', OUT / 'variants.json')
selection = []
for path in sorted((BASE / 'placements').glob('*/selection.csv')):
    for row in csv.DictReader(path.open()):
        selection.append(dict(variant=path.parent.name, **row))
csv_file(OUT / 'variant-selection.csv', selection)
json_file(OUT / 'probe-output.json', {p.name: p.read_text() for p in BASE.glob('uncore-*')})
json_file(OUT / 'stage-output.json', {p.name: p.read_text() for p in BASE.glob('*.console')})
scripts = OUT / 'scripts'
scripts.mkdir(exist_ok=True)
for path in BASE.glob('*.py'):
    if path.name not in {'write-report.py', 'finish.py'}:
        shutil.copy2(path, scripts / path.name)
print('Archived', len(runs), 'throughput runs and', len(profiles), 'profiles to', OUT)

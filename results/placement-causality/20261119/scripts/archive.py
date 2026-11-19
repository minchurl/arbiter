"""Archive unchanged-code experiments without duplicating huge page lists/perf data."""
import collections, csv, gzip, hashlib, json, shutil, subprocess
from pathlib import Path

ROOT = Path.cwd()
BASE = ROOT / 'build/xindex-contention-cause-20261119'
OUT = ROOT / 'results/placement-causality/20261119'
OUT.mkdir(parents=True, exist_ok=True)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def dump(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')

def ranges(pages):
    result = []
    for page in pages:
        if result and result[-1][0] + result[-1][1] * 4096 == page:
            result[-1][1] += 1
        else:
            result.append([page, 1])
    return result

frozen = json.loads((BASE / 'manifest.json').read_text())
checks = dict(frozen_files={}, cases={}, perf_files={}, page_encoding='Runs are [first_byte_address, count_of_4096_byte_pages]; initial_nodes runs additionally carry the NUMA node.')
for name, expected in frozen['files'].items():
    actual = digest((ROOT / name).read_bytes())
    assert actual == expected, name
    checks['frozen_files'][name] = actual
checks['trace_metadata'] = {}
for name, expected in frozen['traces'].items():
    stat = Path(name).stat()
    actual = dict(size=stat.st_size, mtime_ns=stat.st_mtime_ns, inode=stat.st_ino)
    assert actual == expected, name
    checks['trace_metadata'][name] = actual
upstream = ROOT / 'benchmark/libcuckoo/libcuckoo-upstream'
checks['upstream_revision'] = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
expected_upstream = json.loads((ROOT / 'results/libcuckoo/write-heavy-20261119/manifest.json').read_text())['upstream_revision']
assert checks['upstream_revision'] == expected_upstream
checks['upstream_status'] = subprocess.check_output(['git', '-C', str(upstream), 'status', '--short'], text=True)
assert not checks['upstream_status']
for path in BASE.glob('*.json'):
    shutil.copyfile(path, OUT / path.name)
scripts = OUT / 'scripts'
scripts.mkdir(exist_ok=True)
for path in BASE.glob('*.py'):
    shutil.copyfile(path, scripts / path.name)
for path in BASE.glob('*.console'):
    shutil.copyfile(path, OUT / path.name)
for path in BASE.glob('*.asm'):
    (OUT / path.name).write_text('\n'.join(line.rstrip() for line in path.read_text().splitlines()) + '\n')
phase_rows = []
for case in sorted(BASE.iterdir()):
    if not case.is_dir():
        continue
    dest = OUT / case.name
    dest.mkdir(exist_ok=True)
    for path in case.iterdir():
        if not path.is_file() or path.name in ['page-sets.json.gz', 'perf.data']:
            continue
        if path.suffix in ['.data', '.old']:
            continue
        shutil.copyfile(path, dest / path.name)
    pagefile = case / 'page-sets.json.gz'
    if pagefile.exists():
        original_bytes = gzip.decompress(pagefile.read_bytes())
        original = json.loads(original_bytes)
        encoded = dict(groups={key: ranges(pages) for key, pages in original['groups'].items()}, initial_nodes=[])
        for address, node in original['initial_nodes'].items():
            address = int(address)
            last = encoded['initial_nodes'][-1] if encoded['initial_nodes'] else None
            if last and last[0] + 4096 * last[1] == address and last[2] == node:
                last[1] += 1
            else:
                encoded['initial_nodes'].append([address, 1, node])
        restored = dict(groups={key: [start + 4096 * i for start, count in runs for i in range(count)] for key, runs in encoded['groups'].items()}, initial_nodes={str(start + 4096 * i): node for start, count, node in encoded['initial_nodes'] for i in range(count)})
        assert json.dumps(restored).encode() == original_bytes
        encoded.update(original_json_sha256=digest(original_bytes), original_gzip_sha256=digest(pagefile.read_bytes()))
        (dest / 'page-sets.rle.json.gz').write_bytes(gzip.compress(json.dumps(encoded).encode(), mtime=0))
    perf = case / 'perf.data'
    if perf.exists():
        checks['perf_files'][str(perf.relative_to(ROOT))] = dict(sha256=digest(perf.read_bytes()), bytes=perf.stat().st_size)
    manifest_path = case / 'manifest.json'
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text())
        info = dict(valid=manifest.get('valid', False), rejected=(case / 'rejected.json').exists())
        if info['valid']:
            log = (case / 'output.log').read_text()
            assert 'digest=0x7474b8e9d3962859' in log and 'failed_reads=0' in log and 'fallback_allocations=0' in log
            initial = manifest.get('initial_node_counts') or {str(k): v for k, v in collections.Counter(manifest['initial_nodes'].values()).items()}
            for key in ['restore', 'final_query']:
                result = manifest[key]
                counts = result.get('status_counts') or {str(k): v for k, v in collections.Counter(result['status']).items()}
                assert counts == initial

            phases = json.loads((case / 'phases.json').read_text())
            def status_fingerprint(result):
                return result.get('status_sha256') or result['status']
            assert all(status_fingerprint(left['after']) == status_fingerprint(right['before']) for left, right in zip(phases, phases[1:]))
            info['placement_unchanged_between_phase_endpoint_checks'] = True
            objects = json.loads((case / 'objects.json').read_text())
            if manifest['args'].get('bulk'):
                moved = set(original['groups']['coldbuffer'])
                assert not moved.intersection(row['buffer'] // 4096 * 4096 for row in objects if row['buffer'])
                assert not moved.intersection(row['leaf'] // 4096 * 4096 for row in objects if row['leaf'])
                assert not moved.intersection(row['record'] // 4096 * 4096 for row in objects)
                info['all_top20_buffer_leaf_record_pages_excluded_from_migration'] = True
            rows = list(csv.DictReader((case / 'phase-summary.csv').open()))
            phase_rows += rows
            info.update(operations=manifest['operations'], restored=True, digest='0x7474b8e9d3962859')
        checks['cases'][case.name] = info
if phase_rows:
    with (OUT / 'phases.csv').open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(phase_rows[0]), lineterminator='\n')
        writer.writeheader()
        writer.writerows(phase_rows)
checks['benchmark_production_diff'] = subprocess.check_output(['git', 'diff', frozen['base_commit'], '--', 'benchmark', 'src', 'include', 'runtime', 'configs', 'scripts'], text=True)
assert not checks['benchmark_production_diff']
checks['changed_tracked_paths'] = subprocess.check_output(['git', 'diff', '--name-only', frozen['base_commit']], text=True).splitlines()
assert all(name in ['.gitattributes', 'docs/results.md'] or name.startswith('results/') for name in checks['changed_tracked_paths'])
checks['main_unchanged'] = subprocess.check_output(['git', 'rev-parse', 'main'], text=True).strip() == frozen['main_commit']
assert checks['main_unchanged']
dump(OUT / 'checks.json', checks)
print('Archived', len(checks['frozen_files']), 'unchanged inputs;', len(checks['cases']), 'XIndex cases')

"""Check frozen sources/artifacts and every accepted experiment's validation."""
import csv
import hashlib
import json
import subprocess
from pathlib import Path

base = Path('build/placement-diagnosis')
frozen = json.loads((base / 'frozen-inputs.json').read_text())
files = []
for name, expected in frozen['files'].items():
    actual = hashlib.sha256(Path(name).read_bytes()).hexdigest()
    files.append(dict(path=name, unchanged=actual == expected, sha256=actual))
assert all(row['unchanged'] for row in files)
for name, expected in frozen['traces'].items():
    stat = Path(name).stat()
    actual = dict(size=stat.st_size, mtime_ns=stat.st_mtime_ns, inode=stat.st_ino)
    assert actual == expected, (name, actual, expected)
extra = []
for line in Path('build/libcuckoo-rmw/micro/inputs.sha256').read_text().splitlines():
    expected, name = line.split(maxsplit=1)
    if name.endswith(('.config', 'libarbiter_runtime.a')) or '/microbench/' in name or '/vmitosis-workloads/' in name:
        actual = hashlib.sha256(Path(name).read_bytes()).hexdigest()
        extra.append(dict(path=name, unchanged=actual == expected, sha256=actual))
assert all(row['unchanged'] for row in extra)
diff = subprocess.check_output(['git', 'diff', frozen['base_commit'], '--', 'benchmark', 'compiler', 'runtime', 'configs'], text=True)
assert not diff, 'Benchmark, compiler, runtime or selection configuration changed'
accepted = []
live_checks = []
for path in sorted(base.glob('*/runs.csv')):
    settings = json.loads((path.parent/'manifest.json').read_text())['args']
    for row in csv.DictReader(path.open()):
        assert row['valid'] == 'True'
        stem = path.parent / f"{row['round']}-node{row['node']}"
        log = stem.with_suffix('.log').read_text()
        assert 'fallback_allocations=0' in log
        assert 'query_error_pages=0' in log and 'mincore_error_batches=0' in log
        assert int(stem.with_suffix('.time').read_text().split()[1]) == 0
        if 'xindex' in path.parent.name:
            assert int(row['ops']) == 400000000 and 'digest=0x7474b8e9d3962859' in log
        else:
            assert 'status=ok' in log
        if settings.get('interleaved'):
            snapshot=json.loads(stem.with_suffix('.live.json').read_text())
            for obj, data in snapshot['objects'].items():
                expected={0,int(row['node'])} if obj in settings['objects'].split(',') else {int(settings['membind'])}
                nodes={int(k):int(v) for k,v in data['nodes'].items()}
                assert set(nodes)==expected
                assert sum(nodes.values())*4096>=data['bytes']
                if len(expected)==2:
                    assert max(nodes.values())-min(nodes.values())<=max(4,sum(nodes.values())*.01)
            live_checks.append(dict(case=path.parent.name,round=int(row['round']),node=int(row['node']),snapshot_seconds=snapshot['snapshot_seconds']))
        accepted.append(dict(case=path.parent.name, round=int(row['round']), node=int(row['node'])))
result = dict(benchmark_compiler_runtime_policy_diff_empty=True, frozen_files=files, prior_input_manifest_checks=extra, trace_metadata_unchanged=True, accepted_throughput_runs=len(accepted), accepted_cases=accepted, rejected_inactive_rcu_case='screen-xindex-rcu: site 2 was an unexecuted out-of-line clone. Full operations/digest passed, but no placement occurred; excluded. Site 25 is used in the active RCU control.', main_branch=subprocess.check_output(['git','rev-parse','main'],text=True).strip())
prototype=json.loads((base/'interleave-runtime/manifest.json').read_text())
assert all(binary['worker_instructions_identical'] for binary in prototype['binaries'].values())
result.update(isolated_interleave_worker_instructions_identical=True,live_interleave_checks=live_checks)
(base / 'checks.json').write_text(json.dumps(result, indent=2) + '\n')
print('PASS: frozen inputs and', len(accepted), 'accepted throughput rows')

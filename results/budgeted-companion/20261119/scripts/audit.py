"""Validate every accepted row, caps, frozen inputs and unmodified originals."""
import csv,hashlib,json,re,subprocess
from pathlib import Path
root=Path.cwd();base=root/'build/budgeted-companion';manifest=json.loads((base/'manifest.json').read_text())
changes=[];frozen=[]
for name,digest in manifest['files'].items():
    now=hashlib.sha256((root/name).read_bytes()).hexdigest()
    (frozen if now==digest else changes).append(name)
assert changes==['runtime/src/arbiter_jemalloc_arena.cpp'],changes
for name,old in manifest['traces'].items():
    st=Path(name).stat();assert dict(size=st.st_size,mtime_ns=st.st_mtime_ns,inode=st.st_ino)==old
assert subprocess.check_output(['git','rev-parse','main'],text=True).strip()==manifest['main_commit']
variants=json.loads((base/'variants.json').read_text())['records']
original_ir_matches={}
for workload,v in variants.items():
    for kind,b in v['binaries'].items():assert hashlib.sha256(Path(b['path']).read_bytes()).hexdigest()==b['sha256']
    assert (base/workload/'old-seeds.csv').read_bytes()==(base/workload/'new-seeds.csv').read_bytes()
    original_ir_matches[workload]=[p for p,h in manifest['files'].items() if p.endswith('.bc') and (root/p).parent==Path(v['original_binary']).parent and h==v['binaries']['seed']['bitcode_sha256']]
    assert original_ir_matches[workload],workload
accepted=[];rejected=[];placements=[]
for path in sorted(base.glob('*/runs.csv')):
    if path.parent.name.startswith('rejected-'):continue
    case=path.parent
    case_manifest=json.loads((case/'manifest.json').read_text());case_variant=case_manifest['variant']
    for r in csv.DictReader(path.open()):
        assert r['valid']=='True';stem=case/f"{r['round']}-{r['strategy']}-attempt{r['attempt']}"
        log=stem.with_suffix('.log').read_text()
        expected=manifest['files'][str(Path(case_variant['original_binary']).relative_to(root))] if r['strategy']=='original' else case_variant['binaries']['seed' if r['strategy'].startswith('seed') else 'expanded']['sha256']
        assert json.loads(stem.with_suffix('.command.json').read_text())['binary_sha256']==expected
        assert not json.loads(stem.with_suffix('.host.json').read_text())['contaminated']
        assert all(s in log for s in ['fallback_allocations=0','query_error_pages=0','mincore_error_batches=0'])
        if 'xindex' in case.name:assert int(r['ops'])==400000000 and 'digest=0x7474b8e9d3962859' in log
        else:
            assert 'status=ok' in log and stem.with_suffix('.live.json').exists()
            assert 'layout: entry_bytes=64 epoch_store=1 table_alignment=0' in log
            args=case_manifest['args']
            assert f"table_size={args['table']} entries" in log and f"read_pct={args['reads']}" in log
            v=dict(re.findall(r'(\w+)=([^\s]+)',re.search(r'validation: (.*)',log)[1]))
            assert int(v['reads'])+int(v['writes'])==int(r['ops']) and v['writes']==v['versions']
        assert int(stem.with_suffix('.time').read_text().split()[1])==0
        for line in log.splitlines():
            if line.startswith('arbiter-placement-site '):
                p={k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
                assert p['target_assigned_bytes']<=p['target_limit_bytes'];placements.append(dict(case=case.name,round=r['round'],strategy=r['strategy'],**p))
        accepted.append(dict(case=case.name,**r))
    for f in case.glob('*.host.json'):
        d=json.loads(f.read_text())
        if d['contaminated']:rejected.append(dict(case=case.name,attempt=f.stem,reason='Concurrent foreign CPU load',processes=d['processes']))
for f in (base/'page-validation').glob('*.before.json'):
    a=json.loads(f.read_text());b=json.loads(f.with_name(f.name.replace('.before.','.after.')).read_text());assert a['objects']==b['objects']
assert len(list((base/'page-validation').glob('*.after.json')))==4
audit=dict(validated_rows=len(accepted),case_counts={name:sum(r['case']==name for r in accepted) for name in sorted({r['case'] for r in accepted})},frozen_files=frozen,intentionally_modified_files=changes,trace_stat_checks_passed=True,main_unchanged=True,original_seed_reports_unchanged=True,rewritten_binary_hashes_unchanged=True,exact_page_validations=4,rejected_attempts=len(rejected),limits=['First-touch throughput excludes initialization; process wall times are also retained.','All accepted processes passed the recorded foreign-CPU guard, not exclusive machine reservation.','Initial screen-h16 uses a stricter 0.15-core guard; later cases use one core to tolerate ordinary short background-service bursts. Rejected attempts remain excluded.','Screen and confirmation results are never pooled.','Per-site lifetime backing caps include metadata and unused capacity, not current RSS.','No new hardware coherence-causality claim is made.'])
audit['original_seed_ir_matches']=original_ir_matches
audit['discarded_initial_pilot_rows']=len(list(csv.DictReader((base/'rejected-firsttouch-contention/runs.csv').open())))
(base/'audit.json').write_text(json.dumps(audit,indent=2)+'\n');(base/'rejected.json').write_text(json.dumps(rejected,indent=2)+'\n')
for name,rows in [('accepted-runs.csv',accepted),('budget-checks.csv',placements)]:
    with (base/name).open('w') as f:w=csv.DictWriter(f,fieldnames=list(rows[0]),lineterminator='\n');w.writeheader();w.writerows(rows)
print(json.dumps(audit,indent=2))

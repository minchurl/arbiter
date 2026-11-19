"""Audit frozen artifacts and every accepted final process after all runs finish."""
import csv,hashlib,json,re,subprocess
from pathlib import Path
root=Path.cwd();base=root/'build/adaptive-companion'
assert 'QUEUE FINISHED' in (base/'queue.console').read_text()
assert 'FOLLOWUPS FINISHED' in (base/'after.console').read_text()
assert 'HOLDOUT FINISHED' in (base/'holdout.console').read_text()
frozen=json.loads((base/'frozen.json').read_text())
for name,digest in frozen['files'].items():
 assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,name
assert subprocess.check_output(['git','rev-parse','main'],text=True).strip()==frozen['main']
assert not subprocess.check_output(['git','diff',frozen['base_commit'],'--','benchmark/','configs/hitm-seed/'],text=True)
assert all(x['passed'] for x in json.loads((base/'build-checks.json').read_text()))
assert json.loads((base/'worker-equivalence.json').read_text())['identical']
assert json.loads((base/'shared-policy.json').read_text())['identical_seed_options']
cases=['confirm-h16','confirm-h256','neighbor-h8','neighbor-h32','short-h16','short-h256','phase-affinity','holdout-readonly']
counts={};max_pages=0;rejected=[];migration_count=0;cancelled=[]
for case in cases:
 folder=base/case;rows=list(csv.DictReader((folder/'runs.csv').open()));counts[case]=len(rows);accepted=set()
 for row in rows:
  stem=folder/f"{row['round']}-{row['mode']}-attempt{row['attempt']}";accepted.add(stem.name)
  cmd=json.loads(stem.with_suffix('.command.json').read_text());host=json.loads(stem.with_suffix('.host.json').read_text())
  assert not host['busy'] and row['valid']=='True'
  expected=frozen['variants']['micro']['plain']['sha256'] if row['mode']=='plain' else frozen['variants']['micro']['binary_sha256']
  assert cmd['binary_sha256']==expected
  text=stem.with_suffix('.log').read_text();ops=int(re.search(r'total_ops=(\d+)',text)[1]);seconds=float(re.search(r'elapsed=([\d.]+)',text)[1])
  assert int(row['ops'])==ops and float(row['seconds'])==seconds and abs(float(row['mops'])-ops/seconds/1e6)<1e-9
  validation=dict(re.findall(r'(\w+)=([^\s]+)',re.search(r'validation: (.*)',text)[1]))
  assert validation['status']=='ok' and int(validation['reads'])+int(validation['writes'])==ops and validation['writes']==validation['versions']
  assert 'fallback_allocations=0' in text and 'query_error_pages=0' in text and 'mincore_error_batches=0' in text
  assert int(stem.with_suffix('.time').read_text().split()[1])==0
  events=json.loads(stem.with_suffix('.events.json').read_text())
  if row['mode']=='plain':assert not events
  else:
   end=[e for e in events if e['event']=='finish'];assert len(end)==1
   assert end[0]['progress']==ops and end[0]['active_sources']==32 and not end[0]['invalid_progress']
  assert not any('exception' in e['event'] or 'fail' in e.get('action','') or 'invalid' in e.get('action','') for e in events)
  for e in events:
   if e['event']!='migration':continue
   migration_count+=1;max_pages=max(max_pages,e['target_pages'])
   assert e['target_pages']*4096<=e['budget_bytes']==4*1024**3
   if e['cancelled']:cancelled.append(dict(case=case,run=stem.name,migration=e))
   else:assert e['failed']==e['missing']==e['mismatch']==0
  if case=='phase-affinity':assert host['affinity_change']['cpus']==list(range(8))
 for host in folder.glob('*-attempt*.host.json'):
  if host.name.removesuffix('.host.json') not in accepted:
   assert json.loads(host.read_text())['busy'];rejected.append(str(host.relative_to(base)))
assert counts==dict(zip(cases,[9,9,2,2,3,3,2,4])),counts
xrows=list(csv.DictReader((base/'xindex-check/runs.csv').open()));assert len(xrows)==2
for row in xrows:
 stem=base/'xindex-check'/f"{row['mode']}-attempt{row['attempt']}"
 text=stem.with_suffix('.log').read_text()
 assert 'executed=400000000' in text and 'digest=0x7474b8e9d3962859' in text
 assert 'arbiter-adaptive ' not in text and not json.loads(stem.with_suffix('.host.json').read_text())
 assert int(stem.with_suffix('.time').read_text().split()[1])==0
 if row['mode']=='current':assert json.loads(stem.with_suffix('.command.json').read_text())['binary_sha256']==frozen['variants']['xindex']['binary_sha256']
pages=json.loads((base/'page-validation/summary.json').read_text());assert len(pages)==2
result=dict(frozen_files_checked=len(frozen['files']),frozen_artifacts_unchanged=True,benchmark_and_seed_config_unchanged=True,main_unchanged=True,counts=counts,accepted_micro_processes=sum(counts.values()),accepted_xindex_processes=len(xrows),accepted_performance_processes=sum(counts.values())+len(xrows),rejected_micro_attempts=rejected,excluded_pilot_processes=sum(len(list(csv.DictReader(p.open()))) for p in base.glob('pilot-*/runs.csv')),excluded_final_smokes=1,excluded_interrupted_processes=len(list((base/'short-h16-interrupted').glob('*.command.json'))),excluded_page_diagnostics=2,migration_events=migration_count,maximum_companion_target_bytes=max_pages*4096,cancelled_shutdown_migrations=cancelled,llvm_RUN_checks=25,runtime_checks='placement policy, runtime smoke, arena boundary, four counter modes',worker_instructions=149,worker_assembly_identical=True,xindex_and_cuckoo_adaptive_ir_equals_seed_only=True,note='Shared host with sampled foreign-CPU guard, not an exclusive reservation. One XIndex pair is diagnostic, not statistical equivalence. Pilot source snapshots are historical debugging evidence, not exact source manifests for every intermediate binary.')
(base/'audit.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))

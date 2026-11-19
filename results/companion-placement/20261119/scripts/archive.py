"""Freeze successful measurements, raw evidence, scripts and validation."""
import csv,gzip,hashlib,json,shutil,subprocess,sys
from pathlib import Path
root=Path.cwd();base=root/'build/companion-placement';out=root/'results/companion-placement/20261119'
subprocess.run([sys.executable,str(base/'scripts/audit.py')],check=True)
xindex=root/'build/placement-diagnosis/companion-xindex-regression'
assert len(list(csv.DictReader((xindex/'runs.csv').open())))==6
if not (base/'xindex-regression').exists():shutil.copytree(xindex,base/'xindex-regression')
subprocess.run([sys.executable,str(base/'scripts/summarize.py')],check=True)
out.mkdir(parents=True,exist_ok=False)
accepted=[];rejected=[];commands=[];raw_files=[];placements=[];profiles=[];crossovers={}
for case in sorted(base.iterdir()):
    if not case.is_dir() or case.name in ['scripts','lock','bucket','both']:continue
    if not (case/'manifest.json').exists():continue
    target=out/case.name;target.mkdir()
    for file in case.iterdir():
        if file.is_file() and file.suffix not in ['.data']:
            if file.name in ['manifest.json','runs.csv','phases.csv','checks.json']:
                shutil.copy2(file,target/file.name)
            else:
                raw_files.append(dict(case=case.name,file=file.name,text=file.read_bytes().decode()))
    if case.name.startswith('probe'):
        rejected.append(dict(case=case.name,reason='Short setup/validation probe; excluded from performance conclusions.' if (case/'runs.csv').exists() else 'External helper lacked parent ptrace permission; rerun in the GDB parent. No valid throughput.'))
        continue
    if case.name.startswith('crossover-'):
        check=json.loads((case/'checks.json').read_text())
        phases=list(csv.DictReader((case/'phases.csv').open()))
        assert check['valid'] and check['phase_count']==len(phases)
        assert check['all_workers_active'] and check['all_page_moves_verified']
        assert check['final_ballast_node']==0 and check['reported_swaps']==0
        assert 'status=ok' in (case/'output.log').read_text()
        crossovers[case.name]=check
        continue
    for row in csv.DictReader((case/'runs.csv').open()):
        assert row['valid']=='True';accepted.append(dict(case=case.name,**row))
        if 'table_node' in row:
            stem=case/f"{row['round']}-table{row['table_node']}-ballast{row['ballast_percent']}"
            a=json.loads(stem.with_suffix('.place.json').read_text());b=json.loads(stem.with_suffix('.verify.json').read_text())
            for obj in ['table','ballast']:
                assert a['objects'][obj]['after']==b['objects'][obj]['after']
                assert a['objects'][obj]['page_index_sha256']==b['objects'][obj]['page_index_sha256']
            placements.append(dict(case=case.name,round=row['round'],table_node=row['table_node'],ballast_percent=row['ballast_percent'],
                ballast_pages=a['objects']['ballast']['pages'],ballast_cxl_pages=a['objects']['ballast']['after'].get('2',0),
                table_pages=a['objects']['table']['pages'],table_cxl_pages=a['objects']['table']['after'].get('2',0),
                page_index_sha256=a['objects']['ballast']['page_index_sha256'],verified_after=True))
            if stem.with_suffix('.counters.json').exists():
                counters=json.loads(stem.with_suffix('.counters.json').read_text())
                profiles.append(dict(case=case.name,round=row['round'],table_node=row['table_node'],ballast_percent=row['ballast_percent'],ops=counters['ops'],writes=counters['writes'],**counters['per_operation']))
            assert 'status=ok' in stem.with_suffix('.log').read_text()
        elif 'variant' in row:
            stem=case/f"{row['round']}-{row['variant']}-node{row['node']}"
            data=json.loads(next(s for s in stem.with_suffix('.log').read_text().splitlines() if s.startswith('{"keys":')))
            assert data['valid'] and not data['failures'] and data['value_sum']==data['updates']
        else:
            stem=case/f"{row['round']}-node{row['node']}"
            assert int(row['ops'])==400000000 and 'digest=0x7474b8e9d3962859' in stem.with_suffix('.log').read_text()
        log=stem.with_suffix('.log').read_text()
        assert 'fallback_allocations=0' in log and 'query_error_pages=0' in log and 'mincore_error_batches=0' in log
        assert int(stem.with_suffix('.time').read_text().split()[1])==0
        commands.append(json.loads(stem.with_suffix('.command.json').read_text()))
for name in ['frozen.json','build.json','audit.json','summary.csv','runs.jsonl','environment.json','confirmation-plan.json','confirmation-binaries.json','generalization.json']:
    shutil.copy2(base/name,out/name)
if (base/'refinement-plan.json').exists():shutil.copy2(base/'refinement-plan.json',out/'refinement-plan.json')
for name in ['lock','bucket','both']:
    (out/'selection'/name).mkdir(parents=True)
    for file in ['selection.csv','worker.asm']:shutil.copy2(base/name/file,out/'selection'/name/file)
shutil.copytree(base/'scripts',out/'scripts',ignore=shutil.ignore_patterns('__pycache__'))
for file in base.glob('*.console'):shutil.copy2(file,out/file.name)
checks=dict(validated_rows=len(accepted),counts={prefix:sum(r['case'].startswith(prefix) for r in accepted) for prefix in ['screen-','confirm-','profile-','xindex-']},accepted_cases=sorted({r['case'] for r in accepted}),
    rejected_probes=rejected,same_process_crossovers=crossovers,source_and_binary_audit=json.loads((base/'audit.json').read_text()),
    limits=['Screens and fresh confirmations are reported separately.',
            'Bootstrap intervals are paired, exploratory, and not a multiple-comparison guarantee.',
            'GDB interrupts only outside measured regions. Profiles, if present, are separate diagnostics.',
            'Initial micro screen rows predate smaps_rollup capture; later rows explicitly validate zero huge pages and swap.'])
(out/'checks.json').write_text(json.dumps(checks,indent=2)+'\n')
(out/'rejected.json').write_text(json.dumps(rejected,indent=2)+'\n')
(out/'raw-files.jsonl.gz').write_bytes(gzip.compress(''.join(json.dumps(r)+'\n' for r in raw_files).encode(),mtime=0))
for filename,records in [('placement-validation.csv',placements),('profile-counters.csv',profiles)]:
    if records:
        with (out/filename).open('w') as f:
            fields=list(dict.fromkeys(key for row in records for key in row))
            w=csv.DictWriter(f,fieldnames=fields,lineterminator='\n');w.writeheader();w.writerows(records)
subprocess.run([sys.executable,str(out/'scripts/summarize-mechanism.py'),'--base',str(out)],check=True)
subprocess.run([sys.executable,str(out/'scripts/plot.py'),'--base',str(out)],check=True)
(out/'artifacts.sha256').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(out))+'\n' for p in sorted(out.rglob('*')) if p.is_file()))
print('Archived',len(accepted),'validated rows to',out)

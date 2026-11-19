"""Verify matching, fallback, stale-plan rejection and actual bounded launch."""
import json,os,subprocess,sys,tempfile,time
from pathlib import Path
from host_guard import wait_quiet
base=Path('build/budgeted-companion').resolve()
while Path('/proc/'+sys.argv[1]).exists():time.sleep(2)
assert 'FINISHED CHECKS' in (base/'finish.console').read_text()
launcher=base/'scripts/launch-profile.py';out=base/'launcher-validation';out.mkdir(exist_ok=False);checks=[];waits=[]
for path in sorted((base/'accepted-plans').glob('*.json')):
    data=json.loads(path.read_text());argv=data['validated_argv']
    command=[sys.executable,str(launcher),'--profile',str(path),'--dry-run','--',*argv]
    result=json.loads(subprocess.check_output(command,text=True));assert result['matched_profile'] and result['strategy']==data['selected_strategy'] and result['plan']
    checks.append(dict(name=path.stem+' matched arguments',decision=result,passed=True))
profile=base/'accepted-plans/screen-h16-cap4g.json';data=json.loads(profile.read_text());argv=data['validated_argv']
unknown=list(argv);unknown[unknown.index('--table-size')+1]='256';unknown[unknown.index('--duration')+1]='1'
command=[sys.executable,str(launcher),'--profile',str(profile),'--dry-run','--',*unknown]
result=json.loads(subprocess.check_output(command,text=True));assert not result['matched_profile'] and result['strategy']=='seed' and result['plan'] is None
checks.append(dict(name='unmatched input selects seed-only binary',decision=result,passed=True))
with tempfile.TemporaryDirectory(prefix='arbiter-stale-plan-') as directory:
    p=Path(directory)/'profile.json';p.write_bytes(profile.read_bytes());p.with_suffix('.plan').write_bytes(profile.with_suffix('.plan').read_bytes()+b'\n')
    r=subprocess.run([sys.executable,str(launcher),'--profile',str(p),'--dry-run','--',*argv],capture_output=True,text=True)
    assert r.returncode!=0 and 'Placement plan changed' in r.stderr
    checks.append(dict(name='changed plan rejected before execution',passed=True))
for name,arguments in [('matching-bounded-profile',argv),('unmatched-seed-fallback',unknown)]:
    wait_quiet(waits)
    command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=64G','-p','MemorySwapMax=0','--','timeout','240',sys.executable,str(launcher),'--profile',str(profile),'--',*arguments]
    (out/(name+'.command.json')).write_text(json.dumps(command,indent=2)+'\n')
    with (out/(name+'.log')).open('w') as f:subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,check=True)
    log=(out/(name+'.log')).read_text();assert all(s in log for s in ['status=ok','fallback_allocations=0','query_error_pages=0','mincore_error_batches=0'])
    if name.startswith('matching'):assert 'target_assigned_bytes=4294967296' in log
    else:assert 'arbiter-placement-site ' not in log and 'arbiter-arena-site site=5 ' not in log
    checks.append(dict(name=name,passed=True,measurement='Functional integration check, excluded from performance summaries.'))
    print('PASS',name,flush=True)
(out/'waits.json').write_text(json.dumps(waits,indent=2)+'\n');(base/'launcher-checks.json').write_text(json.dumps(checks,indent=2)+'\n')
print('LAUNCHER CHECKS FINISHED',flush=True)

"""Fresh confirmations chosen after screens; benchmark jobs remain serial."""
import csv,json,subprocess,sys,time
from pathlib import Path
base=Path('build/companion-placement');pid=int(sys.argv[1])
while Path(f'/proc/{pid}/cmdline').exists():
    if b'companion-placement/scripts/followup.py' not in Path(f'/proc/{pid}/cmdline').read_bytes():break
    time.sleep(1)
assert 'FOLLOWUP COMPLETE' in (base/'followup.console').read_text()
subprocess.run([sys.executable,str(base/'scripts/summarize.py')],check=True)
rows=list(csv.DictReader((base/'summary.csv').open()))
micro=[r for r in rows if r['case'].startswith('screen-micro-') and r['case']!='screen-micro-default' and 'vs-all-local' not in r['treatment'] and int(r['n'])==2]
best=max(micro,key=lambda r:float(r['paired_percent']))
settings=json.loads(best['workload']);percent=int(best['treatment'].split('ballast')[1])
decision=dict(micro_best_screen=best,rule='Confirm the strongest observed non-default micro condition on fresh processes, with all-local and table-only controls; also confirm all default ballast fractions and apparent libcuckoo gains. Screen and confirmation samples are not pooled.')
(base/'confirmation-plan.json').write_text(json.dumps(decision,indent=2)+'\n')
jobs=[('run-cuckoo.py','confirm-cuckoo-hot64','--hot','64','--operations','8000000','--rounds','5'),
      ('run-cuckoo.py','confirm-cuckoo-hot65536','--hot','65536','--operations','128000000','--rounds','5'),
      ('run-cuckoo.py','confirm-cuckoo-hot1m-lock','--hot','1048576','--operations','128000000','--rounds','5','--variants','lock'),
      ('run-micro.py','confirm-micro-default','--rounds','5','--seconds','20','--table-nodes','2'),
      ('run-micro.py','confirm-micro-best','--rounds','5','--seconds','30','--table',str(settings['table']),'--reads',str(settings['reads']),'--threads',str(settings['threads']),'--fractions','0',str(percent)),
      ('run-micro.py','profile-micro-default','--rounds','1','--seconds','20','--table-nodes','2','--fractions','0','1','5','10','--profile'),
      ('run-micro.py','profile-micro-best','--rounds','1','--seconds','20','--table',str(settings['table']),'--reads',str(settings['reads']),'--threads',str(settings['threads']),'--table-nodes','2','--fractions','0',str(percent),'--profile')]
for job in jobs:
    print('START',job[1],flush=True)
    with (base/(job[1]+'.console')).open('w') as f:
        subprocess.run([sys.executable,str(base/'scripts'/job[0]),*job[1:],*(['--plain'] if job[0]=='run-cuckoo.py' else [])],stdout=f,stderr=subprocess.STDOUT,check=True)
    print((base/(job[1]+'.console')).read_text(),flush=True)
print('CONFIRM COMPLETE',flush=True)

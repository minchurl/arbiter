"""Sequential experiments. Freeze screen decisions before independent confirmation."""
import csv,json,os,subprocess,sys,time
from pathlib import Path
base=Path('build/budgeted-companion')
def run(case,*args):
    with (base/(case+'.console')).open('w') as f:
        subprocess.run([sys.executable,str(base/'scripts/run.py'),case,*map(str,args)],stdout=f,stderr=subprocess.STDOUT,check=True)
def choose(case):
    rows=list(csv.DictReader((base/case/'runs.csv').open()))
    by={s:{int(r['round']):float(r['mops']) for r in rows if r['strategy']==s} for s in {r['strategy'] for r in rows}}
    eligible={s:sum(values.values())/len(values) for s,values in by.items() if s not in ['original','seed','local'] and all(values[i]>max(by['original'][i],by['local'][i],by['seed'][i]) for i in values)}
    selected=max(eligible,key=eligible.get) if eligible else 'seed'
    decision=dict(case=case,selected=selected,eligible_mean_mops=eligible,rule='Highest mean among companion placements beating original, seed-only and companion-local in every training round. Otherwise keep seed-only. This is an offline representative-input decision; fresh confirmation must validate it.',training=rows,time=time.time())
    (base/(case+'-decision.json')).write_text(json.dumps(decision,indent=2)+'\n')
    print('FROZEN DECISION',case,selected,flush=True)
    return selected
while Path('/proc/'+sys.argv[1]).exists():time.sleep(2)
assert len(list(csv.DictReader((base/'screen-h16/runs.csv').open())))==14
chosen=choose('screen-h16')
run('screen-h256','--table',256,'--rounds',2,'--seconds',20)
choose('screen-h256')
run('confirm-h16','--rounds',5,'--seconds',30,'--strategies',*dict.fromkeys(['original','seed','local',chosen,'cap4g']))
run('regression-h256','--table',256,'--rounds',3,'--seconds',20,'--strategies','original','seed')
run('regression-xindex','--workload','xindex','--rounds',3,'--strategies','original','seed','seed-local')
run('screen-xindex-companions','--workload','xindex','--rounds',2,'--strategies','original','seed','local','half','cap4g','full')
choose('screen-xindex-companions')
for table in [8,32]:
    run('neighbor-h'+str(table),'--table',table,'--rounds',2,'--seconds',20,'--strategies','seed','local',chosen)
print('QUEUE FINISHED',flush=True)

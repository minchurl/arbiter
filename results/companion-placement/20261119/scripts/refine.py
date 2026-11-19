"""Expand ballast fractions only after a positive fresh confirmation."""
import csv,json,subprocess,sys,time
from pathlib import Path
base=Path('build/companion-placement');pid=int(sys.argv[1])
while Path(f'/proc/{pid}/cmdline').exists():
    if b'companion-placement/scripts/confirm.py' not in Path(f'/proc/{pid}/cmdline').read_bytes():break
    time.sleep(1)
assert 'CONFIRM COMPLETE' in (base/'confirm.console').read_text(),'Confirmation/profile stage failed'
def summarize():
    subprocess.run([sys.executable,str(base/'scripts/summarize.py')],stdout=subprocess.DEVNULL,check=True)
    return list(csv.DictReader((base/'summary.csv').open()))
rows=summarize()
candidates=[r for r in rows if r['case']=='confirm-micro-best' and r['treatment'] in ['table0-ballast10','table2-ballast10'] and float(r['bootstrap_low_percent'])>0 and int(r['positive_pairs'])>=4]
decision=dict(rule='Expand only if the fresh five-pair interval is positive and at least four pairs improve. Choose the strongest confirmed table placement; test 0/10/20/30/50%. Confirm a new peak only if both wide-screen rounds beat 10% and the average advantage is at least 1%.',eligible=candidates)
plan=base/'refinement-plan.json'
if not candidates:
    decision['executed']=False;plan.write_text(json.dumps(decision,indent=2)+'\n');print('No robust candidate: refinement skipped',flush=True);sys.exit(0)
choice=max(candidates,key=lambda r:float(r['paired_percent']));node=int(choice['treatment'][5]);settings=json.loads(choice['workload'])
decision.update(executed=True,chosen=choice,table_node=node);plan.write_text(json.dumps(decision,indent=2)+'\n')
common=['--table',str(settings['table']),'--threads',str(settings['threads']),'--reads',str(settings['reads']),'--table-nodes',str(node)]
def run(name,extra):
    print('START',name,flush=True)
    with (base/(name+'.console')).open('w') as f:
        subprocess.run([sys.executable,str(base/'scripts/run-micro.py'),name,*common,*extra],stdout=f,stderr=subprocess.STDOUT,check=True)
    print((base/(name+'.console')).read_text(),flush=True)
run('screen-micro-fractions-wide',['--rounds','2','--seconds','20','--fractions','0','10','20','30','50'])
data=list(csv.DictReader((base/'screen-micro-fractions-wide/runs.csv').open()))
control={int(r['round']):float(r['mops']) for r in data if r['ballast_percent']=='10'}
peaks=[]
for fraction in [20,30,50]:
    values=[float(r['mops'])/control[int(r['round'])] for r in data if int(r['ballast_percent'])==fraction]
    if min(values)>1 and sum(values)/len(values)>=1.01:
        peaks.append(dict(fraction=fraction,ratios_vs_10=values,mean_ratio=sum(values)/len(values)))
decision['new_peaks']=peaks
if peaks:
    best=max(peaks,key=lambda r:r['mean_ratio'])['fraction'];decision['confirmed_fraction']=best
    plan.write_text(json.dumps(decision,indent=2)+'\n')
    run('confirm-micro-refined',['--rounds','5','--seconds','30','--fractions','0','10',str(best)])
    run('profile-micro-refined',['--rounds','1','--seconds','20','--fractions','0','10',str(best),'--profile'])
elif node==0:
    run('profile-micro-local-table',['--rounds','1','--seconds','20','--fractions','0','10','--profile'])
plan.write_text(json.dumps(decision,indent=2)+'\n');summarize();print('REFINEMENT COMPLETE',flush=True)

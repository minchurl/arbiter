"""Summarize per-process rows, pairing treatments by run round."""
import argparse,csv,json,random,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--base',type=Path,default=Path('build/companion-placement'));args=p.parse_args();base=args.base
summary=[];allrows=[]
def add(case,label,control,treatment,settings):
    rounds=sorted(set(control)&set(treatment));assert rounds
    ratios=[treatment[r]/control[r] for r in rounds]
    rng=random.Random(381119)
    boot=sorted(statistics.mean(rng.choices(ratios,k=len(ratios))) for _ in range(10000)) if len(ratios)>=3 else []
    row=dict(case=case,treatment=label,n=len(rounds),control_mops=statistics.mean(control[r] for r in rounds),
        treatment_mops=statistics.mean(treatment[r] for r in rounds),paired_percent=100*(statistics.mean(ratios)-1),
        median_paired_percent=100*(statistics.median(ratios)-1),positive_pairs=sum(v>1 for v in ratios),
        min_paired_percent=100*(min(ratios)-1),max_paired_percent=100*(max(ratios)-1),
        bootstrap_low_percent=100*(boot[249]-1) if boot else '',bootstrap_high_percent=100*(boot[9749]-1) if boot else '',
        workload=json.dumps(settings,sort_keys=True))
    summary.append(row)
for file in sorted(base.glob('*/runs.csv')):
    case=file.parent.name
    if case.startswith('probe'):continue
    rows=list(csv.DictReader(file.open()));settings=json.loads((file.parent/'manifest.json').read_text())['args']
    for row in rows:allrows.append(dict(case=case,**row))
    if 'table_node' in rows[0]:
        by={}
        for row in rows:by.setdefault((int(row['table_node']),int(row['ballast_percent'])),{})[int(row['round'])]=float(row['mops'])
        for (node,percent),values in sorted(by.items()):
            if not percent:continue
            add(case,f'table{node}-ballast{percent}',by[node,0],values,settings)
            if node and (0,0) in by:
                add(case,f'table{node}-ballast{percent}-vs-all-local',by[0,0],values,settings)
            if node==0 and (2,0) in by:
                add(case,f'table0-ballast{percent}-vs-current-cxl',by[2,0],values,settings)
            if percent>10 and (node,10) in by:
                add(case,f'table{node}-ballast{percent}-vs-ballast10',by[node,10],values,settings)
        if (0,0) in by and (2,0) in by:add(case,'table2-ballast0-vs-all-local',by[0,0],by[2,0],settings)
    elif 'variant' in rows[0]:
        for variant in sorted({r['variant'] for r in rows}):
            c={int(r['round']):float(r['mops']) for r in rows if r['variant']==variant and r['node']=='0'}
            t={int(r['round']):float(r['mops']) for r in rows if r['variant']==variant and r['node']=='2'}
            if c and t:add(case,variant,c,t,settings)
        for variant in ['bucket','both']:
            t={int(r['round']):float(r['mops']) for r in rows if r['variant']==variant and r['node']=='2'}
            for node,label in [('0','current-local'),('2','current-cxl')]:
                c={int(r['round']):float(r['mops']) for r in rows if r['variant']=='lock' and r['node']==node}
                if c and t:add(case,variant+'-vs-'+label,c,t,settings)
    else:
        c={int(r['round']):float(r['mops']) for r in rows if r['node']=='0'}
        t={int(r['round']):float(r['mops']) for r in rows if r['node']=='2'}
        if c and t:add(case,'auto',c,t,settings)
if summary:
    with (base/'summary.csv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=list(summary[0]),lineterminator='\n');w.writeheader();w.writerows(summary)
with (base/'runs.jsonl').open('w') as f:
    for row in allrows:f.write(json.dumps(row)+'\n')
for row in summary:
    print(row['case'],row['treatment'],'n='+str(row['n']),f"{row['control_mops']:.3f} -> {row['treatment_mops']:.3f}",f"{row['paired_percent']:+.2f}%")

"""Paired results; training and fresh confirmation remain separate."""
import argparse,csv,itertools,json,random,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--base',type=Path,default=Path('build/budgeted-companion'));args=p.parse_args();base=args.base
def compare(rows,treatment,reference):
    by={s:{int(r['round']):r for r in rows if r['strategy']==s} for s in [treatment,reference]}
    rounds=sorted(set(by[treatment])&set(by[reference]));assert rounds
    a=[float(by[reference][i]['mops']) for i in rounds];b=[float(by[treatment][i]['mops']) for i in rounds]
    deltas=[(y/x-1)*100 for x,y in zip(a,b)]
    rng=random.Random(20261119)
    draws=itertools.product(deltas,repeat=len(deltas)) if len(deltas)<=6 else (rng.choices(deltas,k=len(deltas)) for _ in range(20000))
    samples=sorted(sum(draw)/len(deltas) for draw in draws)
    wall_a=[int(by[reference][i]['ops'])/float(by[reference][i]['wall_seconds'])/1e6 for i in rounds];wall_b=[int(by[treatment][i]['ops'])/float(by[treatment][i]['wall_seconds'])/1e6 for i in rounds]
    return dict(treatment=treatment,reference=reference,pairs=len(rounds),reference_mops=statistics.mean(a),treatment_mops=statistics.mean(b),paired_change_pct=statistics.mean(deltas),ci95_low_pct=samples[int(len(samples)*.025)],ci95_high_pct=samples[min(len(samples)-1,int(len(samples)*.975))],positive_pairs=sum(x>0 for x in deltas),min_pair_pct=min(deltas),max_pair_pct=max(deltas),reference_launcher_wall_mops=statistics.mean(wall_a),treatment_launcher_wall_mops=statistics.mean(wall_b),paired_launcher_wall_change_pct=statistics.mean((y/x-1)*100 for x,y in zip(wall_a,wall_b)),max_target_assigned_bytes=max(int(by[treatment][i]['target_assigned_bytes']) for i in rounds))
summary=[]
for path in sorted(base.glob('*/runs.csv')):
    if path.parent.name.startswith('rejected-'):continue
    rows=list(csv.DictReader(path.open()));strategies=sorted({r['strategy'] for r in rows})
    for reference in ['original','seed','local','seed-local']:
        if reference not in strategies:continue
        for treatment in strategies:
            if treatment==reference:continue
            summary.append(dict(case=path.parent.name,**compare(rows,treatment,reference)))
with (base/'summary.csv').open('w') as f:
    w=csv.DictWriter(f,fieldnames=list(summary[0]),lineterminator='\n');w.writeheader();w.writerows(summary)
decisions=[]
for screen,confirmation in [('screen-h16','confirm-h16'),('screen-h256','regression-h256'),('screen-xindex-companions',None)]:
    decision_file=base/(screen+'-decision.json')
    if not decision_file.exists():continue
    d=json.loads(decision_file.read_text());selected=d['selected'];d['confirmation']=confirmation
    if selected=='seed':d.update(accepted='retain-original-seed-policy',reason='No companion strategy passed the training rule.')
    elif confirmation:
        checks=[r for r in summary if r['case']==confirmation and r['treatment']==selected and r['reference'] in ['original','seed','local']]
        accepted=len(checks)==3 and all(r['pairs']>=5 and r['ci95_low_pct']>0 and r['positive_pairs']==r['pairs'] for r in checks)
        d.update(accepted=bool(accepted),holdout_checks=checks,reason='Require five fresh positive pairs and positive paired-bootstrap lower bound against original, seed-only and same-expanded-binary local controls.')
    else:d.update(accepted=False,reason='Exploratory screen only; no independent confirmation.')
    decisions.append(d)
(base/'decisions.json').write_text(json.dumps(decisions,indent=2)+'\n')
for r in summary:
    if r['reference']=='original':print(r['case'],r['treatment'],f"{r['reference_mops']:.3f}->{r['treatment_mops']:.3f} {r['paired_change_pct']:+.2f}% [{r['ci95_low_pct']:+.2f}, {r['ci95_high_pct']:+.2f}] n={r['pairs']}")

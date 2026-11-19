"""Keep prototype pilots and short/phase tests separate from confirmations."""
import argparse,csv,itertools,json,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--base',type=Path,default=Path('build/adaptive-companion'));args=p.parse_args();base=args.base
cases=['confirm-h16','confirm-h256','neighbor-h8','neighbor-h32','short-h16','short-h256','phase-affinity','holdout-readonly']
summary=[];details=[];phase_windows=[]
for case in cases:
 path=base/case/'runs.csv'
 if not path.exists():continue
 rows=list(csv.DictReader(path.open()));modes={r['mode'] for r in rows}
 for reference in ['plain','observe']:
  for treatment in ['observe','adapt']:
   if reference==treatment or not {reference,treatment}<=modes:continue
   a={int(r['round']):r for r in rows if r['mode']==reference};b={int(r['round']):r for r in rows if r['mode']==treatment};pairs=sorted(a.keys()&b.keys())
   if not pairs:continue
   deltas=[(float(b[i]['mops'])/float(a[i]['mops'])-1)*100 for i in pairs]
   samples=sorted(statistics.mean(x) for x in itertools.product(deltas,repeat=len(deltas)))
   summary.append(dict(case=case,reference=reference,treatment=treatment,pairs=len(pairs),reference_mops=statistics.mean(float(a[i]['mops']) for i in pairs),treatment_mops=statistics.mean(float(b[i]['mops']) for i in pairs),paired_change_pct=statistics.mean(deltas),positive_pairs=sum(x>0 for x in deltas),min_pair_pct=min(deltas),max_pair_pct=max(deltas),bootstrap95_low=samples[int(len(samples)*.025)],bootstrap95_high=samples[min(len(samples)-1,int(len(samples)*.975))],launcher_rate_change_pct=statistics.mean(((int(b[i]['ops'])/float(b[i]['wall_seconds']))/(int(a[i]['ops'])/float(a[i]['wall_seconds']))-1)*100 for i in pairs)))
 for row in rows:
  stem=base/case/f"{row['round']}-{row['mode']}-attempt{row['attempt']}"
  event_file=stem.with_suffix('.events.json')
  if event_file.exists():events=json.loads(event_file.read_text())
  elif (base/'raw-files.jsonl.gz').exists():
   import gzip
   raw=[json.loads(x) for x in gzip.decompress((base/'raw-files.jsonl.gz').read_bytes()).decode().splitlines()]
   events=json.loads(next(r['text'] for r in raw if r['case']==case and r['file']==stem.name+'.events.json'))
  else:continue
  decisions=[e for e in events if e['event']=='decision'];monitor=[e for e in events if e['event']=='sample' and e['phase']=='monitor'];migrations=[e for e in events if e['event']=='migration']
  if case=='phase-affinity':
   for start,end in [(60,85),(140,180)]:
    window=[e for e in events if e['event']=='sample' and start<=e['time']-e['seconds'] and e['time']<=end]
    phase_windows.append(dict(mode=row['mode'],round=row['round'],start_seconds=start,end_seconds=end,sample_seconds=sum(e['seconds'] for e in window),progress=sum(e['progress'] for e in window),mops=sum(e['progress'] for e in window)/sum(e['seconds'] for e in window)/1e6))
  holds=[e for e in decisions if e['action']=='hold'];completed=[e for e in migrations if not e.get('cancelled')]
  details.append(dict(case=case,round=int(row['round']),mode=row['mode'],mops=float(row['mops']),decisions=decisions,held_ratio_bp=holds[-1]['ratio_bp'] if holds else None,last_completed_migration_bp=completed[-1]['ratio_bp'] if completed else None,migration_seconds=sum(e['seconds'] for e in migrations),moved_bytes=sum(e['moved']*4096 for e in migrations),monitor_mops=sum(e['progress'] for e in monitor)/sum(e['seconds'] for e in monitor)/1e6 if monitor else None,final_target_bytes=migrations[-1]['target_pages']*4096 if migrations else 0,peak_observed_target_bytes=max((e['target_pages']*4096 for e in migrations),default=0),cancelled_shutdown_migrations=[e for e in migrations if e.get('cancelled')]))
if summary:
 with (base/'summary.csv').open('w') as f:w=csv.DictWriter(f,fieldnames=list(summary[0]),lineterminator='\n');w.writeheader();w.writerows(summary)
(base/'controller-summary.json').write_text(json.dumps(details,indent=2)+'\n')
if phase_windows:
 with (base/'phase-windows.csv').open('w') as f:w=csv.DictWriter(f,fieldnames=list(phase_windows[0]),lineterminator='\n');w.writeheader();w.writerows(phase_windows)
for r in summary:print(r['case'],r['reference'],'->',r['treatment'],f"{r['paired_change_pct']:+.2f}%",'pairs',r['pairs'])

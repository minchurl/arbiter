import csv,statistics
from pathlib import Path
out=Path('results/libcuckoo/object-rmw-20261119')
rows=list(csv.DictReader((out/'libcuckoo-runs.csv').open()))
def write(name,records):
 if not records:return
 with (out/name).open('w') as f:
  w=csv.DictWriter(f,fieldnames=list(records[0]),lineterminator="\n");w.writeheader();w.writerows(records)
groups={}
for row in rows:
 name=row['experiment']
 if name.startswith('confirm-r'):key=f"existing-r{row['read_pct']}-h{row['hot_keys']}"
 elif name.startswith(('universal-confirm-','universal-repeat-')):key=f"universal-r{row['read_pct']}"
 elif name.startswith('control-confirm-'):key=name
 else:continue
 groups.setdefault(key,[]).append(row)
summary=[]
for key,data in groups.items():
 record=dict(case=key,rounds=len(data)//3)
 means={mode:statistics.mean(float(r['mops']) for r in data if r['mode']==mode) for mode in ['native','local','cxl']}
 for mode in means:
  values=[float(r['mops']) for r in data if r['mode']==mode]
  record.update({mode+'_mean_mops':means[mode],mode+'_min_mops':min(values),mode+'_max_mops':max(values)})
 seeds=sorted({r['seed'] for r in data});assert len(seeds)==record['rounds']
 paired=[]
 for seed in seeds:
  values={r['mode']:float(r['mops']) for r in data if r['seed']==seed};assert len(values)==3
  paired.append((values['cxl']/values['local']-1)*100)
 record.update(cxl_over_local_pct=(means['cxl']/means['local']-1)*100,paired_pct_min=min(paired),paired_pct_max=max(paired),cxl_faster_pairs=sum(v>0 for v in paired))
 summary.append(record)
write('placement-summary.csv',summary)
algorithm=[]
for reads,hot in [(0,64),(0,256),(0,65536),(0,1048576),(50,64)]:
 for mode in ['native','local','cxl']:
  base=[r for r in rows if r['experiment']==f'variant-confirm-baseline-r{reads}-h{hot}' and r['mode']==mode]
  if len(base)!=3:continue
  for variant in ['ttas','ttas-padded']:
   candidate=[r for r in rows if r['experiment']==f'variant-confirm-{variant}-r{reads}-h{hot}' and r['mode']==mode]
   if len(candidate)!=3:continue
   b={r['seed']:float(r['mops']) for r in base};c={r['seed']:float(r['mops']) for r in candidate};assert b.keys()==c.keys()
   paired=[c[k]/b[k] for k in b]
   algorithm.append(dict(read_pct=reads,hot_keys=hot,mode=mode,variant=variant,rounds=3,baseline_mops=statistics.mean(b.values()),candidate_mops=statistics.mean(c.values()),speedup=statistics.mean(c.values())/statistics.mean(b.values()),paired_speedup_min=min(paired),paired_speedup_max=max(paired),baseline_rss_mib=statistics.mean(int(r['max_rss_kb']) for r in base)/1024,candidate_rss_mib=statistics.mean(int(r['max_rss_kb']) for r in candidate)/1024))
write('algorithm-summary.csv',algorithm)
for r in summary:print(r['case'],r['rounds'],f"{r['local_mean_mops']:.2f} -> {r['cxl_mean_mops']:.2f} ({r['cxl_over_local_pct']:+.2f}%)")
for r in algorithm:
 if r['mode']=='local':print('algorithm',r['read_pct'],r['hot_keys'],r['variant'],f"{r['speedup']:.3f}x",f"{r['baseline_mops']:.2f} -> {r['candidate_mops']:.2f}")

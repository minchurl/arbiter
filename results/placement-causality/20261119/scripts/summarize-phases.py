import argparse,csv,json,re
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('directories',nargs='+');args=p.parse_args()
rows=[]
for name in args.directories:
 d=Path(name);manifest=json.loads((d/'manifest.json').read_text());assert manifest.get('valid')
 points=[]
 for match in re.finditer(r'Throughput sample (elapsed_sec=.*)',(d/'output.log').read_text()):
  point={k:float(v) for k,v in re.findall(r'(\w+)=([^\s]+)',match[1])};points.append(point)
 phases=json.loads((d/'phases.json').read_text());result=[]
 clock=json.loads((d/'clock-alignment.json').read_text()) if (d/'clock-alignment.json').exists() else None
 delta=manifest.get('phase_clock_monotonic',manifest.get('run_observed_monotonic',0))-clock['start_estimate'] if clock else 0
 for phase in phases:
  chosen=[p for p in points if p['elapsed_sec']-p['interval_sec']>=phase['stable_from_elapsed']+delta and p['elapsed_sec']<=phase['end_elapsed']+delta]
  assert len(chosen)>=5,(d,phase)
  ops=sum(p['interval_ops'] for p in chosen);seconds=sum(p['interval_sec'] for p in chosen)
  row=dict(case=d.name,selected_node=manifest['args']['node'],binary=manifest['args']['binary'],foreground_workers=manifest['args']['fg'],intervention_node=(manifest['args'].get('alternate_node') if manifest['args'].get('alternate_node') is not None else (2 if manifest['args']['node']==0 else 0)),profile=bool(manifest['args'].get('profile',False) or manifest['args'].get('phase_stat',False)),instrumentation=('perf_record_'+manifest['args'].get('profile_kind','retry') if manifest['args'].get('profile') else 'perf_stat' if manifest['args'].get('phase_stat') else 'none'),phase=phase['phase'],name=phase['name'],samples=len(chosen),operations=int(ops),seconds=seconds,mops=ops/seconds/1e6,min_mops=min(p['interval_ops_per_sec']/1e6 for p in chosen),max_mops=max(p['interval_ops_per_sec']/1e6 for p in chosen),gain_vs_adjacent_baselines_pct='')
  result.append(row)
 for i,row in enumerate(result):
  if row['name']!='baseline' and 0<i<len(result)-1 and result[i-1]['name']==result[i+1]['name']=='baseline':
   baseline=(result[i-1]['mops']+result[i+1]['mops'])/2;row['gain_vs_adjacent_baselines_pct']=100*(row['mops']/baseline-1)
  print(d.name,row['phase'],row['name'],round(row['mops'],3),row['gain_vs_adjacent_baselines_pct'])
 with (d/'phase-summary.csv').open('w') as f:
  w=csv.DictWriter(f,fieldnames=list(result[0]),lineterminator='\n');w.writeheader();w.writerows(result)
 rows+=result

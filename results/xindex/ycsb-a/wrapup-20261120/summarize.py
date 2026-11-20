"""Summarize only the nine accepted, untraced full YCSB-A runs."""
import argparse,csv,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--base',type=Path,default=Path('build/xindex-ycsb-a-wrapup'));base=p.parse_args().base;f=base/'final-runs/runs.csv';f=f if f.exists() else base/'runs.csv';rows=list(csv.DictReader(f.open()));assert len(rows)==9 and all(r['valid']=='True' for r in rows);summary=[];comparisons=[]
cells={m:{int(r['round']):r for r in rows if r['mode']==m} for m in ('native','local','cxl')};assert all(set(v)=={1,2,3} for v in cells.values())
for mode,cell in cells.items():
 r=list(cell.values());rates=[float(x['mtx_s']) for x in r];rss=[int(x['peak_rss_kib'])/1024**2 for x in r]
 summary.append(dict(mode=mode,runs=3,mean_mtx_s=statistics.mean(rates),min_mtx_s=min(rates),max_mtx_s=max(rates),mean_peak_rss_gib=statistics.mean(rss),min_peak_rss_gib=min(rss),max_peak_rss_gib=max(rss),mean_selected_resident_gib=statistics.mean(int(x['selected_resident_bytes'])/1024**3 for x in r),mean_wall_seconds=statistics.mean(float(x['wall_seconds']) for x in r)))
for a,b in [('native','local'),('local','cxl'),('native','cxl')]:
 delta=[(float(cells[b][i]['mtx_s'])/float(cells[a][i]['mtx_s'])-1)*100 for i in (1,2,3)]
 comparisons.append(dict(reference=a,treatment=b,pairs=3,mean_paired_change_pct=statistics.mean(delta),min_pair_pct=min(delta),max_pair_pct=max(delta),positive_pairs=sum(x>0 for x in delta)))
for name,data in [('summary.csv',summary),('comparisons.csv',comparisons)]:
 with (base/name).open('w') as out:w=csv.DictWriter(out,fieldnames=data[0],lineterminator='\n');w.writeheader();w.writerows(data)
for r in summary:print(r)
for r in comparisons:print(r)

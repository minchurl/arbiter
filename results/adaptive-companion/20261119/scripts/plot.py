"""Standalone research figures: full-duration results and online transitions."""
import argparse,csv,gzip,json,statistics
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
plt.rcParams['svg.hashsalt']='arbiter-adaptive-20261119'
p=argparse.ArgumentParser();p.add_argument('--base',type=Path,default=Path('build/adaptive-companion'));args=p.parse_args();base=args.base
raw=None
def events(case,mode='adapt'):
 global raw
 path=base/case/f'1-{mode}-attempt1.events.json'
 # Use the accepted attempt if the first one was rejected by the host guard.
 row=next(r for r in csv.DictReader((base/case/'runs.csv').open()) if r['round']=='1' and r['mode']==mode)
 name=f"1-{mode}-attempt{row['attempt']}.events.json";path=base/case/name
 if path.exists():return json.loads(path.read_text())
 if raw is None:raw=[json.loads(s) for s in gzip.decompress((base/'raw-files.jsonl.gz').read_bytes()).decode().splitlines()]
 return json.loads(next(r['text'] for r in raw if r['case']==case and r['file']==name))
fig,axes=plt.subplots(2,2,figsize=(12,7.3),layout='constrained')
for col,case in enumerate(['confirm-h16','confirm-h256']):
 ax=axes[0,col];rows=list(csv.DictReader((base/case/'runs.csv').open()))
 for i,mode in enumerate(['plain','observe','adapt']):
  v=[float(r['mops']) for r in rows if r['mode']==mode]
  ax.bar(i,statistics.mean(v),color=['#BBBBBB','#88AACC','#3377AA'][i],width=.65)
  ax.scatter([i+.07*(j-(len(v)-1)/2) for j in range(len(v))],v,c='black',s=18,zorder=3)
  ax.text(i,max(v)*1.035,f'{statistics.mean(v):.2f}',ha='center')
 ax.set_xticks([0,1,2],['No observer','Observer only','Online adaptive']);ax.set_ylim(0,ax.get_ylim()[1]*1.1);ax.set_ylabel('Full-run Mops/s');ax.set_title(case.replace('confirm-h','')+' entries: 120 s, 3 fresh runs per mode')
 ax=axes[1,col];data=events(case);samples=[e for e in data if e['event']=='sample'];ax.plot([e['time'] for e in samples],[e['rate']/1e6 for e in samples],color='#3377AA',marker='.',markersize=3,label='Progress rate')
 moves=[e for e in data if e['event']=='migration'];ratio=ax.twinx();ratio.step([0]+[e['time'] for e in moves]+[samples[-1]['time']],[0]+[100*e['target_pages']/e['resident_pages'] for e in moves]+[100*moves[-1]['target_pages']/moves[-1]['resident_pages']],where='post',color='#AA7733',alpha=.7,label='Verified CXL %');ratio.set_ylim(-2,55);ratio.set_ylabel('Verified companion CXL %')
 for m in [e for e in data if e['event']=='migration']:ax.axvspan(m['time']-m['seconds'],m['time'],color='gray',alpha=.15)
 ax.set_xlabel('Seconds since controller start');ax.set_ylabel('Progress Mops/s');ax.set_title('Round 1 online trace; gray = query/move/verify')
for ax in axes.flat:ax.grid(axis='y',alpha=.2);ax.spines[['top','right']].set_visible(False)
fig.suptitle('One controller, no workload profiles; exploration and migration included in full-run results')
fig.savefig(base/'adaptive-results.png',dpi=180);fig.savefig(base/'adaptive-results.svg',metadata={'Date':None})
fig,axes=plt.subplots(2,1,figsize=(11,5.5),layout='constrained',sharex=True)
for mode,color in [('observe','#777777'),('adapt','#3377AA')]:
 data=events('phase-affinity',mode);samples=[e for e in data if e['event']=='sample']
 axes[0].plot([e['time'] for e in samples],[e['rate']/1e6 for e in samples],label=mode,color=color)
 if mode=='adapt':
  moves=[e for e in data if e['event']=='migration'];axes[1].step([0]+[e['time'] for e in moves]+[samples[-1]['time']],[0]+[100*e['target_pages']/e['resident_pages'] for e in moves]+[100*moves[-1]['target_pages']/moves[-1]['resident_pages']],where='post',color=color)
  for m in [e for e in data if e['event']=='migration']:
   for ax in axes:ax.axvspan(m['time']-m['seconds'],m['time'],color='gray',alpha=.15)
for ax in axes:ax.axvline(90,color='#AA7733',linestyle='--');ax.grid(alpha=.2)
axes[0].legend();axes[0].set_ylabel('Progress Mops/s');axes[0].set_title('Exploratory condition change: 32 workers restricted to 8 CPUs around 90 s')
axes[1].set_ylabel('Verified CXL %');axes[1].set_xlabel('Seconds since controller start; CPU restriction is timed from launch')
fig.savefig(base/'adaptive-phase.png',dpi=180);fig.savefig(base/'adaptive-phase.svg',metadata={'Date':None})

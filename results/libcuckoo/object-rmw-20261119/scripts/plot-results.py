"""Standalone figure from retained data; ranges are observations, not CIs."""
import csv
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
matplotlib.rcParams['svg.fonttype']='none'
matplotlib.rcParams['svg.hashsalt']='libcuckoo-object-rmw-20261119'
import matplotlib.pyplot as plt
out=Path('results/libcuckoo/object-rmw-20261119')
rows=list(csv.DictReader((out/'libcuckoo-runs.csv').open()))
placement={r['case']:r for r in csv.DictReader((out/'placement-summary.csv').open())}
algorithm=list(csv.DictReader((out/'algorithm-summary.csv').open()))
assert all(int(placement['universal-r'+str(r)]['rounds'])==8 for r in [0,10,50,100])
assert len(algorithm)==30
fig,(ax,bx)=plt.subplots(1,2,figsize=(14,6.8),gridspec_kw={'width_ratios':[1.2,1]})
cases=[('existing-r0-h64','Existing: R0 / 64 keys'),('existing-r0-h4096','Existing: R0 / 4K'),('existing-r0-h65536','Existing: R0 / 64K'),('existing-r0-h1048576','Existing: R0 / 1M'),('existing-r50-h65536','Existing: R50 / 64K'),('existing-r100-h1048576','Existing: R100 / 1M')]+[('universal-r'+str(r),'Universal: R'+str(r)) for r in [0,10,50,100]]
for y,(case,label) in enumerate(cases):
 if case.startswith('existing-'):
  data=[r for r in rows if r['experiment']=='confirm-'+case.removeprefix('existing-')]
 else:
  mix=case.removeprefix('universal-');data=[r for r in rows if r['experiment'] in ['universal-confirm-'+mix,'universal-repeat-'+mix]]
 seeds=sorted({r['seed'] for r in data})
 ratios=[]
 for seed in seeds:
  values={r['mode']:float(r['mops']) for r in data if r['seed']==seed};ratios.append(values['cxl']/values['local'])
 ax.scatter(ratios,[y]*len(ratios),s=24,c='#a0a7b4',alpha=.8,label='Paired runs' if y==0 else None,zorder=2)
 mean=float(placement[case]['cxl_mean_mops'])/float(placement[case]['local_mean_mops'])
 ax.scatter([mean],[y],s=58,c='#205dac',marker='D',label='Ratio of means' if y==0 else None,zorder=3)
ax.axvline(1,c='#454545',ls='--',lw=1)
ax.set_yticks(range(len(cases)),[label for _,label in cases]);ax.invert_yaxis()
ax.set_title('Placement: original libcuckoo',loc='left',fontweight='bold')
ax.set_xlabel('CXL / Local throughput');ax.grid(axis='x',alpha=.2);ax.legend(frameon=False,loc='upper left')
labels=[]
for y,(reads,hot) in enumerate([(0,64),(0,256),(0,65536),(0,1048576),(50,64)]):
 labels.append(f'R{reads} / '+{64:'64 keys',256:'256 keys',65536:'64K keys',1048576:'1M keys'}[hot])
 for variant,offset,color,label in [('ttas',-.12,'#1a7a57','TTAS'),('ttas-padded',.12,'#bf710d','TTAS + padding')]:
  r=next(r for r in algorithm if int(r['read_pct'])==reads and int(r['hot_keys'])==hot and r['mode']=='local' and r['variant']==variant)
  mean=float(r['speedup']);lo=float(r['paired_speedup_min']);hi=float(r['paired_speedup_max'])
  bx.errorbar(mean,y+offset,xerr=[[max(0,mean-lo)],[max(0,hi-mean)]],fmt='o',color=color,capsize=4,label=label if y==0 else None)
bx.axvline(1,c='#454545',ls='--',lw=1);bx.set_yticks(range(5),labels);bx.invert_yaxis()
bx.set_title('Lock changes: Local memory',loc='left',fontweight='bold');bx.set_xlabel('Throughput / fresh original baseline')
bx.grid(axis='x',alpha=.2);bx.legend(frameon=False,loc='upper left')
for a in [ax,bx]:
 a.spines[['top','right']].set_visible(False);a.tick_params(axis='both',labelsize=10)
fig.suptitle('Libcuckoo: allocation placement and lock-algorithm effects',fontsize=15,fontweight='bold',x=.04,ha='left')
fig.text(.04,.025,'32 workers. R = read percentage. Existing-key writes always succeed; universal ratios count attempts.\nPlacement: 3 existing-key / 8 universal rounds. Algorithms: 3 rounds; whiskers show paired min/max, not confidence intervals. Padding adds 28 MiB RSS.',fontsize=9,color='#454545')
fig.tight_layout(rect=[0,.11,1,.94],w_pad=3)
fig.savefig(out/'performance.png',dpi=180)
svg=out/'performance.svg'
fig.savefig(svg,metadata={'Date':None})
svg.write_text('\n'.join(line.rstrip() for line in svg.read_text().splitlines())+'\n')

"""Standalone research figure; screens are visibly separate from confirmations."""
import argparse,csv,json,statistics
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
p=argparse.ArgumentParser();p.add_argument('--base',type=Path,default=Path('build/budgeted-companion'));args=p.parse_args();base=args.base
fig,axes=plt.subplots(1,3,figsize=(13.5,4.3),layout='constrained')
panels=[('confirm-h16','16 entries: fresh confirmation', ['original','seed','local','half','cap4g']),('screen-h256','256 entries: exploratory screen',['seed','local','half','cap1g','cap4g','full']),('regression-xindex','XIndex: full YCSB-A regression',['seed-local','original','seed'])]
labels={'original':'Original\nseed CXL','seed':'New\nseed CXL','seed-local':'New\nseed DRAM','local':'Companion\nDRAM','half':'Companion\n50% CXL','cap1g':'CXL cap\n1 GiB','cap4g':'CXL cap\n4 GiB','full':'Companion\n100% CXL'}
for ax,(case,title,order) in zip(axes,panels):
    rows=list(csv.DictReader((base/case/'runs.csv').open()));order=[s for s in order if any(r['strategy']==s for r in rows)]
    for i,s in enumerate(order):
        values=[float(r['mops']) for r in rows if r['strategy']==s]
        color='#4477AA' if s in ['half','cap4g'] else '#BBBBBB'
        ax.bar(i,statistics.mean(values),color=color,width=.66,zorder=2)
        ax.scatter([i+(j-(len(values)-1)/2)*.055 for j in range(len(values))],values,color='#222222',s=14,zorder=3)
        ax.text(i,max(values)*1.04,f'{statistics.mean(values):.1f}',ha='center',fontsize=9)
    ax.set_xticks(range(len(order)),[labels[s] for s in order],fontsize=8);ax.set_title(title,fontsize=11);ax.set_ylabel('Throughput (Mops/s)');ax.set_ylim(bottom=0,top=ax.get_ylim()[1]*1.13);ax.grid(axis='y',alpha=.2,zorder=0);ax.spines[['top','right']].set_visible(False)
fig.suptitle('Compiler-discovered companions, first-touch placement, unchanged benchmark sources',fontsize=13)
fig.savefig(base/'performance.png',dpi=180);fig.savefig(base/'performance.svg')

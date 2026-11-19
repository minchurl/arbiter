"""Publication-style static comparison from retained paired summaries."""
import argparse,csv,json,statistics
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

p=argparse.ArgumentParser();p.add_argument('--base',type=Path,default=Path('results/companion-placement/20261119'));args=p.parse_args();base=args.base
rows=list(csv.DictReader((base/'summary.csv').open()))
def find(case,treatment):return next(r for r in rows if r['case']==case and r['treatment']==treatment)
plt.rcParams.update({'font.size':10,'axes.spines.top':False,'axes.spines.right':False,'axes.titleweight':'bold','svg.hashsalt':'companion-placement-20261119'})
fig,axes=plt.subplots(2,2,figsize=(13,9),layout='constrained')
ax=axes[0,0];fraction=[0,1,5,10];mean=[100.];low=[0.];high=[0.]
for n in fraction[1:]:
    r=find('confirm-micro-default',f'table2-ballast{n}');v=float(r['paired_percent']);mean.append(100+v)
    low.append(v-float(r['bootstrap_low_percent']));high.append(float(r['bootstrap_high_percent'])-v)
ax.errorbar(fraction,mean,yerr=[low,high],marker='o',color='#b85a28',capsize=4)
ax.axhline(100,color='#888',ls='--',lw=1);ax.set(xticks=fraction,xlabel='Ballast pages in CXL (%)',ylabel='Throughput / table-only control (%)',title='Micro: default 256 entries, 50% reads')
for x,y in zip(fraction,mean):ax.annotate(f'{y:.1f}%',(x,y),xytext=(0,8),textcoords='offset points',ha='center')
ax.grid(axis='y',alpha=.15)
ax=axes[0,1];plan=json.loads((base/'confirmation-plan.json').read_text());s=json.loads(plan['micro_best_screen']['workload']);pct=int(plan['micro_best_screen']['treatment'].split('ballast')[1])
values=list(csv.DictReader((base/'confirm-micro-best/runs.csv').open()));labels=[];means=[];sds=[]
for node,f in [(0,0),(0,pct),(2,0),(2,pct)]:
    a=[float(r['mops']) for r in values if int(r['table_node'])==node and int(r['ballast_percent'])==f]
    labels.append(('Local' if node==0 else 'CXL')+f' table\n{f}% ballast CXL');means.append(statistics.mean(a));sds.append(statistics.stdev(a))
ax.bar(range(4),means,yerr=sds,capsize=4,color=['#467998','#b85a28','#467998','#b85a28'])
for x,(mean,sd) in enumerate(zip(means,sds)):ax.text(x,mean+sd+.3,f'{mean:.2f}',ha='center',fontsize=9)
ax.set(xticks=range(4),xticklabels=labels,ylabel='Mops/s',title=f"Micro: fresh confirmation of best screen\n{s['table']} entries, {s['reads']}% reads")
ax.grid(axis='y',alpha=.15)
ax=axes[1,0];hot=['64','65536','1m','8m','32m'];variant=['lock','bucket','both'];matrix=[];notes=[]
for h in hot:
    row=[];note=[]
    for v in variant:
        case=f'confirm-cuckoo-hot{h}' if h in ['64','65536'] else 'confirm-cuckoo-hot1m-lock' if h=='1m' and v=='lock' else f'screen-cuckoo-hot{h}'
        r=find(case,v);row.append(float(r['paired_percent']));note.append(f"{float(r['paired_percent']):+.1f}%\nn={r['n']}")
    matrix.append(row);notes.append(note)
im=ax.imshow(matrix,cmap='RdBu',vmin=-100,vmax=100,aspect='auto')
for i in range(5):
    for j in range(3):ax.text(j,i,notes[i][j],ha='center',va='center',color='white' if matrix[i][j]<-60 else '#202020')
ax.set(xticks=range(3),xticklabels=['Lock','Bucket','Both'],yticks=range(5),yticklabels=['64','65,536','1,048,576','8,388,608','33,554,432'],ylabel='Uniform hot-key range',title='Libcuckoo: 100% successful updates\nCXL versus matching Local allocation variant')
fig.colorbar(im,ax=ax,label='Paired throughput change (%)',shrink=.8)
ax=axes[1,1];values=list(csv.DictReader((base/'xindex-regression/runs.csv').open()))
for x,node,color in [(0,'0','#467998'),(1,'2','#b85a28')]:
    a=[float(r['mops']) for r in values if r['node']==node]
    ax.bar(x,statistics.mean(a),yerr=statistics.stdev(a),capsize=4,color=color)
    ax.scatter([x]*len(a),a,color='#222',s=18,zorder=3)
r=find('xindex-regression','auto');ax.set(xticks=[0,1],xticklabels=['Local','CXL'],ylabel='Mops/s',title=f"XIndex YCSB-A: unchanged automatic policy\n400M operations/run, n=3, {float(r['paired_percent']):+.1f}%")
ax.grid(axis='y',alpha=.15)
fig.suptitle('Companion placement with frozen benchmark code',fontsize=16)
fig.supxlabel('Libcuckoo n=5: untraced confirmations; n=2: exploratory screens. Bars: mean +/− sample SD. Micro curve: paired bootstrap 95% intervals.',fontsize=8)
fig.savefig(base/'performance.png',dpi=180);fig.savefig(base/'performance.svg',metadata={'Date':None})
plt.close(fig)

if (base/'confirm-micro-refined/runs.csv').exists():
    fig,axes=plt.subplots(2,2,figsize=(13,9),layout='constrained')
    ax=axes[0,0]
    for case,label,color,style in [('screen-micro-fractions-wide','Screen: 2 processes / cell','#999999','--'),('confirm-micro-refined','Fresh confirmation: 5 processes / cell','#b85a28','-')]:
        data=list(csv.DictReader((base/case/'runs.csv').open()));fractions=sorted({int(r['ballast_percent']) for r in data});means=[];sds=[]
        for fraction in fractions:
            a=[float(r['mops']) for r in data if int(r['ballast_percent'])==fraction]
            means.append(statistics.mean(a));sds.append(statistics.stdev(a))
        ax.errorbar(fractions,means,yerr=sds,marker='o',color=color,ls=style,capsize=4,label=label)
    ax.set(xlabel='Ballast pages in CXL (%)',ylabel='Mops/s',title='16 entries, 50% reads, table in CXL')
    ax.legend(fontsize=8);ax.grid(alpha=.15)
    crossover=base/'crossover-micro/phases.csv'
    if crossover.exists():
        data=list(csv.DictReader(crossover.open()));x=[int(r['phase'])+1 for r in data];fractions=[int(r['ballast_percent']) for r in data]
        ax=axes[0,1];ax.plot(x,[float(r['mops']) for r in data],color='#467998',marker='o')
        for a,r in zip(x,data):ax.annotate(f"{float(r['mops']):.1f}",(a,float(r['mops'])),xytext=(0,8),textcoords='offset points',ha='center',fontsize=8)
        ax.set(xticks=x,xticklabels=[f'{a}\n{f}%' for a,f in zip(x,fractions)],xlabel='Consecutive phase / ballast CXL fraction',ylabel='Mops/s',title='One process: migrate and restore ballast pages')
        ax.grid(alpha=.15)
        ax=axes[1,0]
        for key,label,color in [('ocr.demand_rfo.l3_hit.snoop_hitm:u','RFO HITM','#b85a28'),('ocr.demand_data_rd.l3_hit.snoop_hitm:u','Demand-read HITM','#467998')]:
            ax.plot(x,[float(r[key]) for r in data],marker='o',label=label,color=color)
        ax.set(xticks=x,xticklabels=[f'{a}\n{f}%' for a,f in zip(x,fractions)],xlabel='Consecutive phase / ballast CXL fraction',ylabel='Events / completed operation',title='Selected HITM responses (not all coherence traffic)')
        ax.legend(fontsize=8);ax.grid(alpha=.15)
        ax=axes[1,1];ax.plot(x,[float(r['mem_inst_retired.lock_loads:u']) for r in data],marker='o',color='#647d38')
        ax.set(xticks=x,xticklabels=[f'{a}\n{f}%' for a,f in zip(x,fractions)],xlabel='Consecutive phase / ballast CXL fraction',ylabel='Locked loads / completed operation',title='CAS-attempt proxy in the same process')
        ax.axhline(.5,color='#888888',ls='--',lw=1,label='Expected successful writes / operation');ax.legend(fontsize=8);ax.grid(alpha=.15)
    fig.suptitle('A profitable placement range in a more contended micro workload',fontsize=15)
    fig.supxlabel('Whole-process error bars: sample SD. Crossover: one diagnostic process; 15-second perf windows, enclosing read-only epoch snapshots. Migration excluded.',fontsize=8)
    fig.savefig(base/'placement-window.png',dpi=180);fig.savefig(base/'placement-window.svg',metadata={'Date':None})

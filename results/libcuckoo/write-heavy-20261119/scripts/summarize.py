"""Regenerate summaries from retained rows and separate diagnostic files."""
import csv
import gzip
import json
import re
import statistics
from pathlib import Path

base=Path(__file__).resolve().parents[1]

def write(name, rows):
    with (base/name).open('w') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]),lineterminator='\n');w.writeheader();w.writerows(rows)

rows=list(csv.DictReader((base/'runs.csv').open()))
cases=json.loads((base/'cases.json').read_text())+json.loads((base/'extra-cases.json').read_text())
summary=[]
for case in cases:
    name=case['name']
    group=[r for r in rows if r['phase']=='confirm' and r['case']==name]
    modes={m:[r for r in group if r['mode']==m] for m in ['local','cxl']}
    assert len(modes['local'])==len(modes['cxl'])==case['rounds']
    pairs=[]
    for local in modes['local']:
        cxl=next(r for r in modes['cxl'] if r['round']==local['round'])
        assert local['operations']==cxl['operations']
        pairs.append(100*(float(cxl['mops'])/float(local['mops'])-1))
    means={m:statistics.mean(float(r['mops']) for r in rs) for m,rs in modes.items()}
    native=[float(r['mops']) for r in rows if r['phase']=='native' and r['case']==name]
    summary.append(dict(case=name,rounds_per_mode=case['rounds'],operations=group[0]['operations'],local_mean_mops=means['local'],cxl_mean_mops=means['cxl'],ratio_of_means_pct=100*(means['cxl']/means['local']-1),mean_paired_pct=statistics.mean(pairs),paired_min_pct=min(pairs),paired_max_pct=max(pairs),positive_pairs=sum(p>0 for p in pairs),min_timed_seconds=min(float(r['timed_seconds']) for r in group),max_timed_seconds=max(float(r['timed_seconds']) for r in group),native_rounds=len(native),native_mean_mops=statistics.mean(native) if native else '',sites=';'.join(sorted({site for r in group for site in r['sites'].split(';')})),max_rss_kb=max(int(r['max_rss_kb']) for r in group)))
write('summary.csv',summary)

counters=[]
for path in sorted((base/'profiles').glob('stat-*.perf.csv')):
    stem=path.name.removesuffix('.perf.csv'); _,hot,mode=stem.split('-')
    data=json.loads((path.parent/(stem+'.json')).read_text()); ops=data['reads']+data['updates']
    for r in csv.reader(path.open()):
        if len(r)<5 or not r[2].startswith(('cycles','instructions','mem_','ocr.')):continue
        count=float(r[0]); running=float(r[4]); assert count>0 and running>99.9,(stem,r)
        counters.append(dict(hot=int(hot[3:]),mode=mode,event=r[2],count=int(count),timed_operations=ops,per_timed_operation=count/ops,running_pct=running,scope='whole_process_includes_setup_and_validation'))
assert len(counters)==24
write('counters.csv',counters)
samples=[]
for path in sorted((base/'profiles').glob('samples-*.samples.txt.gz')):
    stem=path.name.removesuffix('.samples.txt.gz'); _,hot,mode=stem.split('-')
    ranges=[]
    for line in (path.parent/(stem+'.mbind.log')).read_text().splitlines():
        m=re.search(r'mbind\((0x[0-9a-f]+),\s*(\d+),',line)
        if m and re.search(r'= 0\s*$',line):ranges.append((int(m[1],16),int(m[1],16)+int(m[2])))
    assert ranges
    decoded=gzip.decompress(path.read_bytes()).decode()
    diagnostics=decoded+(path.parent/(stem+'.stderr')).read_text()+(path.parent/(stem+'.decode.stderr')).read_text()
    assert not re.search(r'LOST|lost',diagnostics),stem
    groups={}
    for line in decoded.splitlines():
        m=re.search(r'(mem_[\w.]+:upp):\s*(?:0x)?([0-9a-f]+)\s*$',line)
        if not m:continue
        address=int(m[2],16); row=groups.setdefault(m[1],dict(samples=0,in_arena=0,outside_arena=0,zero_address=0))
        row['samples']+=1
        if not address:row['zero_address']+=1
        elif any(start<=address<end for start,end in ranges):row['in_arena']+=1
        else:row['outside_arena']+=1
    assert len(groups)==2
    for event,row in groups.items():
        samples.append(dict(hot=int(hot[3:]),mode=mode,event=event,**row,arena_pct=100*row['in_arena']/(row['samples']-row['zero_address']),reported_lost_events=0,scope='whole_process_selected_arena_extents'))
write('address-samples.csv',samples)
for r in summary:
    print(f"{r['case']}: {r['local_mean_mops']:.3f} -> {r['cxl_mean_mops']:.3f} Mops/s; {r['ratio_of_means_pct']:+.2f}% [{r['paired_min_pct']:+.2f}, {r['paired_max_pct']:+.2f}], {r['positive_pairs']}/{r['rounds_per_mode']} positive; {r['min_timed_seconds']:.2f}-{r['max_timed_seconds']:.2f}s")

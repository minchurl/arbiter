"""Reject throughput measurements overlapping another CPU-heavy process."""
import os,time
from pathlib import Path
HZ=os.sysconf('SC_CLK_TCK')
POLICY='Five quiet seconds before each run; reject overlap with a foreign process consuming more than one CPU core in a sampled interval. Small background-service bursts remain ordinary host noise. Initial screen-h16 used the stricter 0.15-core threshold.'
def snapshot():
    result={}
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():continue
        try:
            if not (path/'cmdline').read_bytes():continue
            text=(path/'stat').read_text();end=text.rindex(')');fields=text[end+2:].split()
            result[int(path.name)]=dict(parent=int(fields[1]),ticks=int(fields[11])+int(fields[12]),start=int(fields[19]),name=text[text.index('(')+1:end])
        except (FileNotFoundError,ProcessLookupError,PermissionError):pass
    return time.monotonic(),result
def descendants(rows,root):
    found={root};changed=True
    while changed:
        before=len(found)
        found.update(pid for pid,r in rows.items() if r['parent'] in found)
        changed=len(found)!=before
    return found
def foreign(before,after,root=None):
    a,old=before;b,new=after;excluded={os.getpid()}
    if root is not None:excluded|=descendants(old,root)|descendants(new,root)
    busy=[]
    for pid,r in new.items():
        if pid in excluded or pid not in old or old[pid]['start']!=r['start']:continue
        cpu=(r['ticks']-old[pid]['ticks'])/HZ/(b-a)
        if cpu>1:busy.append(dict(pid=pid,name=r['name'],cpu_cores=cpu))
    return busy
def wait_quiet(log):
    steady=0;last=snapshot();announced=0
    while steady<5:
        time.sleep(1);now=snapshot();busy=foreign(last,now);last=now
        steady=0 if busy else steady+1
        if busy:
            log.append(dict(time=time.time(),stage='waiting',processes=busy))
            if time.monotonic()-announced>60:
                print('WAIT host busy:',[(x['name'],round(x['cpu_cores'],2)) for x in busy],flush=True);announced=time.monotonic()

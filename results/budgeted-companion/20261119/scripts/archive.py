"""Archive reviewable summaries plus losslessly compressed raw evidence."""
import csv,gzip,hashlib,json,shutil
from pathlib import Path
root=Path.cwd();base=root/'build/budgeted-companion';out=root/'results/budgeted-companion/20261119'
assert 'FINISHED CHECKS' in (base/'finish.console').read_text()
assert all(r['passed'] for r in json.loads((base/'launcher-checks.json').read_text()))
out.mkdir(parents=True,exist_ok=False);raw=[]
for folder in sorted(base.iterdir()):
    if not folder.is_dir() or folder.name in ['compiler','scripts','reproduction']:continue
    files=[p for p in folder.iterdir() if p.is_file() and p.suffix in ['.json','.csv','.log','.plan','.gdb','.smaps','.time','.cpp','.h']]
    if not files:continue
    dest=out/folder.name;dest.mkdir()
    for p in files:
        if p.name in ['manifest.json','runs.csv','summary.json','checks.json','old-seeds.csv','new-seeds.csv','worker-equivalence.json'] or (folder.name=='historical' and p.suffix=='.csv') or folder.name=='accepted-plans':shutil.copy2(p,dest/p.name)
        else:raw.append(dict(case=folder.name,file=p.name,text=p.read_bytes().decode()))
for p in sorted(base.iterdir()):
    if not p.is_file():continue
    if p.name.startswith('interim-'):continue
    if p.name=='firsttouch.console':
        raw.append(dict(case='rejected-firsttouch-contention',file='driver.console',text=p.read_bytes().decode()));continue
    if p.suffix in ['.json','.csv','.console','.png','.svg']:shutil.copy2(p,out/p.name)
    elif p.suffix in ['.log','.cpp','.h']:raw.append(dict(case='tools-and-checks',file=p.name,text=p.read_bytes().decode()))
shutil.copytree(base/'scripts',out/'scripts',ignore=shutil.ignore_patterns('__pycache__'))
(out/'raw-files.jsonl.gz').write_bytes(gzip.compress(''.join(json.dumps(r)+'\n' for r in raw).encode(),mtime=0))
# Prove archive encoding is byte-preserving before recording checksums.
decoded=[json.loads(line) for line in gzip.decompress((out/'raw-files.jsonl.gz').read_bytes()).decode().splitlines()]
assert decoded==raw
(out/'artifacts.sha256').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(out))+'\n' for p in sorted(out.rglob('*')) if p.is_file()))
print('Archived',len(raw),'raw text artifacts and',json.loads((base/'audit.json').read_text())['validated_rows'],'accepted processes to',out)

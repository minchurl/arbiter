"""Freeze text evidence losslessly; keep summaries, scripts and figures reviewable."""
import gzip,hashlib,json,shutil
from pathlib import Path
root=Path.cwd();base=root/'build/adaptive-companion';out=root/'results/adaptive-companion/20261119'
audit=json.loads((base/'audit.json').read_text());assert audit['accepted_performance_processes']==36
assert 'HOLDOUT FINISHED' in (base/'holdout.console').read_text()
out.mkdir(parents=True,exist_ok=False);raw=[]
for folder in sorted(base.iterdir()):
 if not folder.is_dir() or folder.name in ['compiler','compiler-config-rejected','scripts','reproduction']:continue
 for p in sorted(folder.iterdir()):
  if not p.is_file() or p.suffix not in ['.json','.csv','.log','.plan','.gdb','.smaps','.time','.cpp','.h']:continue
  if p.name in ['manifest.json','runs.csv','summary.json','variants.json','local.plan']:
   target=out/folder.name/p.name;target.parent.mkdir(exist_ok=True);shutil.copy2(p,target)
  else:raw.append(dict(case=folder.name,file=p.name,text=p.read_bytes().decode()))
for p in sorted(base.iterdir()):
 if not p.is_file() or p.name.startswith('interim-'):continue
 if p.suffix in ['.json','.csv','.png','.svg']:shutil.copy2(p,out/p.name)
 elif p.suffix in ['.log','.console','.cpp','.h','.asm','.ll','.txt','.py']:
  raw.append(dict(case='tools-and-checks',file=p.name,text=p.read_bytes().decode()))
shutil.copytree(base/'scripts',out/'scripts',ignore=shutil.ignore_patterns('__pycache__'))
(out/'raw-files.jsonl.gz').write_bytes(gzip.compress(''.join(json.dumps(r)+'\n' for r in raw).encode(),mtime=0))
assert [json.loads(x) for x in gzip.decompress((out/'raw-files.jsonl.gz').read_bytes()).decode().splitlines()]==raw
(out/'artifacts.sha256').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(out))+'\n' for p in sorted(out.rglob('*')) if p.is_file()))
print('Archived',len(raw),'raw artifacts and',audit['accepted_performance_processes'],'performance processes to',out)

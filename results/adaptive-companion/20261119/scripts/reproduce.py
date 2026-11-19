"""Replay rewrite/link commands only after all throughput measurements finish."""
import hashlib,json,os,subprocess
from pathlib import Path
root=Path.cwd();base=root/'build/adaptive-companion';out=base/'reproduction'
assert 'HOLDOUT FINISHED' in (base/'holdout.console').read_text()
out.mkdir(exist_ok=False)
env={**os.environ,**json.loads((base/'build.json').read_text())['environment']}
commands=json.loads((base/'variants.json').read_text())['commands'];records=[]
def mapped(argument):
 for name in ['micro','xindex','cuckoo']:
  prefix=str(base/name)+'/'
  if argument.startswith(prefix):return str(out/name/argument[len(prefix):])
 return argument
for row in commands:
 original=row['command'];command=[mapped(x) for x in original]
 if '-o' in command:Path(command[command.index('-o')+1]).parent.mkdir(parents=True,exist_ok=True)
 result=subprocess.run(command,env=env,text=True,capture_output=True)
 record=dict(command=command,returncode=result.returncode,stdout=result.stdout,stderr=result.stderr)
 assert result.returncode==0,record
 if '-o' in command:
  old=Path(original[original.index('-o')+1]);new=Path(command[command.index('-o')+1])
  record.update(original=str(old),reproduced=str(new),original_sha256=hashlib.sha256(old.read_bytes()).hexdigest(),reproduced_sha256=hashlib.sha256(new.read_bytes()).hexdigest(),identical=old.read_bytes()==new.read_bytes())
 records.append(record)
 (base/'reproduction.json').write_text(json.dumps(records,indent=2)+'\n')
assert all(r.get('identical',True) for r in records)
print('PASS: all regenerated bitcode and linked benchmark binaries are byte-identical')

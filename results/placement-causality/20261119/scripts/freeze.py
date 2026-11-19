import hashlib,json,subprocess,time
from pathlib import Path
root=Path.cwd();base=root/'build/xindex-contention-cause-20261119'
old=json.loads((root/'build/placement-diagnosis/frozen-inputs.json').read_text())
files={}
for name,digest in old['files'].items():
 actual=hashlib.sha256((root/name).read_bytes()).hexdigest();assert actual==digest,name
 files[name]=actual
for name,digest in json.loads((root/'results/libcuckoo/write-heavy-20261119/manifest.json').read_text())['frozen'].items():
 actual=hashlib.sha256((root/name).read_bytes()).hexdigest();assert actual==digest,name
 files[name]=actual
for name in ['xindex-auto','xindex-buffer','xindex-leaf','xindex-data-array','xindex-buffer-leaf']:
 path=root/'build/placement-diagnosis/placements'/name/'binary';files[str(path.relative_to(root))]=hashlib.sha256(path.read_bytes()).hexdigest()
manifest=dict(start=time.time(),base_commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),main_commit=subprocess.check_output(['git','rev-parse','main'],text=True).strip(),branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip(),files=files,traces=old['traces'],constraint='Do not modify benchmark/library code. Read-only object inspection and reversible page migration are diagnostic placement interventions. Source, input IR, runtime, selection policy, and existing binary files stay unchanged.',scope='CPU and ordinary memory node0; original selected arena node0 or node2. 64GiB/no-swap process scopes. No concurrent benchmarks. Crossover/duration diagnostics are not pooled with fixed-count full-trace throughput.',hypotheses=['Direct home/placement of the hot leaf lock','Indirect throttling by cold accesses before the lock','Timing-dependent structure or background work','Worker/CPU scheduling and cache locality'])
(base/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Frozen',len(files),'source/artifact hashes')

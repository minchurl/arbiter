import hashlib,json,re,subprocess
from pathlib import Path
root=Path.cwd();base=root/'build/adaptive-companion';v=json.loads((base/'variants.json').read_text())
workers={}
for name,path in [('plain',v['records']['micro']['plain']['path']),('adaptive',v['records']['micro']['binary'])]:
 text=subprocess.check_output(['objdump','-d','--no-show-raw-insn','--disassemble=_ZL13victim_threadi6ConfigP12VictimResult',path],text=True)
 lines=[]
 for line in text.splitlines():
  m=re.match(r'\s*[0-9a-f]+:\s*(.*)',line)
  if m:
   x=re.sub(r'-?0x[0-9a-f]+\(%rip\)','RIP',m[1]);lines.append(re.sub(r'\b[0-9a-f]+ (?=<)','ADDR ',x))
 (base/(name+'-worker.asm')).write_text(text)
 workers[name]=dict(instructions=len(lines),sha256=hashlib.sha256('\n'.join(lines).encode()).hexdigest())
(base/'worker-equivalence.json').write_text(json.dumps(dict(workers=workers,identical=workers['plain']==workers['adaptive']),indent=2)+'\n')
files={}
tracked=subprocess.check_output(['git','ls-files','--','benchmark/','compiler/','runtime/','configs/hitm-seed/'],text=True).splitlines()
tracked+=['compiler/llvm/lib/hitm_seed/AdaptiveExperiment.cpp','runtime/src/arbiter_adaptive_experiment.cpp','build/libcuckoo-rmw/micro/coherence_noise.cpp','build/libcuckoo-rmw/micro/micro-native.bc']
for name in tracked:
 p=root/name
 if p.is_file() and p.stat().st_size<20000000:files[name]=hashlib.sha256(p.read_bytes()).hexdigest()
for name,record in v['records'].items():
 p=Path(record['binary']);files[str(p.relative_to(root))]=hashlib.sha256(p.read_bytes()).hexdigest()
p=Path(v['records']['micro']['plain']['path']);files[str(p.relative_to(root))]=hashlib.sha256(p.read_bytes()).hexdigest()
policy=dict(candidates_bp=[1250,2500,5000],warmup_seconds=3,sample_seconds=2,median_samples=3,settle_seconds=2,gain_to_accept=.02,loss_to_stop_probe=.03,emergency_probe_loss=.15,drop_to_test_local=.15,consecutive_drop_samples=3,resident_companion_budget_bytes=4*1024**3)
(base/'frozen.json').write_text(json.dumps(dict(base_commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),main=subprocess.check_output(['git','rev-parse','main'],text=True).strip(),files=files,policy=policy,variants=v['records'],note='No benchmark-name, argv, table-size or application-symbol lookup in controller. Compiler automatically supplies sites and progress metadata. Earlier prototypes excluded from final comparisons.'),indent=2)+'\n')
print(workers)

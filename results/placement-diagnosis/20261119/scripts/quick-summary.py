import json
from pathlib import Path
for p in sorted(Path('build/placement-diagnosis').glob('*/manifest.json')):
 d=json.loads(p.read_text())
 if not isinstance(d,dict) or not d.get('valid'):continue
 ops=d['operations'];c=d.get('counters',{});cycles=c.get('cycles:u',1)
 print(p.parent.name,round(d['mops'],2),'Mops/s', 'window',round(d.get('disable_time',0)-d.get('enable_time',0),3))
 for name,v in c.items():
  suffix=(f' ({v/cycles*100:.1f}% cycles)' if 'stall' in name or 'walk_active' in name else '')
  print(' ',name,round(v/ops,4),'/op'+suffix)

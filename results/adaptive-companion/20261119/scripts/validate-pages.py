"""Query-only before/after diagnostics, deliberately excluded from throughput."""
import json,os,subprocess
from pathlib import Path
from host_guard import wait_quiet
base=Path('build/adaptive-companion').resolve();out=base/'page-validation';out.mkdir(exist_ok=False);waits=[];summary=[]
binary=base/'micro/adaptive'
for table,seconds in [(16,90),(256,60)]:
 wait_quiet(waits);stem=out/('h'+str(table))
 env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','MALLOC_CONF'))};env.update(ARBITER_TARGET_NODE='2',ARBITER_ARENA_REPORT='1',ARBITER_ADAPTIVE_MODE='adapt')
 commands=['set pagination off','set confirm off','set print thread-events off','set disable-randomization off','break coherence_noise.cpp:338','run']
 def query(phase):
  args=[str(base/'scripts/query-pages.py'),'PID',str(binary),str(stem),phase]
  return ['python','import gdb,runpy,sys','sys.argv='+repr(args),"sys.argv[1]=str(gdb.selected_inferior().pid)","runpy.run_path(sys.argv[0],run_name='__main__')",'end']
 commands+=query('initial')+['delete breakpoints','break coherence_noise.cpp:413','continue']+query('final')+['delete breakpoints','continue']
 stem.with_suffix('.gdb').write_text('\n'.join(commands)+'\n')
 command=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=16G','-p','MemorySwapMax=0','--','timeout','240','numactl','--cpunodebind=0','--membind=0','gdb','-nx','-q','-batch','-x',str(stem.with_suffix('.gdb')),'--args',str(binary),'--victims','32','--noise','0','--mode','none','--duration',str(seconds),'--table-size',str(table),'--ballast-mb','8192','--read-pct','50']
 stem.with_suffix('.command.json').write_text(json.dumps(dict(command=command,environment={k:v for k,v in env.items() if k.startswith('ARBITER_')}),indent=2)+'\n')
 with stem.with_suffix('.log').open('w') as f:subprocess.run(command,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
 text=stem.with_suffix('.log').read_text();assert 'status=ok' in text and 'exited normally' in text and 'Traceback' not in text
 initial=json.loads(stem.with_suffix('.initial.json').read_text());final=json.loads(stem.with_suffix('.final.json').read_text())
 assert set(initial['objects']['table']['nodes'])==set(final['objects']['table']['nodes'])=={'2'}
 assert set(initial['objects']['ballast']['nodes'])=={'0'}
 remote=final['objects']['ballast']['nodes'].get('2',0)
 assert 0<=remote*4096<=4*1024**3
 events=[json.loads(x[len('arbiter-adaptive '):]) for x in text.splitlines() if x.startswith('arbiter-adaptive ')]
 migrations=[e for e in events if e['event']=='migration'];assert migrations
 if migrations[-1]['target_pages']==0:assert remote==0
 else:assert abs(remote-migrations[-1]['target_pages'])<1024,'Unexpected page drift versus last migration (allow allocator metadata outside object)'
 summary.append(dict(table=table,initial=initial,final=final,last_migration=migrations[-1],excluded_from_throughput=True))
 print('PAGE VALIDATION',table,final['objects']['ballast']['nodes'],flush=True)
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');(out/'waits.json').write_text(json.dumps(waits,indent=2)+'\n')

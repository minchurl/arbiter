"""Export only a positively confirmed offline profile; unknown inputs keep seeds."""
import argparse,csv,gzip,hashlib,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--base',type=Path,default=Path('build/budgeted-companion'));args=p.parse_args();base=args.base
decisions=json.loads((base/'decisions.json').read_text());out=base/'accepted-plans';out.mkdir(exist_ok=True)
summary=list(csv.DictReader((base/'summary.csv').open()))
def read_command(case,filename):
    path=base/case/filename
    if path.exists():return json.loads(path.read_text())
    for line in gzip.decompress((base/'raw-files.jsonl.gz').read_bytes()).decode().splitlines():
        r=json.loads(line)
        if r['case']==case and r['file']==filename:return json.loads(r['text'])
    raise FileNotFoundError(path)
for d in decisions:
    if d['accepted'] is not True:continue
    screen=json.loads((base/d['case']/'manifest.json').read_text())
    rows=list(csv.DictReader((base/d['confirmation']/'runs.csv').open()))
    for selected,(percent,cap) in screen['policy'].items():
        checks=[r for r in summary if r['case']==d['confirmation'] and r['treatment']==selected and r['reference'] in ['original','seed','local']]
        if len(checks)!=3 or not all(int(r['pairs'])>=5 and float(r['ci95_low_pct'])>0 and r['pairs']==r['positive_pairs'] for r in checks):continue
        sites=screen['variant']['companions'];per=cap if cap==2**64-1 else cap//len(sites)
        text=''.join(f'{site} 0 {percent} {per}\n' for site in sites)
        suffix='' if selected==d['selected'] else '-'+selected
        path=out/(d['case']+suffix+'.plan');path.write_text(text)
        row=next(r for r in rows if r['strategy']==selected)
        filename=f"{row['round']}-{selected}-attempt{row['attempt']}.command.json"
        run=read_command(d['confirmation'],filename);binary=screen['variant']['binaries']['expanded']['path'];argv=run['command'][run['command'].index(binary)+1:]
        environment={k:v for k,v in run['environment'].items() if k!='ARBITER_EXPERIMENT_PLAN'}
        metadata=dict(profile=screen['args'],validated_argv=argv,environment=environment,cpu_node=0,local_node=0,selected_strategy=selected,role='training winner' if not suffix else 'independently confirmed alternative',target_percent=percent,total_companion_limit_bytes=cap,companions=sites,source_sha256=screen['variant']['source_sha256'],baseline_binary=screen['variant']['binaries']['seed'],expanded_binary=screen['variant']['binaries']['expanded'],plan_sha256=hashlib.sha256(text.encode()).hexdigest(),scope='Use launch-profile.py with this frozen profile. Exact validated arguments choose the expanded binary plus plan; unmatched arguments choose the seed-only binary. Argument matching does not detect load changes or altered input-file contents. This is an offline profile launcher, not online adaptation.',confirmation=checks)
        path.with_suffix('.json').write_text(json.dumps(metadata,indent=2)+'\n')
        print('Exported confirmed profile',path)

"""Apply a confirmed offline profile; unmatched arguments use seed-only code."""
import argparse,hashlib,json,os,sys
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--profile',type=Path,required=True);p.add_argument('--dry-run',action='store_true');p.add_argument('arguments',nargs=argparse.REMAINDER);args=p.parse_args()
argv=args.arguments[1:] if args.arguments[:1]==['--'] else args.arguments
profile=json.loads(args.profile.read_text());matched=argv==profile['validated_argv']
binary=profile['expanded_binary' if matched else 'baseline_binary'];path=Path(binary['path'])
assert hashlib.sha256(path.read_bytes()).hexdigest()==binary['sha256'],'Frozen executable changed; rebuild and revalidate the profile'
env={k:v for k,v in os.environ.items() if not k.startswith(('ARBITER_','XINDEX_','MALLOC_CONF'))};env.update(profile['environment'])
if matched:
    plan=args.profile.with_suffix('.plan').resolve()
    assert hashlib.sha256(plan.read_bytes()).hexdigest()==profile['plan_sha256'],'Placement plan changed'
    env['ARBITER_EXPERIMENT_PLAN']=str(plan)
command=['numactl','--cpunodebind='+str(profile['cpu_node']),'--membind='+str(profile['local_node']),str(path),*argv]
decision=dict(matched_profile=matched,strategy=profile['selected_strategy'] if matched else 'seed',command=command,plan=env.get('ARBITER_EXPERIMENT_PLAN'))
if args.dry_run:print(json.dumps(decision,indent=2))
else:
    print('arbiter-profile '+json.dumps(decision),file=sys.stderr,flush=True)
    os.execvpe(command[0],command,env)

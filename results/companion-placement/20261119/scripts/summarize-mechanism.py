"""Describe separate PMU diagnostics; never pool them into confirmations."""
import argparse,csv,json
from pathlib import Path

p=argparse.ArgumentParser();p.add_argument('--base',type=Path,default=Path('results/companion-placement/20261119'));args=p.parse_args();base=args.base
profiles=[]
for row in csv.DictReader((base/'profile-counters.csv').open()):
    operations=int(row['ops']);writes=int(row['writes'])
    locked=float(row['mem_inst_retired.lock_loads:u'])
    profiles.append(dict(case=row['case'],ballast_percent=int(row['ballast_percent']),
        cycles_per_op=float(row['cycles:u']),instructions_per_op=float(row['instructions:u']),
        locked_loads_per_op=locked,cas_attempts_per_write=locked*operations/writes,
        estimated_failed_cas_per_op=locked-writes/operations,
        demand_rfo_hitm_per_op=float(row['ocr.demand_rfo.l3_hit.snoop_hitm:u']),
        demand_read_hitm_per_op=float(row['ocr.demand_data_rd.l3_hit.snoop_hitm:u']) if row.get('ocr.demand_data_rd.l3_hit.snoop_hitm:u') else None))
crossover=[]
path=base/'crossover-micro/phases.csv'
if path.exists():
    rows=list(csv.DictReader(path.open()))
    for index,row in enumerate(rows):
        if not int(row['ballast_percent']):continue
        before=rows[index-1];after=rows[index+1]
        assert before['ballast_percent']==after['ballast_percent']=='0'
        reference=(float(before['mops'])+float(after['mops']))/2
        counters={}
        for key in ['cycles:u','instructions:u','mem_inst_retired.lock_loads:u','ocr.demand_rfo.l3_hit.snoop_hitm:u','ocr.demand_data_rd.l3_hit.snoop_hitm:u']:
            local=(float(before[key])+float(after[key]))/2;placed=float(row[key])
            counters[key]=dict(adjacent_control_per_op=local,treatment_per_op=placed,change_percent=100*(placed/local-1))
        crossover.append(dict(phase=int(row['phase']),ballast_percent=int(row['ballast_percent']),
            adjacent_control_mops=reference,treatment_mops=float(row['mops']),
            throughput_change_percent=100*(float(row['mops'])/reference-1),counters=counters))
result=dict(profiles=profiles,crossover_interventions=crossover,limits=[
    'One process per profile condition; crossover phases are repeated interventions within one process, not independent replicates.',
    'Locked loads approximate table CAS attempts in this frozen epoch-store worker; failed CAS is estimated by subtracting successful writes.',
    'Reader retries are not measured by the locked-load counter.',
    'Selected RFO/read HITM events are not all coherence traffic and do not measure Shared-state residence time.',
    'Crossover counter/op denominators enclose perf attachment and detachment and are approximate; whole-process profile counters use the benchmark ROI.'])
(base/'mechanism-summary.json').write_text(json.dumps(result,indent=2)+'\n')
print('Summarized',len(profiles),'profiles and',len(crossover),'crossover interventions')

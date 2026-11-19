"""Capture final experiment scope and methodological limits without source edits."""
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import time

base = Path('build/placement-diagnosis')
profiles = []
for path in base.glob('*/manifest.json'):
    data = json.loads(path.read_text())
    if isinstance(data, dict) and 'command' in data:
        profiles.append(dict(case=path.parent.name, valid=bool(data.get('valid')), kind=data.get('args',{}).get('record') or data.get('args',{}).get('group')))
rows = [dict(case=path.parent.name,**row) for path in base.glob('*/runs.csv') for row in csv.DictReader(path.open())]
result = dict(
    investigation='Compare XIndex and microbenchmark CXL behavior without benchmark source changes; search allocation/extent placement only.',
    completed_at_unix=time.time(),
    branch=subprocess.check_output(['git','branch','--show-current'],text=True).strip(),
    base_commit=json.loads((base/'frozen-inputs.json').read_text())['base_commit'],
    main_branch=subprocess.check_output(['git','rev-parse','main'],text=True).strip(),
    benchmark_source_changes=False,
    production_compiler_runtime_policy_changes=False,
    experimental_runtime_patch='interleave-runtime.patch: MPOL_INTERLEAVE on {0,target}, isolated binaries only; no production interface change.',
    new_selection_parameters=False,
    frozen_micro_version=dict(entry_bytes=64,epoch_store=True,note='Already corrected version at task start, not pristine upstream.'),
    topology=dict(cpu_node=0,ordinary_memory_node=0,cxl_target_node=2,cxl_target_evidence='/sys/bus/dax/devices/dax0.0/target_node',dax_device_path=str(Path('/sys/bus/dax/devices/dax0.0').resolve()),cxl_devices=sorted(path.name for path in Path('/sys/bus/cxl/devices').iterdir()),node1='Memory-only NUMA node; physical memory technology not asserted.'),
    default_inputs=dict(xindex=dict(workload='YCSB-A',load=100000000,operations=400000000,fg=31,bg_option=1,background_actual='coordinator plus one maintenance worker'),micro=dict(victims=32,entries=256,entry_bytes=64,read_percent=50,ballast_mib=8192,noise=0)),
    scope=dict(memory_max='64G',memory_swap_max=0,concurrent_benchmarks=False,governor='schedutil',boost='unchanged',cache_flush=False),
    protocols=dict(throughput='Fresh processes; setup and validation outside reported workload interval; no perf counters. Reverse two-mode order on even rounds, cyclic rotate three-node order. No outliers removed.',confirmation='Five 30-second micro pairs and three full XIndex rounds; separate changed-input holdouts use five 30-second pairs. Screen selection rules are retained.',profiles='Separate diagnostics, excluded from throughput means. XIndex enabled by read-only observation of existing run_control and disabled at existing completed-operation output. Micro uses existing acknowledged perf FIFOs.',live_residency='Micro prints three live page samples per object. Production arena checks all still-resident selected extent pages at exit; a freed large ballast may be purged by then. Interleaved cases additionally snapshot live mappings and NUMA page counts after the existing g_start flag, checking full initialized object-containing VMAs. XIndex selected allocations remain live at the arena check.',state='XIndex: 400M completed operations and the existing 4096-key digest. Micro: existing operation mix, write/version and epoch checks. Not a full-key XIndex state proof.',sampling='PEBS branch/locked-load estimates use period-weighted counts per operation. Instruction samples use event periods. Ordinary cycle sample IPs can skid; stall events overlap.',latency='Exploratory load-latency records include below-threshold weights and out-of-order warnings; no all-load mean or stall partition is inferred.'),
    uncore='Unavailable under current permissions. Cannot directly establish CHA IRQ occupancy, memory-controller bandwidth saturation or CXL coherence route. IRQ here is hardware Ingress Request Queue, not Linux interrupts.',
    excluded=['Two first XIndex basic-counter probes multiplexed; kept as rejected diagnostics.','Inactive RCU site 2 selected no executed allocation; excluded from accepted throughput rows. Active site 25 is a separate control.','First sparse XIndex latency probes use alias ldlat 131/period 50003; later raw ldlat 128/period 1003 are separately labeled.','CLI input changes never count as improvement of the original fixed workload.','One early decoded memory-sample analysis overlapped a diagnostic profile, whose throughput is excluded along with all other profiles.'],
    accepted_throughput_rows=len(rows),
    accepted_profiles=sum(row['valid'] for row in profiles),
    profiles=profiles,
    reproduction='Archived driver paths reflect this host. Build matching frozen inputs first using the benchmark guide and hashes. experiments.jsonl/raw-runs.jsonl.gz contain exact cases and commands. Historical stage scripts retain failures/resumes; do not blindly rerun all stages. summarize.py and plot.py regenerate derived outputs directly from archived tables.',
    primary_event_sources=['https://perfmon-events.intel.com/platforms/emeraldrapids/core-events/core/','https://perfmon-events.intel.com/platforms/emeraldrapids/offcore-events/offcore/','https://perfmon-events.intel.com/platforms/emeraldrapids/uncore-events/uncore/','https://cdrdv2-public.intel.com/817509/817509-EMR_XCC_UPG_Guide-Rev_001.pdf'],
)
(base/'manifest.json').write_text(json.dumps(result,indent=2)+'\n')
print('Manifest:',len(rows),'throughput rows;',result['accepted_profiles'],'valid profiles')

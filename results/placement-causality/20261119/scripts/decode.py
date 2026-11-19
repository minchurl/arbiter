"""Phase-aligned PMU diagnostics; run only after benchmark processes finish."""
import argparse, collections, csv, gzip, json, re, statistics, subprocess
from pathlib import Path

PERF = '/usr/lib/linux-hwe-6.8-tools-6.8.0-149/perf'
parser = argparse.ArgumentParser()
parser.add_argument('directories', nargs='+')
args = parser.parse_args()

def write_csv(path, rows):
    if not rows:
        return
    with path.open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)

for directory in map(Path, args.directories):
    manifest = json.loads((directory / 'manifest.json').read_text())
    assert manifest['valid'] and manifest['args']['profile']
    kind = manifest['args']['profile_kind']
    points = []
    for match in re.finditer(r'Throughput sample (elapsed_sec=.*)', (directory / 'output.log').read_text()):
        points.append({k: float(v) for k, v in re.findall(r'(\w+)=([^\s]+)', match[1])})
    phases = json.loads((directory / 'phases.json').read_text())
    for phase in phases:
        chosen = [p for p in points if p['elapsed_sec'] - p['interval_sec'] >= phase['stable_from_elapsed'] and p['elapsed_sec'] <= phase['end_elapsed']]
        assert len(chosen) >= 5
        phase['operations'] = sum(p['interval_ops'] for p in chosen)
        phase['sample_windows'] = [(p['elapsed_sec'] - p['interval_sec'], p['elapsed_sec']) for p in chosen]
    objects = json.loads((directory / 'objects.json').read_text())
    pages = json.loads(gzip.decompress((directory / 'page-sets.json.gz').read_bytes()))['groups']
    cold = set(pages.get('coldbuffer', []))
    hot_buffer = set(pages.get('bulkbuffer', [])) - cold
    leaves = [(r['leaf'], r['leaf'] + 104) for r in objects if r['leaf']]
    records = [(r['record'], r['record'] + 32) for r in objects]
    hottest = next(r for r in objects if r['leaf'])['leaf']
    fields = 'tid,time,period,event,ip,sym,symoff,addr'
    if kind == 'memory':
        fields += ',weight,ins_lat,data_src'
    command = [PERF, 'script', '--ns', '--show-lost-events', '-i', str(directory / 'perf.data'), '-F', fields]
    (directory / 'decode-command.json').write_text(json.dumps(command) + '\n')
    report = subprocess.check_output([PERF, 'report', '-i', str(directory / 'perf.data'), '--stdio', '--no-children', '--percent-limit', '1', '--sort', 'symbol'], text=True)
    (directory / 'perf-report.txt').write_text(report)
    assert 'Total Lost Samples: 0' in report
    evlist = subprocess.check_output([PERF, 'evlist', '-v', '-i', str(directory / 'perf.data')], text=True)
    (directory / 'evlist.txt').write_text(evlist)
    metrics = collections.Counter()
    samples = collections.Counter()
    positions = collections.Counter()
    latencies = collections.defaultdict(list)
    leaf_accesses = collections.defaultdict(list)
    tids = collections.defaultdict(set)
    all_tids = set()
    total_samples = 0
    unmatched = []
    header = re.compile(r'\s*(\d+)\s+(\d+\.\d+):\s+(\d+)\s+(.+?):\s+(.*)')
    with (directory / 'decode.stderr').open('w') as err, gzip.open(directory / 'decoded.txt.gz', 'wt', compresslevel=6) as raw:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=err, text=True)
        for line in process.stdout:
            raw.write(line)
            if not line.strip():
                continue
            match = header.fullmatch(line.rstrip('\n'))
            assert match, line
            tid, timestamp, period, event, rest = match.groups()
            tid, timestamp, period = int(tid), float(timestamp), int(period)
            if kind == 'memory':
                match = re.fullmatch(r'([0-9a-f]+)\s+([0-9a-f]+)\s+(\|.*?)\s+(\d+)\s+(\d+)\s+([0-9a-f]+)\s+(.*)', rest)
                assert match, line
                address, source_raw, source, weight, instruction_latency, ip, symbol = match.groups()
                if 'mem-loads-aux' in event:
                    continue
                weight = int(weight)
                instruction_latency = int(instruction_latency)
                assert instruction_latency >= 128, line
                assert period == 10007
            else:
                match = re.fullmatch(r'([0-9a-f]+)\s+([0-9a-f]+)\s+(.*)', rest)
                assert match, line
                address, ip, symbol = match.groups()
                assert period == (30000003 if 'event=0x3c' in event else 100003)
            total_samples += 1
            all_tids.add(tid)
            elapsed = timestamp - manifest['phase_clock_monotonic']
            phase = next((p for p in phases if any(start <= elapsed < end for start, end in p['sample_windows'])), None)
            if phase is None:
                continue
            index = phase['phase']
            tids[index].add(tid)
            event_kind = 'memory' if kind == 'memory' else 'branch' if 'cond_taken' in event else 'locks' if 'lock_loads' in event else 'cycles'
            address = int(address, 16)
            offset = re.search(r'\+0x([0-9a-f]+)$', symbol)
            offset = int(offset[1], 16) if offset else -1
            category = 'other'
            if symbol.startswith('xindex::HGroup<') and '>::put(' in symbol:
                if event_kind == 'branch' and offset == 0x269:
                    category = 'failed_leaf_cas'
                elif event_kind == 'locks' and offset == 0x262:
                    category = 'leaf_cas_attempt'
                elif event_kind == 'cycles' and 0x260 <= offset < 0x26b:
                    category = 'leaf_tas_loop'
            elif symbol.startswith('xindex::AltBtreeBuffer<') and '>::get(' in symbol and event_kind == 'branch' and offset == 0x141:
                category = 'reader_locked_leaf_retry'
            elif symbol.startswith('xindex::AtomicVal<') and '>::update(' in symbol and event_kind == 'locks':
                category = 'value_cas'
            metrics[index, event_kind, category] += period
            samples[index, event_kind, category] += 1
            positions[index, event_kind, symbol] += 1
            if event_kind == 'locks' and category == 'leaf_cas_attempt':
                metrics[index, event_kind, 'hottest_leaf_cas_attempt'] += period * (address == hottest + 1)
                samples[index, event_kind, 'hottest_leaf_cas_attempt'] += int(address == hottest + 1)
            if kind == 'memory':
                page = address // 4096 * 4096
                obj = 'cold_buffer_page' if page in cold else 'hot_buffer_page' if page in hot_buffer else 'hot_leaf_object' if any(lo <= address < hi for lo, hi in leaves) else 'hot_record_object' if any(lo <= address < hi for lo, hi in records) else 'other'
                latencies[index, obj, 'cache_access'].append(weight)
                latencies[index, 'ALL', 'cache_access'].append(weight)
                latencies[index, obj, 'instruction'].append(instruction_latency)
                latencies[index, 'ALL', 'instruction'].append(instruction_latency)
                if hottest <= address < hottest + 104:
                    relative = address - hottest
                    field = 'lock' if relative == 1 else 'version' if 8 <= relative < 16 else 'keys' if 16 <= relative < 40 else 'values_status' if 48 <= relative < 96 else 'header_next_other'
                    role = 'writer_acquire' if symbol.startswith('xindex::HGroup<') and '>::put(' in symbol and offset == 0x262 else 'writer_critical' if '>::insert_leaf(' in symbol else 'writer_value' if symbol.startswith('xindex::AtomicVal<') and '>::update(' in symbol else 'reader' if '>::get(' in symbol else 'lookup_or_other'
                    hitm = 'SNP HitM' in source
                    leaf_accesses[index, role, field, hitm].append((weight, instruction_latency))

        assert process.wait() == 0
    rows = []
    for (index, event, category), value in sorted(metrics.items()):
        rows.append(dict(phase=index, name=phases[index]['name'], event=event, category=category, samples=samples[index, event, category], estimated_events=value, operations=int(phases[index]['operations']), events_per_operation=value / phases[index]['operations']))
    write_csv(directory / 'phase-events.csv', rows)
    write_csv(directory / 'phase-positions.csv', [dict(phase=index, event=event, symbol_offset=symbol, samples=count) for (index, event, symbol), count in sorted(positions.items())])
    rows = []
    for (index, obj, metric), weights in sorted(latencies.items()):
        weights.sort()
        rows.append(dict(phase=index, name=phases[index]['name'], object=obj, metric=metric, samples=len(weights), estimated_samples_per_operation=10007 * len(weights) / phases[index]['operations'], conditional_mean_cycles=statistics.mean(weights), conditional_median_cycles=statistics.median(weights), conditional_p90_cycles=weights[int(.9 * (len(weights) - 1))], conditional_p99_cycles=weights[int(.99 * (len(weights) - 1))]))
    write_csv(directory / 'phase-latencies.csv', rows)
    details = []
    for (index, role, field, hitm), values in sorted(leaf_accesses.items()):
        details.append(dict(phase=index, name=phases[index]['name'], role=role, field=field, hitm=hitm, samples=len(values), conditional_mean_cache_cycles=statistics.mean(v[0] for v in values), conditional_mean_instruction_cycles=statistics.mean(v[1] for v in values)))
    write_csv(directory / 'hottest-leaf-accesses.csv', details)

    (directory / 'decode-checks.json').write_text(json.dumps(dict(valid=True, lost_samples=0, total_samples=total_samples, all_tids=sorted(all_tids), phase_tids={index: sorted(ids) for index, ids in tids.items()}, phases=phases, timestamp_note='perf CLOCK_MONOTONIC and existing flushed benchmark timestamps; exact selected one-second sample intervals used for event and operation windows. Log timestamps rounded at source.', latency_note='PEBS eligibility uses instruction latency >=128. On this platform weight is cache-access latency and ins_lat is dispatch-to-completion instruction latency. Cache latency can be below 128; neither distribution is an all-load average.'), indent=2) + '\n')
    print(directory.name, total_samples, 'samples; TIDs per phase', {index: len(ids) for index, ids in tids.items()}, flush=True)

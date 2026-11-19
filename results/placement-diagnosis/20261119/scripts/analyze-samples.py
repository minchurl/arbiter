"""Decode completed perf recordings; retain samples, not only derived means."""
import collections
import csv
import gzip
import json
import re
import statistics
import subprocess
from pathlib import Path

BASE = Path('build/placement-diagnosis')
PERF = '/usr/lib/linux-hwe-6.8-tools-6.8.0-149/perf'


def write_csv(path, rows):
    if not rows:
        return
    opener = gzip.open if path.suffix == '.gz' else open
    with opener(path, 'wt') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)


def decode(directory, manifest):
    kind = manifest['args']['record']
    fields = 'period,event,ip,sym,symoff'
    if kind == 'memory':
        fields += ',addr,weight,data_src'
    elif kind in ('locks', 'hitm'):
        fields += ',addr'
    command = [PERF, 'script', '--show-lost-events', '-i', str(directory / 'perf.data'), '-F', fields]
    result = subprocess.run(command, text=True, capture_output=True, check=True)
    (directory / 'decode.stderr').write_text(result.stderr)
    with gzip.open(directory / 'decoded.txt.gz', 'wt') as stream:
        stream.write(result.stdout)
    report = subprocess.check_output([PERF, 'report', '-i', str(directory / 'perf.data'), '--stdio', '--no-children', '--percent-limit', '0', '--sort', 'symbol'], text=True)
    (directory / 'symbols.txt').write_text(report)
    assert 'Total Lost Samples: 0' in report, directory
    rows = []
    objects = {}
    if manifest['args']['workload'] == 'micro':
        output = (directory / 'output.log').read_text()
        for name, address, length in re.findall(r'(table|ballast|epochs)=(0x[0-9a-f]+) \w+_bytes=(\d+)', output):
            objects[name] = (int(address, 16), int(length))
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        if kind == 'memory':
            match = re.fullmatch(r'\s*(\d+)\s+(.+?):\s+([0-9a-f]+)\s+([0-9a-f]+)\s+(\|.*?)\s+(\d+)\s+([0-9a-f]+)\s+(.*)', line)
            assert match, (directory, line)
            period, event, address, source_raw, source, weight, ip, symbol = match.groups()
            if 'mem-loads-aux' in event:
                continue
            row = dict(period=int(period), event=event, ip=ip, symbol_offset=symbol, address=address, latency_cycles=int(weight), data_source=source.strip(), data_source_raw=source_raw)
        elif kind in ('locks', 'hitm'):
            match = re.fullmatch(r'\s*(\d+)\s+(.+?):\s+([0-9a-f]+)\s+([0-9a-f]+)\s+(.*)', line)
            assert match, (directory, line)
            period, event, address, ip, symbol = match.groups()
            row = dict(period=int(period), event=event, ip=ip, symbol_offset=symbol, address=address)
        else:
            match = re.fullmatch(r'\s*(\d+)\s+(.+?):\s+([0-9a-f]+)\s+(.*)', line)
            assert match, (directory, line)
            period, event, ip, symbol = match.groups()
            row = dict(period=int(period), event=event, ip=ip, symbol_offset=symbol)
        row['symbol'] = re.sub(r'\+0x[0-9a-f]+$', '', symbol)
        if kind in ('memory', 'locks', 'hitm'):
            number = int(row['address'], 16)
            row['object'] = next((name for name, (start, length) in objects.items() if start <= number < start + length), 'other')
        rows.append(row)
    assert rows, directory
    write_csv(directory / 'samples.csv.gz', rows)
    totals = collections.Counter()
    counts = collections.Counter()
    for row in rows:
        totals[row['symbol']] += row['period']
        counts[row['symbol']] += 1
    total = sum(totals.values())
    positions = collections.Counter()
    position_counts = collections.Counter()
    for row in rows:
        positions[row['symbol_offset']] += row['period']
        position_counts[row['symbol_offset']] += 1
    write_csv(directory / 'ip-summary.csv', [dict(symbol_offset=name, samples=position_counts[name], period=period, share=period / total, period_per_operation=period / manifest['operations']) for name, period in positions.most_common()])
    write_csv(directory / 'symbol-summary.csv', [dict(symbol=name, samples=counts[name], period=period, share=period / total, period_per_operation=period / manifest['operations']) for name, period in totals.most_common()])
    if kind in ('memory', 'locks', 'hitm'):
        groups = collections.defaultdict(list)
        for row in rows:
            groups[row['object']].append(row)
        summary = []
        for name, selected in groups.items():
            item = dict(object=name, samples=len(selected), fraction=len(selected) / len(rows))
            if kind == 'memory':
                weights = sorted(row['latency_cycles'] for row in selected)
                item.update(conditional_mean_cycles=statistics.mean(weights), conditional_median_cycles=statistics.median(weights), conditional_p90_cycles=weights[int(.9 * (len(weights) - 1))], conditional_p99_cycles=weights[int(.99 * (len(weights) - 1))])
            summary.append(item)
        write_csv(directory / 'object-summary.csv', summary)
    print(directory.name, len(rows), 'samples', flush=True)


for directory in sorted(BASE.glob('*samples*')):
    if not directory.is_dir():
        continue
    manifest = json.loads((directory / 'manifest.json').read_text())
    if (directory / 'samples.csv.gz').exists():
        if not (directory / 'ip-summary.csv').exists():
            positions = collections.Counter()
            counts = collections.Counter()
            for row in csv.DictReader(gzip.open(directory / 'samples.csv.gz', 'rt')):
                positions[row['symbol_offset']] += int(row['period'])
                counts[row['symbol_offset']] += 1
            total = sum(positions.values())
            write_csv(directory / 'ip-summary.csv', [dict(symbol_offset=name, samples=counts[name], period=period, share=period/total, period_per_operation=period/manifest['operations']) for name, period in positions.most_common()])
        continue
    if manifest.get('valid'):
        decode(directory, manifest)

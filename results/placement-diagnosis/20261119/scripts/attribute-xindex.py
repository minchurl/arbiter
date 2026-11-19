"""Join sampled addresses to uniform-node VMAs; never infer a mixed VMA's page."""
import bisect
import collections
import csv
import gzip
import json
import re
from pathlib import Path

base = Path('build/placement-diagnosis')
output = []
hot_leaves = []
for directory in sorted(base.glob('xindex*samples*')):
    samples = directory / 'samples.csv.gz'
    if not samples.exists():
        continue
    manifest = json.loads((directory / 'manifest.json').read_text())
    if manifest['args']['record'] not in ('locks', 'hitm', 'memory'):
        continue
    maps = (directory / 'start.maps').read_text().splitlines()
    numa = (directory / 'start.numa_maps').read_text().splitlines()
    starts, ranges = [], []
    for line in maps:
        left, right = line.split()[0].split('-')
        starts.append(int(left, 16))
        ranges.append((int(left, 16), int(right, 16)))
    nodes = {}
    for line in numa:
        found = re.findall(r'\bN(\d+)=(\d+)', line)
        used = [int(node) for node, count in found if int(count)]
        nodes[int(line.split()[0], 16)] = str(used[0]) if len(used) == 1 else 'mixed-or-unresident'
    groups = collections.Counter()
    addresses = collections.defaultdict(collections.Counter)
    leaf_locks = collections.Counter()
    value_locks = collections.Counter()
    for row in csv.DictReader(gzip.open(samples, 'rt')):
        address = int(row['address'], 16)
        index = bisect.bisect_right(starts, address) - 1
        node = 'unmapped'
        if index >= 0 and address < ranges[index][1]:
            node = nodes.get(starts[index], 'unknown')
        key = (row['symbol_offset'], node)
        groups[key] += int(row['period'])
        addresses[key][address // 64] += 1
        if manifest['args']['record'] == 'locks':
            if '::HGroup<' in row['symbol_offset'] and row['symbol_offset'].endswith(('+0x272', '+0x262')):
                leaf_locks[address] += 1
            if '::AtomicVal<' in row['symbol_offset'] and '::update(' in row['symbol_offset']:
                value_locks[address] += 1
    for (symbol, node), period in groups.most_common():
        histogram = addresses[(symbol, node)]
        samples = sum(histogram.values())
        output.append(dict(case=directory.name, record=manifest['args']['record'], target_node=manifest['args']['node'], symbol_offset=symbol, sampled_address_node=node, samples=samples, unique_lines=len(histogram), hottest_line_sample_fraction=histogram.most_common(1)[0][1] / samples, period_per_operation=period / manifest['operations']))
    if leaf_locks:
        lock_address, attempts = leaf_locks.most_common(1)[0]
        leaf_address = lock_address - 1
        # Frozen Key/u64 specialization: Node=48 B, three AtomicVal slots,
        # then next pointer. Compare the same leaf, not the same cache line.
        updates = sum(count for address, count in value_locks.items() if leaf_address + 48 <= address < leaf_address + 96)
        hot_leaves.append(dict(case=directory.name, leaf_address=hex(leaf_address), leaf_cas_samples=attempts, value_cas_samples_same_leaf=updates, sampled_attempts_per_value_update=attempts/updates if updates else ''))
with (base / 'xindex-address-attribution.csv').open('w') as stream:
    writer = csv.DictWriter(stream, fieldnames=list(output[0]), lineterminator='\n')
    writer.writeheader()
    writer.writerows(output)
with (base / 'hot-leaf-samples.csv').open('w') as stream:
    writer = csv.DictWriter(stream, fieldnames=list(hot_leaves[0]), lineterminator='\n')
    writer.writeheader()
    writer.writerows(hot_leaves)

"""Read bounded windows of the frozen trace, outside timed benchmark runs."""
import collections
import json
from pathlib import Path

path = Path('benchmark/xindex/YCSB/xindex_dat/xindex_transaction_ycsb_a.dat')
size = path.stat().st_size
counts = collections.Counter()
operations = collections.Counter()
windows = []
with path.open('rb') as stream:
    for fraction in [0, .25, .5, .75, .95]:
        offset = int(size * fraction)
        stream.seek(offset)
        if offset:
            stream.readline()
        begin = stream.tell()
        local = collections.Counter()
        number = 0
        for line in stream:
            if not line.startswith((b'READ ', b'UPDATE ')):
                continue
            op, table, key, rest = line.split(maxsplit=3)
            assert table == b'usertable' and key.startswith(b'user')
            key = int(key[4:])
            local[key] += 1
            operations[op.decode()] += 1
            number += 1
            if number == 200000:
                break
        counts.update(local)
        windows.append(dict(byte_offset=begin, records=sum(local.values()), top_keys=local.most_common(10)))
result = dict(path=str(path), protocol='Five deterministic byte-offset windows of 200,000 records; not an exact full-trace distribution.', records=sum(counts.values()), distinct_keys=len(counts), operations=dict(operations), top_keys=counts.most_common(20), windows=windows)
Path('build/placement-diagnosis/trace-sample.json').write_text(json.dumps(result, indent=2) + '\n')

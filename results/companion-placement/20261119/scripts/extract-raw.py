"""Restore a named case's raw logs, page checks and exact command records."""
import argparse,gzip,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('case');p.add_argument('output',type=Path);p.add_argument('--archive',type=Path,default=Path('results/companion-placement/20261119/raw-files.jsonl.gz'));args=p.parse_args()
records=[json.loads(line) for line in gzip.decompress(args.archive.read_bytes()).decode().splitlines()]
records=[r for r in records if r['case']==args.case]
assert records,'Unknown case'
args.output.mkdir(parents=True,exist_ok=False)
for row in records:
    assert Path(row['file']).name==row['file']
    (args.output/row['file']).write_bytes(row['text'].encode())
print('Restored',len(records),'files to',args.output)

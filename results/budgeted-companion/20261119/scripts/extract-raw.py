"""Restore one case, including rejected attempts, without altering log bytes."""
import argparse,gzip,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('case');p.add_argument('output',type=Path);p.add_argument('--archive',type=Path,default=Path('results/budgeted-companion/20261119/raw-files.jsonl.gz'));args=p.parse_args()
rows=[json.loads(line) for line in gzip.decompress(args.archive.read_bytes()).decode().splitlines()];rows=[r for r in rows if r['case']==args.case];assert rows,'Unknown case'
args.output.mkdir(parents=True,exist_ok=False)
for r in rows:
    assert Path(r['file']).name==r['file'];(args.output/r['file']).write_bytes(r['text'].encode())
print('Restored',len(rows),'files')

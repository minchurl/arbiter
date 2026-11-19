"""Restore one evidence case; never replace an existing output directory."""
import argparse,gzip,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('case');p.add_argument('output',type=Path);p.add_argument('--archive',type=Path,default=Path('results/adaptive-companion/20261119/raw-files.jsonl.gz'));args=p.parse_args()
rows=[json.loads(x) for x in gzip.decompress(args.archive.read_bytes()).decode().splitlines()];rows=[x for x in rows if x['case']==args.case];assert rows,'Unknown case'
args.output.mkdir(parents=True,exist_ok=False)
for row in rows:
 assert Path(row['file']).name==row['file'];(args.output/row['file']).write_bytes(row['text'].encode())
print('Restored',len(rows),'files')

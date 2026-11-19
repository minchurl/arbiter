"""Observe existing flushed throughput lines; never write benchmark memory."""
import json,re,sys,time
from pathlib import Path
out=Path(sys.argv[1]);log=out/'output.log';samples=[]
initial=re.findall(r'Throughput sample elapsed_sec=([\d.]+)',log.read_text());last=initial[-1] if initial else None
start=time.monotonic()
while len(samples)<5 and time.monotonic()-start<12:
 values=re.findall(r'Throughput sample elapsed_sec=([\d.]+)',log.read_text())
 observed=time.monotonic()
 if values and values[-1]!=last:
  last=values[-1];elapsed=float(last);samples.append(dict(elapsed_sec=elapsed,observed_monotonic=observed,start_estimate=observed-elapsed))
 time.sleep(.002)
assert len(samples)==5,samples
estimates=[s['start_estimate'] for s in samples]
result=dict(samples=samples,start_estimate=min(estimates),spread_seconds=max(estimates)-min(estimates),poll_seconds=.002,method='Minimum observation-minus-elapsed over five distinct, flushed one-second samples; observation follows benchmark timestamp. Transition guard exceeds observed spread.')
assert result['spread_seconds']<.05,result
(out/'clock-alignment.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))

"""Fresh uninstrumented confirmations, with alternating order within pairs."""
import subprocess, sys
from pathlib import Path
base=Path('build/placement-diagnosis')
subprocess.run([sys.executable,str(base/'cross-hotset.py')],check=True)
for workload, rounds in [('micro',5),('xindex',3)]:
 subprocess.run([sys.executable,str(base/'placement-run.py'),workload,'confirm-'+workload+'-baseline','--rounds',str(rounds),'--seconds','30',*(['--nodes','0','2','1'] if workload=='xindex' else [])],check=True)

subprocess.run([sys.executable,str(base/'confirm-cross-hotset.py')],check=True)

subprocess.run([sys.executable,str(base/'confirm-screen-winners.py')],check=True)

subprocess.run([sys.executable,str(base/'interleave-screen.py')],check=True)

"""Freeze inputs and build allocation-only libcuckoo ablations from existing IR."""
import hashlib, json, os, re, subprocess
from pathlib import Path

root = Path.cwd()
base = root / 'build/companion-placement'
old = json.loads((root / 'results/placement-causality/20261119/manifest.json').read_text())
for name, digest in old['files'].items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest, name
manifest = dict(base_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                files=old['files'], traces=old['traces'],
                constraint='Frozen benchmark source and IR. Existing allocation-site override only. '
                'Micro pages move while stopped before worker creation and before the timer. '
                'No production runtime, compiler or selection parameter changes.')
(base / 'frozen.json').write_text(json.dumps(manifest, indent=2)+'\n')
env = dict(os.environ,
    LD_LIBRARY_PATH=str(root/'.tools/libtinfo5-root/lib/x86_64-linux-gnu')+':'+str(root/'.tools/libllvm18-root/usr/lib/x86_64-linux-gnu'),
    LIBRARY_PATH=str(root/'.tools/libstdcxx')+':'+str(root/'.tools/libllvm18-root/usr/lib/x86_64-linux-gnu'))
source = root/'build/libcuckoo-rmw/bench-final/contention.bc'
options = root/'build/libcuckoo-rmw/bench-final/contention.hitm-seed-effective.opt-args'
records = []
for name, ids in [('lock', '26'), ('bucket', '13'), ('both', '13,26')]:
    out = base/name
    out.mkdir(exist_ok=False)
    args = [a for a in options.read_text().splitlines() if not a.startswith(('-arbiter-hitm-seed-report-path=', '-arbiter-hitm-seed-site-ids='))]
    args += ['-arbiter-hitm-seed-site-ids='+ids, '-arbiter-hitm-seed-report-path='+str(out/'selection.csv')]
    commands = [
      [str(root/'.tools/llvm18-apt-root/usr/bin/opt-18'), '-load-pass-plugin', str(root/'build/libcuckoo-rmw/compiler/lib/ArbiterLLVMPlugin.so'), '-passes=arbiter-experiment-hitm-seed-rewrite', *args, str(source), '-o', str(out/'placed.bc')],
      [str(root/'.tools/llvm-18.1.8/bin/clang++'), '-std=c++17', '-O2', '-gline-tables-only', '-march=native', '-pthread', str(out/'placed.bc'), str(root/'build/libcuckoo-rmw/compiler/runtime/libarbiter_runtime.a'), '-Wl,--no-as-needed', '-ljemalloc', '-lnuma', '-o', str(out/'binary')]]
    for command in commands:
        subprocess.run(command, env=env, check=True)
    records.append(dict(name=name, ids=ids, commands=commands,
        source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
        binary_sha256=hashlib.sha256((out/'binary').read_bytes()).hexdigest()))
    print('Built', name, flush=True)
(base/'build.json').write_text(json.dumps(records, indent=2)+'\n')

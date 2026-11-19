"""Isolated Arbiter extent-placement experiment; benchmark IR stays frozen.

This runtime copy interprets target N as interleave(0,N), including the
degenerate Local control N=0. It is NOT the production runtime interface.
No new selection parameter or benchmark transformation is introduced.
"""
import csv
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

root = Path.cwd()
base = root / 'build/placement-diagnosis'
out = base / 'interleave-runtime'
out.mkdir(exist_ok=False)
source = root / 'runtime/src/arbiter_jemalloc_arena.cpp'
before = source.read_text()
after = before.replace('mbind(ptr, size, MPOL_BIND,', 'mbind(ptr, size, MPOL_INTERLEAVE,')
after = after.replace('  numa_bitmask_setbit(arena->mask, node);', '  numa_bitmask_setbit(arena->mask, node);\n  numa_bitmask_setbit(arena->mask, 0);\n  std::fprintf(stderr, "arbiter-experiment-interleave nodes=0,%ld\\n", node);')
assert after != before
(out / source.name).write_text(after)
(out / 'runtime.patch').write_text(''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile='a/runtime/src/arbiter_jemalloc_arena.cpp', tofile='b/runtime/src/arbiter_jemalloc_arena.cpp')))
build = root / 'build/libcuckoo-rmw/compiler'
original_object = 'runtime/CMakeFiles/arbiter_runtime.dir/src/arbiter_jemalloc_arena.cpp.o'
command_text = subprocess.check_output(['ninja', '-C', str(build), '-t', 'commands', original_object], text=True).strip()
assert len(command_text.splitlines()) == 1
command_text = command_text.replace(original_object, str(out / 'arena.o')).replace(str(source), str(out / source.name))
compile_command = shlex.split(command_text) + ['-I' + str(source.parent)]
env = dict(os.environ, LD_LIBRARY_PATH=str(root / '.tools/libtinfo5-root/lib/x86_64-linux-gnu') + ':' + str(root / '.tools/libllvm18-root/usr/lib/x86_64-linux-gnu'), LIBRARY_PATH=str(root / '.tools/libstdcxx') + ':' + str(root / '.tools/libllvm18-root/usr/lib/x86_64-linux-gnu'))
env['CPLUS_INCLUDE_PATH']='/usr/include/c++/11/backward:/usr/include/x86_64-linux-gnu/c++/11:/usr/include/c++/11'
commands = [compile_command]
subprocess.run(compile_command, env=env, cwd=build, check=True)
runtime = out / 'libarbiter_runtime.a'
archive_command = [str(root / '.tools/llvm-18.1.8/bin/llvm-ar'), 'rcs', str(runtime), str(build / 'runtime/CMakeFiles/arbiter_runtime.dir/src/arbiter_runtime_site.cpp.o'), str(out / 'arena.o')]
commands.append(archive_command)
subprocess.run(archive_command, env=env, check=True)
binaries = {}
def normalized_worker(binary):
    decoded = subprocess.run(['objdump', '-d', '--no-show-raw-insn', '--disassemble=_ZL13victim_threadi6ConfigP12VictimResult', str(binary)], text=True, capture_output=True, check=True)
    (out / (Path(binary).name + '.objdump.stderr')).write_text(decoded.stderr)
    disassembly = decoded.stdout
    instructions = []
    for line in disassembly.splitlines():
        match = re.match(r'\s*[0-9a-f]+:\s*(.*)', line)
        if not match:
            continue
        instruction = re.sub(r'-?0x[0-9a-f]+\(%rip\)', 'RIP', match[1])
        instruction = re.sub(r'\b[0-9a-f]+ (?=<)', 'ADDR ', instruction)
        instructions.append(instruction)
    assert len(instructions) == 149, len(instructions)
    return '\n'.join(instructions) + '\n'
original_worker = normalized_worker(root / 'build/libcuckoo-rmw/micro/micro-placed')
for name in ['ballast', 'both', 'table']:
    binary = out / ('micro-' + name)
    bc = base / 'placements' / ('micro-' + name) / 'placed.bc'
    command = [str(root / '.tools/llvm-18.1.8/bin/clang++'), '-std=c++17', '-O2', '-gline-tables-only', '-march=native', '-pthread', str(bc), str(runtime), '-Wl,--no-as-needed', '-ljemalloc', '-lnuma', '-o', str(binary)]
    commands.append(command)
    subprocess.run(command, env=env, check=True)
    worker = normalized_worker(binary)
    assert worker == original_worker, 'Benchmark worker instructions changed'
    binaries[name] = dict(binary=str(binary), binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), bitcode=str(bc), bitcode_sha256=hashlib.sha256(bc.read_bytes()).hexdigest(), normalized_worker_sha256=hashlib.sha256(worker.encode()).hexdigest(), worker_instructions_identical=True)
manifest = dict(experimental_runtime_only=True, mapping='ARBITER_TARGET_NODE=N means MPOL_INTERLEAVE on {0,N} in this isolated binary only; N=0 is the single-node control.', source_sha256=hashlib.sha256(before.encode()).hexdigest(), modified_source_sha256=hashlib.sha256(after.encode()).hexdigest(), runtime_sha256=hashlib.sha256(runtime.read_bytes()).hexdigest(), commands=commands, build_environment={key:env[key] for key in ['CPLUS_INCLUDE_PATH','LD_LIBRARY_PATH','LIBRARY_PATH']}, binaries=binaries)
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

screen = []
for name in ['ballast', 'both', 'table']:
    case = 'screen-micro-interleave-' + name
    objects = 'table,ballast' if name == 'both' else name
    print('START', case, flush=True)
    command = [sys.executable, str(base / 'placement-run.py'), 'micro', case, '--binary', binaries[name]['binary'], '--objects', objects, '--interleaved', '--nodes', '0', '2', '1', '--rounds', '1', '--seconds', '20']
    subprocess.run(command, check=True)
    values = {int(row['node']): float(row['mops']) for row in csv.DictReader((base / case / 'runs.csv').open())}
    for node in [1, 2]:
        screen.append(dict(selection=name, node=node, local=values[0], interleaved=values[node], ratio=values[node] / values[0]))
eligible = [row for row in screen if row['ratio'] >= 1.03]
choice = max(eligible, key=lambda row: row['ratio']) if eligible else None
(base / 'interleave-screen.json').write_text(json.dumps(dict(screen=screen, screen_threshold=1.03, confirmation_choice=choice, confirmation_rounds=5, confirmation_seconds=30), indent=2) + '\n')
if choice:
    name = choice['selection']
    objects = 'table,ballast' if name == 'both' else name
    case = f"confirm-micro-interleave-{name}-node{choice['node']}"
    print('START', case, flush=True)
    subprocess.run([sys.executable, str(base / 'placement-run.py'), 'micro', case, '--binary', binaries[name]['binary'], '--objects', objects, '--interleaved', '--nodes', '0', str(choice['node']), '--rounds', '5', '--seconds', '30'], check=True)

#!/usr/bin/env python3
"""Run LLVM selection fixtures and a real libstdc++ thread/member-pointer case."""
import argparse
import csv
import io
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=root/'build-llvm18')
    parser.add_argument('--opt', default=os.environ.get('OPT', 'opt-18'))
    parser.add_argument('--clangxx', default=os.environ.get('CLANGXX', 'clang++-18'))
    parser.add_argument('--filecheck', default=shutil.which('FileCheck-18') or shutil.which('FileCheck-14') or 'FileCheck')
    args = parser.parse_args()
    plugin = args.build_dir.resolve()/'lib/ArbiterLLVMPlugin.so'
    env = dict(os.environ)
    env['PATH'] = '/usr/lib/llvm-18/bin:/usr/lib/llvm-14/bin:'+env.get('PATH','')
    count=0
    for fixture in sorted((root/'tests/llvm').glob('*.ll')):
        for line in fixture.read_text().splitlines():
            if not line.startswith('; RUN: '):
                continue
            command=line.removeprefix('; RUN: ')
            command=command.replace('%shlibdir/ArbiterLLVMPlugin%shlibext',shlex.quote(str(plugin)))
            command=command.replace('%s',shlex.quote(str(fixture)))
            command=command.replace('opt ',shlex.quote(args.opt)+' ').replace('FileCheck ',shlex.quote(args.filecheck)+' ')
            subprocess.run(['bash','-o','pipefail','-c',command],env=env,check=True,capture_output=True,text=True)
            count+=1
    report = subprocess.run([args.opt, '-load-pass-plugin', str(plugin),
                             '-passes=arbiter-report-hitm-seed-sites',
                             '-arbiter-hitm-weight-published-rmw=3', '-disable-output',
                             str(root/'tests/llvm/object-access.ll')],
                            env=env,check=True,capture_output=True,text=True)
    proven = {int(r['site_id']) for r in csv.DictReader(io.StringIO(report.stdout))
              if 'object-pointee-atomic-rmw' in r['reasons']}
    assert proven == {2, 4, 6}, proven
    with tempfile.TemporaryDirectory(prefix='arbiter-object-access-') as temporary:
        bc=Path(temporary)/'thread.bc'
        subprocess.run([args.clangxx,'-std=c++17','-O2','-gline-tables-only','-pthread','-emit-llvm','-c',
                        str(root/'tests/llvm/object-access-thread.cpp'),'-o',str(bc)],env=env,check=True)
        base=[args.opt,'-load-pass-plugin',str(plugin),'-passes=arbiter-report-hitm-seed-sites','-disable-output',str(bc)]
        def report(weight):
            run=subprocess.run([*base,f'-arbiter-hitm-weight-published-rmw={weight}'],env=env,check=True,capture_output=True,text=True)
            assert not run.stderr,run.stderr
            return list(csv.DictReader(io.StringIO(run.stdout)))
        rows=report(3)
        workers=[r for r in rows if r['function']=='worker' and r['kind']=='cxx-new-array']
        assert len(workers)==1 and 'thread-worker-reachable' in workers[0]['reasons'],workers
        rmw=[r for r in rows if 'object-pointee-atomic-rmw' in r['reasons']]
        assert len(rmw)==1 and rmw[0]['kind']=='cxx-new',rmw
        data=[r for r in rows if r['function']=='main' and r['kind']=='cxx-new-array']
        assert len(data)==1 and 'pointee-atomic-rmw' not in data[0]['reasons'],data
        assert not any('pointee-atomic-rmw' in r['reasons'] for r in report(0))
    print(f'PASS: {count} LLVM RUN checks; std::thread callback/lambda, list/vector member RMW, readonly exclusion, weight=0')


if __name__=='__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stdout or '')
        print(error.stderr or '')
        raise

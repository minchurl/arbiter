import hashlib, json, os, shutil, subprocess
from pathlib import Path
root=Path.cwd(); base=root/'build/libcuckoo-rmw'; source=root/'benchmark/libcuckoo/libcuckoo-upstream'
out=base/'upstream-unit-validation'; out.mkdir(exist_ok=False)
records=[]
for variant in ['baseline','ttas','ttas-padded']:
    work=out/variant
    src=work/'source'
    shutil.copytree(source,src,ignore=shutil.ignore_patterns('.git'))
    if variant!='baseline':
        shutil.copytree(base/('variant-'+variant)/'include/libcuckoo',src/'libcuckoo',dirs_exist_ok=True)
    build=work/'build'
    commands=[['cmake','-S',str(src),'-B',str(build),'-G','Ninja',
               '-DCMAKE_CXX_COMPILER='+str(root/'.tools/llvm-18.1.8/bin/clang++'),
               '-DCMAKE_CXX_FLAGS=--gcc-install-dir='+subprocess.check_output(['gcc','-print-libgcc-file-name'],text=True).strip().rsplit('/',1)[0],
               '-DCMAKE_CXX_STANDARD=17','-DCMAKE_BUILD_TYPE=RelWithDebInfo',
               '-DBUILD_UNIT_TESTS=ON','-DBUILD_TESTS=OFF','-DBUILD_STRESS_TESTS=OFF',
               '-DBUILD_UNIVERSAL_BENCHMARK=OFF','-DBUILD_EXAMPLES=OFF'],
              ['cmake','--build',str(build),'-j','4','--target','unit_tests'],
              ['ctest','--test-dir',str(build),'--output-on-failure','-V']]
    record={'variant':variant,'commands':commands,
            'headers_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((src/'libcuckoo').glob('*.hh'))}}
    (work/'commands.json').write_text(json.dumps(record,indent=2)+'\n')
    for label,command in zip(['configure','build','ctest'],commands):
        print(variant,label,flush=True)
        with (work/(label+'.log')).open('w') as log:
            subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=600)
    record['passed']=True;records.append(record)
    (out/'summary.json').write_text(json.dumps(records,indent=2)+'\n')
print('PASS: baseline, TTAS and TTAS+padded upstream unit suites',flush=True)

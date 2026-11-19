"""Verify frozen artifacts, worker code, and selection effects without edits."""
import csv,hashlib,json,os,re,struct,subprocess
from pathlib import Path
root=Path.cwd();base=root/'build/companion-placement'
frozen=json.loads((base/'frozen.json').read_text())
for name,digest in frozen['files'].items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,name
for name,expected in frozen['traces'].items():
    st=Path(name).stat();assert dict(size=st.st_size,mtime_ns=st.st_mtime_ns,inode=st.st_ino)==expected
assert not subprocess.check_output(['git','diff',frozen['base_commit'],'--','benchmark','compiler','runtime','configs'])
upstream=root/'benchmark/libcuckoo/libcuckoo-upstream'
assert not subprocess.check_output(['git','-C',str(upstream),'status','--porcelain'])
builds=json.loads((base/'build.json').read_text());reports=[]
env=dict(os.environ,LD_LIBRARY_PATH=str(root/'.tools/libtinfo5-root/lib/x86_64-linux-gnu')+':'+str(root/'.tools/libllvm18-root/usr/lib/x86_64-linux-gnu'))
for build in builds:
    assert hashlib.sha256((base/build['name']/'binary').read_bytes()).hexdigest()==build['binary_sha256']
    command=[arg.replace('-passes=arbiter-experiment-hitm-seed-rewrite','-passes=arbiter-report-hitm-seed-sites') for arg in build['commands'][0][:-2]]+['-disable-output']
    subprocess.run(command,env=env,check=True)
    selected=[int(row['site_id']) for row in csv.DictReader((base/build['name']/'selection.csv').open()) if row['selected']=='yes']
    assert sorted(selected)==sorted(map(int,build['ids'].split(',')))
    reports.append(dict(variant=build['name'],command=command,selected=selected))
symbol=next(line.split()[-1] for line in subprocess.check_output(['nm',str(base/'lock/binary')],text=True).splitlines() if re.search(r' T _Z6worker',line))
workers={}
for name in ['lock','bucket','both']:
    result=subprocess.run(['objdump','-d','--no-show-raw-insn','--disassemble='+symbol,str(base/name/'binary')],text=True,capture_output=True,check=True)
    (base/name/'worker.asm').write_text(result.stdout)
    lines=[]
    for line in result.stdout.splitlines():
        m=re.match(r'\s*[0-9a-f]+:\s*(.*)',line)
        if m:
            inst=re.sub(r'-?0x[0-9a-f]+\(%rip\)','RIP',m[1])
            inst=re.sub(r'\b[0-9a-f]+ (?=<)','ADDR ',inst)
            lines.append(inst)
    assert lines
    workers[name]=dict(instructions=len(lines),sha256=hashlib.sha256('\n'.join(lines).encode()).hexdigest())
assert len({row['sha256'] for row in workers.values()})==1,workers
def text_section(binary):
    data=binary.read_bytes();assert data[:6]==b'\x7fELF\x02\x01'
    start=struct.unpack_from('<Q',data,40)[0]
    size,count,names_index=struct.unpack_from('<HHH',data,58)
    assert size==64 and 0<names_index<count
    sections=[struct.unpack_from('<IIQQQQIIQQ',data,start+i*size) for i in range(count)]
    names=sections[names_index];strings=data[names[4]:names[4]+names[5]]
    for section in sections:
        if strings[section[0]:].split(b'\0',1)[0]==b'.text':
            return data[section[4]:section[4]+section[5]]
    raise AssertionError('Missing ELF text section')
lock_text=text_section(base/'lock/binary')
assert lock_text==text_section(root/'build/libcuckoo-rmw/bench-final/contention-placed')
helper_symbols=sorted(set(re.findall(r'call\s+[0-9a-f]+ <(_ZNK9libcuckoo[^>]+)>',(base/'lock/worker.asm').read_text())))
assert len(helper_symbols)==3
helpers={}
for symbol_name in helper_symbols:
    implementations={}
    for name in ['lock','bucket','both']:
        text=subprocess.run(['objdump','-d','--no-show-raw-insn','--disassemble='+symbol_name,str(base/name/'binary')],text=True,capture_output=True,check=True).stdout
        lines=[]
        for line in text.splitlines():
            m=re.match(r'\s*[0-9a-f]+:\s*(.*)',line)
            if m:
                instruction=re.sub(r'-?0x[0-9a-f]+\(%rip\)','RIP',m[1])
                lines.append(re.sub(r'\b[0-9a-f]+ (?=<)','ADDR ',instruction))
        assert lines
        implementations[name]=dict(instructions=len(lines),sha256=hashlib.sha256('\n'.join(lines).encode()).hexdigest())
    assert len({r['sha256'] for r in implementations.values()})==1,implementations
    helpers[symbol_name]=implementations
micro_path=root/'build/placement-diagnosis/placements/micro-both'
micro_expected=json.loads((micro_path/'manifest.json').read_text())['binary_sha256']
assert hashlib.sha256((micro_path/'binary').read_bytes()).hexdigest()==micro_expected
micro_workers={}
for name,binary in [('both',micro_path/'binary'),('automatic',root/'build/libcuckoo-rmw/micro/micro-placed')]:
    decoded=subprocess.run(['objdump','-d','--no-show-raw-insn','--disassemble=_ZL13victim_threadi6ConfigP12VictimResult',str(binary)],text=True,capture_output=True,check=True).stdout
    lines=[]
    for line in decoded.splitlines():
        m=re.match(r'\s*[0-9a-f]+:\s*(.*)',line)
        if m:
            inst=re.sub(r'-?0x[0-9a-f]+\(%rip\)','RIP',m[1])
            lines.append(re.sub(r'\b[0-9a-f]+ (?=<)','ADDR ',inst))
    assert lines
    micro_workers[name]=dict(instructions=len(lines),sha256=hashlib.sha256('\n'.join(lines).encode()).hexdigest())
assert micro_workers['both']==micro_workers['automatic']
for path in base.glob('*/manifest.json'):
    data=json.loads(path.read_text())
    if 'binaries' in data:
        for name,digest in data['binaries'].items():assert hashlib.sha256((base/name/'binary').read_bytes()).hexdigest()==digest,path
    if 'sha256' in data:
        assert data['sha256'] in [micro_expected,frozen['files']['build/libcuckoo-rmw/micro/micro-placed']],path
        assert hashlib.sha256(Path(data['binary']).read_bytes()).hexdigest()==data['sha256']
thresholds={}
folder=root/'results/libcuckoo/object-rmw-20261119/selection'
for name in ['new-micro64','contention','new-xindex']:
    rows=list(csv.DictReader((folder/(name+'.csv')).open()))
    thresholds[name]={}
    for cutoff in [5,4,3,2,1]:
        eligible=[r for r in rows if r['kind'] in ['cxx-new','cxx-new-array','malloc','calloc','realloc'] and int(r['score'])>=cutoff and not any(s in r['reasons'] for s in ['no-escape','no-sync-mutable','not-supported-allocation'])]
        eligible.sort(key=lambda r:(-int(r['score']),int(r['site_id'])))
        thresholds[name][cutoff]=dict(eligible=[int(r['site_id']) for r in eligible],selected=[int(r['site_id']) for r in eligible[:12]])
result=dict(frozen_file_count=len(frozen['files']),sources_and_inputs_unchanged=True,
    main_commit=subprocess.check_output(['git','rev-parse','main'],text=True).strip(),
    workers=workers,workers_identical=True,allocation_selection_reports=reports,lock_control_matches_automatic_text=True,lock_text_sha256=hashlib.sha256(lock_text).hexdigest(),lookup_and_lock_helpers=helpers,micro_workers=micro_workers,micro_binary_sha256=micro_expected,thresholds=thresholds,
    limitations=['Score is static evidence, not access frequency or companion relationship.',
    'Existing runtime binds complete selected extents to one node. Ballast fractions cannot be encoded by a site score threshold.',
    'Libcuckoo initial buckets have no-sync-mutable; lowering score alone does not select them.'])
(base/'audit.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS frozen files:',len(frozen['files']),'identical worker instructions:',workers['lock']['instructions'])

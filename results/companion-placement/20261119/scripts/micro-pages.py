"""External page-only intervention, invoked by GDB before workers and after join."""
import collections, ctypes, hashlib, json, os, random, re, struct, subprocess, sys, time
from pathlib import Path

pid, binary, destination, action, percent, table_node, seed = sys.argv[1:]
pid, percent, table_node, seed = map(int, [pid, percent, table_node, seed])
destination = Path(destination)
lib = ctypes.CDLL('libnuma.so.1', use_errno=True)
lib.numa_move_pages.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.c_int]
symbols = subprocess.check_output(['nm', binary], text=True)
offsets = {name:int(re.search(r'^([0-9a-f]+) \w '+re.escape(name)+r'$', symbols, re.M)[1],16)
           for name in ['_ZL7g_table', '_ZL12g_table_size', '_ZL9g_ballast', '_ZL15g_ballast_elems']}
maps = Path(f'/proc/{pid}/maps').read_text()
load = int(next(line for line in maps.splitlines() if binary in line and line.split()[2]=='00000000').split('-')[0],16)
fd = os.open(f'/proc/{pid}/mem', os.O_RDONLY)
def read64(name):
    return struct.unpack('<Q', os.pread(fd,8,load+offsets[name]))[0]
objects = {'table':(read64('_ZL7g_table'), read64('_ZL12g_table_size')*64),
           'ballast':(read64('_ZL9g_ballast'), read64('_ZL15g_ballast_elems')*8)}
os.close(fd)
def status(pages, targets=None):
    result=[]
    for pos in range(0,len(pages),4096):
        batch=pages[pos:pos+4096]
        addr=(ctypes.c_void_p*len(batch))(*batch)
        wanted=None if targets is None else (ctypes.c_int*len(batch))(*targets[pos:pos+4096])
        states=(ctypes.c_int*len(batch))(*([-999]*len(batch)))
        ret=lib.numa_move_pages(pid,len(batch),addr,wanted,states,0 if wanted is None else 2)
        assert ret==0 and min(states)>=0,(ret,ctypes.get_errno(),collections.Counter(states))
        result.extend(states)
    return result
records={}
for name,(address,size) in objects.items():
    assert size and address
    pages=list(range(address//4096*4096,(address+size+4095)//4096*4096,4096))
    # Nested, uniform random subsets: the 1% set is contained in 5%, then 10%.
    indices=list(range(len(pages)))
    random.Random(seed).shuffle(indices)
    selected=set(indices[:len(pages)*percent//100]) if name=='ballast' else set()
    targets=[(2 if i in selected else 0) if name=='ballast' else table_node for i in range(len(pages))]
    before=status(pages)
    started=time.monotonic()
    if action=='place':
        assert set(before)=={0},(name,collections.Counter(before))
        to_move=[p for p,n in zip(pages,targets) if n!=0]
        if to_move:assert status(to_move,[2]*len(to_move))==[2]*len(to_move)
    after=status(pages)
    assert after==targets,(name,action,collections.Counter(after),collections.Counter(targets))
    records[name]=dict(address=hex(address),bytes=size,pages=len(pages),
        before=dict(collections.Counter(before)),after=dict(collections.Counter(after)),
        page_index_sha256=hashlib.sha256(b''.join(struct.pack('<I',i) for i in sorted(selected))).hexdigest(),
        migration_and_query_seconds=time.monotonic()-started)
destination.with_suffix('.'+action+'.json').write_text(json.dumps(dict(pid=pid,percent=percent,table_node=table_node,seed=seed,objects=records),indent=2)+'\n')
destination.with_suffix('.'+action+'.numa_maps').write_text(Path(f'/proc/{pid}/numa_maps').read_text())
rollup=Path(f'/proc/{pid}/smaps_rollup').read_text()
assert re.search(r'^AnonHugePages:\s+0 kB$',rollup,re.M), 'Huge-page split would confound partial placement'
assert re.search(r'^Swap:\s+0 kB$',rollup,re.M)
destination.with_suffix('.'+action+'.smaps_rollup').write_text(rollup)

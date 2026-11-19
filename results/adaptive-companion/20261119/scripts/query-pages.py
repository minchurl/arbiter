"""GDB diagnostic: query every object page. Never request page migration."""
import collections,ctypes,hashlib,json,os,re,struct,subprocess,sys
from pathlib import Path
pid,binary,destination,phase=sys.argv[1:];pid=int(pid);destination=Path(destination)
lib=ctypes.CDLL('libnuma.so.1',use_errno=True)
lib.numa_move_pages.argtypes=[ctypes.c_int,ctypes.c_ulong,ctypes.POINTER(ctypes.c_void_p),ctypes.POINTER(ctypes.c_int),ctypes.POINTER(ctypes.c_int),ctypes.c_int]
symbols=subprocess.check_output(['nm',binary],text=True)
names=['_ZL7g_table','_ZL12g_table_size','_ZL9g_ballast','_ZL15g_ballast_elems']
offsets={name:int(re.search(r'^([0-9a-f]+) \w '+re.escape(name)+r'$',symbols,re.M)[1],16) for name in names}
maps=Path(f'/proc/{pid}/maps').read_text()
load=int(next(line for line in maps.splitlines() if binary in line and line.split()[2]=='00000000').split('-')[0],16)
fd=os.open(f'/proc/{pid}/mem',os.O_RDONLY)
def read(name):return struct.unpack('<Q',os.pread(fd,8,load+offsets[name]))[0]
objects={'table':(read(names[0]),read(names[1])*64),'ballast':(read(names[2]),read(names[3])*8)}
os.close(fd);records={}
for name,(address,size) in objects.items():
    page_addresses=range(address//4096*4096,(address+size+4095)//4096*4096,4096)
    counts=collections.Counter();digest=hashlib.sha256()
    for pos in range(0,len(page_addresses),4096):
        batch=page_addresses[pos:pos+4096]
        addresses=(ctypes.c_void_p*len(batch))(*batch);states=(ctypes.c_int*len(batch))(*([-999]*len(batch)))
        # nodes=NULL and flags=0: residency query only.
        ret=lib.numa_move_pages(pid,len(batch),addresses,None,states,0)
        assert ret==0 and set(states)<={0,2},(ret,ctypes.get_errno(),collections.Counter(states))
        counts.update(states);digest.update(bytes(states))
    records[name]=dict(address=hex(address),bytes=size,pages=len(page_addresses),nodes={str(node):count for node,count in counts.items()},ordered_residency_sha256=digest.hexdigest())
rollup=Path(f'/proc/{pid}/smaps_rollup').read_text()
assert re.search(r'^AnonHugePages:\s+0 kB$',rollup,re.M) and re.search(r'^Swap:\s+0 kB$',rollup,re.M)
destination.with_suffix('.'+phase+'.json').write_text(json.dumps(dict(pid=pid,objects=records,method='All-page query only; nodes=NULL. No page migration.'),indent=2)+'\n')
destination.with_suffix('.'+phase+'.smaps').write_text(rollup)
if phase=='after':
    before=json.loads(destination.with_suffix('.before.json').read_text())
    assert before['objects']==records,'Residency changed during timed interval'

#!/usr/bin/env python3
import struct, gzip, zlib, subprocess, os, sys

REPO = "/home/micah/Desktop/Sylorlabs/mathpressor"
SRC = sys.argv[1]            # structured dir
MATH = sys.argv[2]           # produced .math
BIN = os.path.join(REPO, "zig-out/bin/mathpressor")

NAMES = {0x01:'bytecode',0x02:'fallback',0x03:'store',0x04:'residual',0x08:'filtered',
         0x09:'columnar',0x0A:'image2d',0x0B:'dict',0x0C:'audio',0x0D:'bcj2',
         0x0E:'cm',0x0F:'chunked',0x10:'optlzma'}

def csize(cmd, f):
    out = subprocess.run(cmd+[f], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
    return len(out)

# --- mathpressor per-file from the FAT ---
d = open(MATH,'rb').read()
fc=struct.unpack_from('<I',d,6)[0]; gzl=struct.unpack_from('<Q',d,12)[0]
fat = gzip.decompress(d[20:20+gzl]) if d[20:22]==b'\x1f\x8b' else zlib.decompress(d[20:20+gzl],31)
ESZ=280; mp={}
for i in range(fc):
    r=fat[i*ESZ:(i+1)*ESZ]; ct=r[240]
    osz=struct.unpack_from('<Q',r,256)[0]; cs=struct.unpack_from('<Q',r,264)[0]
    path=bytes(b for b in r[0:240] if 32<=b<127).decode('latin1')
    base=os.path.basename(path)
    mp[base]=(NAMES.get(ct,hex(ct)), osz, cs)

files = sorted(os.listdir(SRC))
print(f"\n{'file':<22}{'orig':>10} | {'mp codec':<10}{'mp':>8} | {'zstd19':>8}{'zstd22':>8}{'xz9e':>8} | best (ratio)")
print('-'*104)
wins=0
for fn in files:
    fp=os.path.join(SRC,fn); o=os.path.getsize(fp)
    z19=csize(['zstd','-19','-q','-c'], fp)
    z22=csize(['zstd','--ultra','-22','--long=27','-q','-c'], fp)
    xz=csize(['xz','-9e','-T1','-c'], fp)
    codec, mo, mc = mp.get(fn, ('?',o,o))
    cands={'mp':mc,'zstd19':z19,'zstd22':z22,'xz9e':xz}
    best=min(cands,key=cands.get)
    mr=o/mc if mc else 0
    mark='  <-- MP' if best=='mp' else ''
    if best=='mp': wins+=1
    print(f"{fn:<22}{o:>10,} | {codec:<10}{mr:>7.2f}x | {o/z19:>7.2f}x{o/z22:>7.2f}x{o/xz:>7.2f}x | {best} {o/cands[best]:.2f}x{mark}")
print('-'*104)
print(f"mathpressor wins (smallest) on {wins}/{len(files)} datasets")

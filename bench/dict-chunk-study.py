#!/usr/bin/env python3
# Empirical study: on a real UE4 pak subset, how do we recover the long-range
# cross-chunk redundancy that whole-file zstd captures (via a 128MB LDM window)
# but per-4MB-chunk zstd loses — WHILE keeping every frame independently
# decodable (the live constraint)?
#
# Compares: independent chunking at 4/16/64 MB, a raw sampled-content dictionary
# of various sizes priming 4 MB chunks, and the whole-stream ceiling.
import os, subprocess, sys, tempfile

SUB = sys.argv[1]
LEVEL = "19"
data = open(SUB, "rb").read()
N = len(data)
MB = 1024 * 1024

def zc(buf, extra=None):
    """zstd-compress a bytes buffer at LEVEL, return compressed size."""
    cmd = ["zstd", f"-{LEVEL}", "-q", "-c"]
    if extra:
        cmd[1:1] = extra
    p = subprocess.run(cmd, input=buf, stdout=subprocess.PIPE)
    return len(p.stdout)

def indep_chunks(cs):
    """Independent frames of cs bytes each — sum of compressed sizes."""
    tot = 0
    for off in range(0, N, cs):
        tot += zc(data[off:off + cs])
    return tot

def sampled_dict(D, win=64 * 1024):
    """Raw content dict: D bytes as `win`-sized windows evenly across the file."""
    nsites = max(1, D // win)
    span = max(1, N - win)
    out = bytearray()
    for i in range(nsites):
        off = 0 if nsites == 1 else (span * i) // (nsites - 1)
        out += data[off:off + win]
    return bytes(out)

def indep_chunks_dict(cs, dictbytes):
    """Independent cs-byte frames, each primed with a raw content dict (-D)."""
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(dictbytes); dpath = f.name
    try:
        tot = 0
        for off in range(0, N, cs):
            tot += zc(data[off:off + cs], extra=["-D", dpath])
        return tot
    finally:
        os.unlink(dpath)

print(f"subset = {N/MB:.0f} MiB  level z{LEVEL}\n")

base4 = indep_chunks(4 * MB)
print(f"independent 4 MB chunks (shipping)   : {base4/MB:8.2f} MiB   ratio {N/base4:.3f}x")
b16 = indep_chunks(16 * MB)
print(f"independent 16 MB chunks             : {b16/MB:8.2f} MiB   ratio {N/b16:.3f}x   ({(base4-b16)/MB:+.2f} MiB vs 4MB)")
b64 = indep_chunks(64 * MB)
print(f"independent 64 MB chunks             : {b64/MB:8.2f} MiB   ratio {N/b64:.3f}x   ({(base4-b64)/MB:+.2f} MiB vs 4MB)")

for D in (4 * MB, 16 * MB, 64 * MB):
    d = sampled_dict(D)
    body = indep_chunks_dict(4 * MB, d)
    # dict is stored once; compress it too (it ships compressed)
    dcost = zc(d)
    tot = body + dcost
    print(f"4 MB chunks + {D//MB:2d} MB sampled dict     : {tot/MB:8.2f} MiB   ratio {N/tot:.3f}x   "
          f"(body {body/MB:.2f} + dict {dcost/MB:.2f};  {(base4-tot)/MB:+.2f} MiB vs 4MB)")

whole = zc(data, extra=["--long=27"])
print(f"\nwhole-stream zstd --long=27 (ceiling): {whole/MB:8.2f} MiB   ratio {N/whole:.3f}x   (not seekable)")
print(f"gap 4MB-chunks → whole               : {(base4-whole)/MB:+.2f} MiB  ({(base4-whole)*100/base4:.1f}%)")

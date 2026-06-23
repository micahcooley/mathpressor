#!/usr/bin/env python3
# Generate structured/scientific/synthetic datasets to test whether mathpressor's
# predictor/columnar/audio/residual (formula-based) codecs beat zstd/xz where the
# data has predictive/generative structure (the theory's home turf).
import numpy as np, struct, os, sys

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(1234)

def save(name, arr):
    p = os.path.join(OUT, name)
    arr.tofile(p)
    print(f"  {name:24} {os.path.getsize(p):>10,} B")

print("generating structured datasets:")

# --- media-structured, 8-bit (image2d MED predictor target) ---
# smooth gradient + gaussian blobs → very predictable in byte space
N = 2048
yy, xx = np.mgrid[0:N, 0:N].astype(np.float64)
field = (np.sin(xx/90.0) + np.cos(yy/70.0))
for _ in range(40):
    cx, cy = rng.uniform(0, N, 2); s = rng.uniform(40, 200)
    field += 2.0*np.exp(-((xx-cx)**2+(yy-cy)**2)/(2*s*s))
g = ((field-field.min())/(np.ptp(field))*255).astype(np.uint8)
save("grad8_2048.bin", g)

# multi-octave value noise heightmap (procedural-ish, smooth) → image2d
def value_noise(N, octaves=6):
    acc = np.zeros((N, N)); amp = 1.0; tot = 0.0
    for o in range(octaves):
        step = max(1, N >> (o+2))
        coarse = rng.uniform(0, 1, (N//step+2, N//step+2))
        # bilinear upsample
        ys = np.linspace(0, coarse.shape[0]-1, N); xs = np.linspace(0, coarse.shape[1]-1, N)
        y0 = ys.astype(int); x0 = xs.astype(int)
        fy = (ys-y0)[:,None]; fx = (xs-x0)[None,:]
        c = coarse
        top = c[y0][:,x0]*(1-fx)+c[y0][:,np.minimum(x0+1,c.shape[1]-1)]*fx
        bot = c[np.minimum(y0+1,c.shape[0]-1)][:,x0]*(1-fx)+c[np.minimum(y0+1,c.shape[0]-1)][:,np.minimum(x0+1,c.shape[1]-1)]*fx
        acc += amp*(top*(1-fy)+bot*fy); tot += amp; amp *= 0.5
    return acc/tot
h = value_noise(N)
save("terrain8_2048.bin", ((h-h.min())/np.ptp(h)*255).astype(np.uint8))

# --- 16-bit PCM audio (LPC predictor target), proper WAV header ---
sr = 48000; nsamp = 2_000_000
t = np.arange(nsamp)/sr
sig = (np.sin(2*np.pi*(220+40*t)*t) + 0.5*np.sin(2*np.pi*(440+80*t)*t)
       + 0.25*np.sin(2*np.pi*880*t))
pcm = (sig/np.abs(sig).max()*30000).astype(np.int16)
with open(os.path.join(OUT, "audio16.wav"), "wb") as f:
    data = pcm.tobytes(); n = len(data)
    f.write(b"RIFF"); f.write(struct.pack("<I", 36+n)); f.write(b"WAVE")
    f.write(b"fmt "); f.write(struct.pack("<IHHIIHH", 16,1,1,sr,sr*2,2,16))
    f.write(b"data"); f.write(struct.pack("<I", n)); f.write(data)
print(f"  audio16.wav              {os.path.getsize(os.path.join(OUT,'audio16.wav')):>10,} B")

# --- tabular record array AoS (columnar transpose + delta target) ---
M = 200_000
ids = np.arange(M, dtype=np.uint32)
x = np.cumsum(rng.normal(0,1,M)).astype(np.float32)   # smooth random walk
y = np.cumsum(rng.normal(0,1,M)).astype(np.float32)
z = np.cumsum(rng.normal(0,1,M)).astype(np.float32)
ts = (1_700_000_000 + np.arange(M)*16).astype(np.uint32)  # monotonic timestamps
rec = np.zeros(M, dtype=[('id','<u4'),('x','<f4'),('y','<f4'),('z','<f4'),('ts','<u4')])
rec['id']=ids; rec['x']=x; rec['y']=y; rec['z']=z; rec['ts']=ts
save("records_aos.bin", rec)

# --- float32 scientific 2D field (the SZ/ZFP niche; tests float-awareness) ---
Nf = 1024
yy, xx = np.mgrid[0:Nf, 0:Nf].astype(np.float64)
ff = np.sin(xx/50.0)*np.cos(yy/40.0)
for _ in range(30):
    cx, cy = rng.uniform(0, Nf, 2); s = rng.uniform(20, 120)
    ff += np.exp(-((xx-cx)**2+(yy-cy)**2)/(2*s*s))
save("field_f32_1024.bin", ff.astype(np.float32))

# --- float32 smooth time-series (sensor) ---
L = 1_000_000
tt = np.arange(L)/1000.0
series = (0.001*tt + np.sin(tt/5.0) + 0.3*np.sin(tt/0.7) + rng.normal(0,0.01,L))
save("timeseries_f32.bin", series.astype(np.float32))

# --- monotonic u32 counter (delta → near-nothing) ---
save("counter_u32.bin", (np.arange(1_000_000, dtype=np.uint32)*7 + 3))

# --- mostly-constant 8-bit with sparse changes (RLE/constant) ---
sp = np.full(4_000_000, 200, dtype=np.uint8)
idx = rng.integers(0, sp.size, 4000); sp[idx] = rng.integers(0, 256, 4000)
save("sparse8.bin", sp)

print("done.")

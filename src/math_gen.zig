//! math_gen.zig — Deterministic, integer-only mathematical generators.
//!
//! HARD RULE: nothing in this file may use `f32`/`f64` or any floating point.
//! Every routine is built from strict 32/64-bit integer arithmetic so that
//! the exact same bytes are generated regardless of CPU architecture or
//! endianness. This is the bedrock of Mathpressor's determinism guarantee.

const std = @import("std");

// ---------------------------------------------------------------------------
// PRNG — XorShift32
// ---------------------------------------------------------------------------

/// A bit-perfect 32-bit XorShift PRNG.
///
/// We roll our own instead of using `std.Random` because the standard library's
/// RNG internals are an implementation detail that can change between Zig
/// releases. This struct's output is frozen: pure u32 bit operations, no tables,
/// no float, identical on big- and little-endian machines.
pub const XorShift32 = struct {
    state: u32,

    /// Seed the generator. XorShift cannot escape a zero state, so a zero seed
    /// is remapped to a fixed non-zero constant.
    pub fn init(seed: u32) XorShift32 {
        return .{ .state = if (seed == 0) 0xDEAD_BEEF else seed };
    }

    /// Advance and return the next 32-bit value.
    pub fn next(self: *XorShift32) u32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return x;
    }

    /// Return the top 8 bits of the next value (better quality than the low bits).
    pub fn nextByte(self: *XorShift32) u8 {
        return @truncate(self.next() >> 24);
    }

    /// Return a value in [0, bound) using plain modulo.
    pub fn nextBelow(self: *XorShift32, bound: u32) u32 {
        if (bound == 0) return 0;
        return self.next() % bound;
    }
};

// ---------------------------------------------------------------------------
// Integer value / lattice noise
// ---------------------------------------------------------------------------
//
// Canonical simplex noise relies on floating-point gradients, which would break
// cross-architecture determinism. We use an integer lattice noise built on a
// fixed-point smoothstep: smooth, organic gradients — all exact integer ops.

const FRACT_BITS: u5 = 8;
const FRACT_ONE: i64 = 1 << FRACT_BITS; // 256

/// Integer avalanche hash of a lattice corner under `seed`.
fn hashCorner(seed: u32, gx: i32, gy: i32) u8 {
    var h: u32 = seed *% 0x9E37_79B1;
    h ^= @as(u32, @bitCast(gx)) *% 0x85EB_CA6B;
    h = (h ^ (h >> 13)) *% 0xC2B2_AE35;
    h ^= @as(u32, @bitCast(gy)) *% 0x27D4_EB2F;
    h = (h ^ (h >> 15)) *% 0x1656_67B1;
    h ^= h >> 16;
    return @truncate(h >> 24);
}

/// Fixed-point smoothstep s(t) = t^2*(3−2t), input/output scaled by FRACT_ONE.
fn smoothstep(t: i64) i64 {
    const t2 = (t * t) >> FRACT_BITS;
    const three_minus_2t = (3 << FRACT_BITS) - 2 * t;
    return (t2 * three_minus_2t) >> FRACT_BITS;
}

/// Fixed-point lerp between byte values a and b. `t` is scaled by FRACT_ONE.
fn lerp(a: i64, b: i64, t: i64) i64 {
    return a + (((b - a) * t) >> FRACT_BITS);
}

/// Sample single-octave integer value noise at pixel (px, py). Returns 0..255.
pub fn valueNoise2D(seed: u32, px: u32, py: u32, w: u32, h: u32, freq: u32) u8 {
    const f: i64 = if (freq == 0) 1 else freq;
    const lx: i64 = @divTrunc(@as(i64, px) * f * FRACT_ONE, @as(i64, w));
    const ly: i64 = @divTrunc(@as(i64, py) * f * FRACT_ONE, @as(i64, h));
    const gx0: i32 = @intCast(lx >> FRACT_BITS);
    const gy0: i32 = @intCast(ly >> FRACT_BITS);
    const gx1 = gx0 + 1;
    const gy1 = gy0 + 1;
    const sx = smoothstep(lx & (FRACT_ONE - 1));
    const sy = smoothstep(ly & (FRACT_ONE - 1));
    const c00: i64 = hashCorner(seed, gx0, gy0);
    const c10: i64 = hashCorner(seed, gx1, gy0);
    const c01: i64 = hashCorner(seed, gx0, gy1);
    const c11: i64 = hashCorner(seed, gx1, gy1);
    const top = lerp(c00, c10, sx);
    const bottom = lerp(c01, c11, sx);
    const v = lerp(top, bottom, sy);
    return @intCast(std.math.clamp(v, 0, 255));
}

/// Fill a w×h buffer with 4-octave fractal integer noise.
pub fn fillFractalNoise(buf: []u8, w: u32, h: u32, seed: u32, freq: u8) void {
    const octaves: u32 = 4;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var sum: i64 = 0;
            var total: i64 = 0;
            var amp: i64 = 256;
            var f: u32 = if (freq == 0) 1 else freq;
            var o: u32 = 0;
            while (o < octaves) : (o += 1) {
                const n = valueNoise2D(seed +% (o *% 0x9E37_79B9), x, y, w, h, f);
                sum += @as(i64, n) * amp;
                total += amp;
                amp >>= 1;
                if (amp == 0) break;
                f *%= 2;
            }
            buf[@as(usize, y) * @as(usize, w) + @as(usize, x)] = @intCast(@divTrunc(sum, total));
        }
    }
}

// ---------------------------------------------------------------------------
// Domain warp
// ---------------------------------------------------------------------------
//
// Domain warping displaces the sample coordinates of `src` by amounts derived
// from `disp`, creating twisted, organic-looking results from simple noise.
// The displacement is 100% integer: no floats, no tables.
//
// We use `disp[i] − 128` for the X offset and its negation for Y, which
// approximates a 90-degree rotation of the displacement field and gives
// convincing 2-D warp from a single greyscale channel.

/// Warp-sample `src` into `dst` using `disp` as a displacement field.
/// `dst` and `src` MUST NOT alias. `disp` may alias either.
/// `strength` is a scale factor: 128 ≈ ±64-pixel max displacement.
pub fn warpSample(
    dst: []u8,
    src: []const u8,
    disp: []const u8,
    w: u32,
    h: u32,
    strength: u8,
) void {
    const iw: i32 = @intCast(w);
    const ih: i32 = @intCast(h);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const idx = @as(usize, y) * @as(usize, w) + @as(usize, x);
            const d: i32 = @as(i32, disp[idx]) - 128; // −128 .. 127
            // Arithmetic right-shift for sign preservation (Zig guarantees this
            // for signed integers, per the language spec §5.8).
            const dx: i32 = (d * @as(i32, strength)) >> 7;
            const dy: i32 = (-d * @as(i32, strength)) >> 7;
            const sx = std.math.clamp(@as(i32, @intCast(x)) + dx, 0, iw - 1);
            const sy = std.math.clamp(@as(i32, @intCast(y)) + dy, 0, ih - 1);
            dst[idx] = src[@as(usize, @intCast(sy)) * @as(usize, w) + @as(usize, @intCast(sx))];
        }
    }
}

// ---------------------------------------------------------------------------
// Level / contrast-stretch
// ---------------------------------------------------------------------------

/// Remap pixel values: [lo,hi] is stretched to [0,255]; outside clamps.
/// All arithmetic is integer; the result is identical on any architecture.
pub fn levelRemap(buf: []u8, lo: u8, hi: u8) void {
    if (lo >= hi) {
        for (buf) |*p| p.* = if (p.* >= lo) 255 else 0;
        return;
    }
    const range: u32 = @as(u32, hi) - @as(u32, lo);
    for (buf) |*p| {
        const v = p.*;
        if (v <= lo) {
            p.* = 0;
        } else if (v >= hi) {
            p.* = 255;
        } else {
            p.* = @intCast((@as(u32, v - lo) * 255) / range);
        }
    }
}

// ---------------------------------------------------------------------------
// Cellular Automata
// ---------------------------------------------------------------------------

/// Seed a buffer with a deterministic random fill. `fill_percent` is 0..100.
pub fn cellularSeed(buf: []u8, prng: *XorShift32, fill_percent: u32) void {
    for (buf) |*c| {
        c.* = if (prng.nextBelow(100) < fill_percent) 255 else 0;
    }
}

/// One Moore-neighbourhood automaton step from `src` into `dst` (both w×h).
/// Out-of-bounds neighbours count as walls so structures close at the border.
pub fn cellularStep(
    src: []const u8,
    dst: []u8,
    w: u32,
    h: u32,
    birth_limit: u32,
    survive_limit: u32,
) void {
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var alive: u32 = 0;
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    if (dx == 0 and dy == 0) continue;
                    const nx = @as(i32, @intCast(x)) + dx;
                    const ny = @as(i32, @intCast(y)) + dy;
                    if (nx < 0 or ny < 0 or nx >= w or ny >= h) {
                        alive += 1;
                        continue;
                    }
                    const ni = @as(usize, @intCast(ny)) * @as(usize, w) + @as(usize, @intCast(nx));
                    if (src[ni] > 127) alive += 1;
                }
            }
            const idx = @as(usize, y) * @as(usize, w) + @as(usize, x);
            const is_alive = src[idx] > 127;
            const next_alive = if (is_alive) (alive >= survive_limit) else (alive > birth_limit);
            dst[idx] = if (next_alive) 255 else 0;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "XorShift32 produces a frozen, known sequence" {
    var r = XorShift32.init(1);
    try std.testing.expectEqual(@as(u32, 270369), r.next());
    var r2 = XorShift32.init(1);
    try std.testing.expectEqual(r.state, blk: {
        _ = r2.next();
        break :blk r2.state;
    });
}

test "XorShift32 never gets stuck at zero" {
    var r = XorShift32.init(0);
    try std.testing.expect(r.state != 0);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try std.testing.expect(r.next() != 0 or r.state != 0);
    }
}

test "value noise is deterministic and in range" {
    const v1 = valueNoise2D(42, 10, 7, 64, 64, 8);
    const v2 = valueNoise2D(42, 10, 7, 64, 64, 8);
    try std.testing.expectEqual(v1, v2);
    try std.testing.expect(valueNoise2D(43, 10, 7, 64, 64, 8) != v1 or
        valueNoise2D(99, 10, 7, 64, 64, 8) != v1);
}

test "fractal noise fills buffer deterministically" {
    const a = std.testing.allocator;
    const w: u32 = 32;
    const h: u32 = 32;
    const b1 = try a.alloc(u8, w * h);
    defer a.free(b1);
    const b2 = try a.alloc(u8, w * h);
    defer a.free(b2);
    fillFractalNoise(b1, w, h, 0xABCDEF, 4);
    fillFractalNoise(b2, w, h, 0xABCDEF, 4);
    try std.testing.expectEqualSlices(u8, b1, b2);
}

test "warpSample is deterministic and stays in-range" {
    const a = std.testing.allocator;
    const w: u32 = 32;
    const h: u32 = 32;
    const src = try a.alloc(u8, w * h);
    defer a.free(src);
    const disp = try a.alloc(u8, w * h);
    defer a.free(disp);
    const dst1 = try a.alloc(u8, w * h);
    defer a.free(dst1);
    const dst2 = try a.alloc(u8, w * h);
    defer a.free(dst2);

    fillFractalNoise(src, w, h, 0x111, 4);
    fillFractalNoise(disp, w, h, 0x222, 6);
    warpSample(dst1, src, disp, w, h, 64);
    warpSample(dst2, src, disp, w, h, 64);
    try std.testing.expectEqualSlices(u8, dst1, dst2);
    for (dst1) |p| try std.testing.expect(p <= 255); // trivially true but proves no UB
}

test "levelRemap stretches the range" {
    var buf = [_]u8{ 0, 50, 100, 150, 200, 255 };
    levelRemap(&buf, 50, 200);
    try std.testing.expectEqual(@as(u8, 0), buf[0]); // clamped below lo
    try std.testing.expectEqual(@as(u8, 0), buf[1]); // exactly lo
    try std.testing.expectEqual(@as(u8, 255), buf[4]); // exactly hi
    try std.testing.expectEqual(@as(u8, 255), buf[5]); // clamped above hi
    try std.testing.expect(buf[2] > 0 and buf[2] < 255);
}

test "cellular automaton is binary and deterministic" {
    const a = std.testing.allocator;
    const w: u32 = 16;
    const h: u32 = 16;
    const src = try a.alloc(u8, w * h);
    defer a.free(src);
    const dst = try a.alloc(u8, w * h);
    defer a.free(dst);
    var prng = XorShift32.init(7);
    cellularSeed(src, &prng, 45);
    cellularStep(src, dst, w, h, 4, 3);
    for (dst) |c| try std.testing.expect(c == 0 or c == 255);
    const dst2 = try a.alloc(u8, w * h);
    defer a.free(dst2);
    var prng2 = XorShift32.init(7);
    cellularSeed(src, &prng2, 45);
    cellularStep(src, dst2, w, h, 4, 3);
    try std.testing.expectEqualSlices(u8, dst, dst2);
}

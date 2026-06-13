//! cm.zig — a pure-Zig context-mixing compressor (lpaq family).
//!
//! LZMA is a strong LZ+range-coder, but on text and binary the best general
//! archivers (xz, 7-Zip) edge mathpressor purely on backend quality. A context-
//! mixing coder beats LZMA's model: it predicts the next BIT from many context
//! models at once (orders 1..6 + a match model that captures LZ-style
//! redundancy), blends them with an online logistic mixer, refines with an SSE
//! stage, and arithmetic-codes the bit. This is slow to decode, so it's a
//! COLD / full-mode-only backend — never the live path.
//!
//! encode/decode share one Predictor whose state evolves identically on both
//! sides (each updates from the actual bit), so they are exact inverses.

const std = @import("std");

// ---- logistic transforms (lpaq tables, public domain) ----------------------

const squash_t = [33]i32{ 1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047, 2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094 };

/// logistic: stretched domain [-2047,2047] -> probability [0,4095]
fn squash(d_in: i32) i32 {
    var d = d_in;
    if (d > 2047) return 4095;
    if (d < -2047) return 0;
    const w = d & 127;
    d = (d >> 7) + 16;
    return (squash_t[@intCast(d)] * (128 - w) + squash_t[@intCast(d + 1)] * w + 64) >> 7;
}

var stretch_t: [4096]i16 = undefined;
var stretch_ready = false;

fn initStretch() void {
    if (stretch_ready) return;
    var pi: i32 = 0;
    var x: i32 = -2047;
    while (x <= 2047) : (x += 1) {
        const v = squash(x);
        var j: i32 = pi;
        while (j <= v) : (j += 1) stretch_t[@intCast(j)] = @intCast(x);
        pi = v + 1;
    }
    while (pi < 4096) : (pi += 1) stretch_t[@intCast(pi)] = 2047;
    stretch_ready = true;
}

inline fn stretch(p: i32) i32 {
    return stretch_t[@intCast(p)];
}

// Count-adaptive learning-rate table: dt[n] = 16384/(2n+3). A counter seen n
// times moves by err*dt[n], so it adapts fast when new and slowly once settled.
var dt: [1024]i32 = undefined;
var dt_ready = false;
fn initDt() void {
    if (dt_ready) return;
    var i: usize = 0;
    while (i < 1024) : (i += 1) dt[i] = @intCast(@divTrunc(16384, 2 * @as(i32, @intCast(i)) + 3));
    dt_ready = true;
}

inline fn clampP(p: i32) u32 {
    if (p < 1) return 1;
    if (p > 4095) return 4095;
    return @intCast(p);
}

// A count-adaptive StateMap cell: u32 = (22-bit prediction << 10) | 10-bit count.
inline fn smPredict12(cell: u32) i32 {
    return @intCast(cell >> 20); // 22-bit prediction -> 12-bit
}
inline fn smUpdate(t: []u32, idx: usize, bit: u1) void {
    const raw = t[idx];
    const n: usize = raw & 1023;
    const pred: i64 = @intCast(raw >> 10);
    var base: i64 = @intCast(raw);
    if (n < 1023) base += 1;
    const y22: i64 = @as(i64, bit) << 22;
    const step: i64 = (((y22 - pred) >> 3) * @as(i64, dt[n])) & ~@as(i64, 1023);
    var nv: i64 = base + step;
    if (nv < 0) nv = 0;
    if (nv > 0xFFFF_FFFF) nv = 0xFFFF_FFFF;
    t[idx] = @intCast(nv);
}

// ---- arithmetic coder (LZMA-style low/range/cache; same scheme as bcj2.zig,
//      which round-trips, but here `p` is an EXTERNAL 12-bit P(bit=1)) --------

const kTopValue: u32 = 1 << 24;

const Encoder = struct {
    low: u64 = 0,
    range: u32 = 0xFFFF_FFFF,
    cache: u8 = 0,
    cache_size: u64 = 1,
    out: *std.ArrayList(u8),

    fn shiftLow(self: *Encoder) !void {
        if (@as(u32, @truncate(self.low >> 32)) != 0 or self.low < 0xFF00_0000) {
            var temp = self.cache;
            while (true) {
                try self.out.append(temp +% @as(u8, @truncate(self.low >> 32)));
                temp = 0xFF;
                self.cache_size -= 1;
                if (self.cache_size == 0) break;
            }
            self.cache = @truncate(self.low >> 24);
        }
        self.cache_size += 1;
        self.low = @as(u64, @as(u32, @truncate(self.low)) << 8);
    }

    fn encode(self: *Encoder, bit: u1, p: u32) !void {
        const bound: u32 = (self.range >> 12) * p; // p = P(bit==1)
        if (bit == 1) {
            self.range = bound;
        } else {
            self.low += bound;
            self.range -= bound;
        }
        while (self.range < kTopValue) {
            self.range <<= 8;
            try self.shiftLow();
        }
    }

    fn flush(self: *Encoder) !void {
        var i: usize = 0;
        while (i < 5) : (i += 1) try self.shiftLow();
    }
};

const Decoder = struct {
    code: u32 = 0,
    range: u32 = 0xFFFF_FFFF,
    src: []const u8,
    pos: usize = 0,

    fn nextByte(self: *Decoder) u8 {
        if (self.pos >= self.src.len) return 0;
        const b = self.src[self.pos];
        self.pos += 1;
        return b;
    }

    fn init(src: []const u8) Decoder {
        var d = Decoder{ .src = src };
        _ = d.nextByte(); // first byte is always 0
        var i: usize = 0;
        while (i < 4) : (i += 1) d.code = (d.code << 8) | d.nextByte();
        return d;
    }

    fn decode(self: *Decoder, p: u32) u1 {
        const bound: u32 = (self.range >> 12) * p;
        var bit: u1 = 0;
        if (self.code < bound) {
            bit = 1;
            self.range = bound;
        } else {
            self.code -= bound;
            self.range -= bound;
        }
        while (self.range < kTopValue) {
            self.range <<= 8;
            self.code = (self.code << 8) | self.nextByte();
        }
        return bit;
    }
};

// ---- adaptive probability map (SSE / APM) ----------------------------------

const APM = struct {
    t: []u16,
    n: usize, // number of contexts
    idx: usize = 0,
    a: std.mem.Allocator,

    fn init(a: std.mem.Allocator, n: usize) !APM {
        const t = try a.alloc(u16, n * 33);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var j: usize = 0;
            while (j < 33) : (j += 1) {
                t[i * 33 + j] = @intCast(squash(@as(i32, @intCast(j)) * 128 - 2048) * 16);
            }
        }
        return .{ .t = t, .n = n, .a = a };
    }
    fn deinit(self: *APM) void {
        self.a.free(self.t);
    }

    /// Refine probability `pr` (12-bit) given context `cx`.
    fn pp(self: *APM, pr: i32, cx: usize) i32 {
        const s = stretch(pr) + 2048; // 0..4095
        const w = s & 127;
        const lo = (cx * 33) + @as(usize, @intCast(s >> 7));
        self.idx = lo + (@as(usize, @intFromBool(w >= 64)));
        return (@as(i32, self.t[lo]) * (128 - w) + @as(i32, self.t[lo + 1]) * w) >> 11;
    }

    fn update(self: *APM, bit: u1, rate: u5) void {
        const g: i32 = (@as(i32, bit) << 16) + (@as(i32, bit) << rate) - @as(i32, bit) - @as(i32, bit);
        const cur = @as(i32, self.t[self.idx]);
        self.t[self.idx] = @intCast(cur + ((g - cur) >> rate));
    }
};

// ---- the predictor ---------------------------------------------------------

const NUM_ORDERS = 6; // context orders 1,2,3,4,6 + a sparse model
const orders = [NUM_ORDERS]u32{ 1, 2, 3, 4, 6, 0 }; // 0 = sparse (skip) model handled specially
const TBITS = 22; // 4M entries per model table
const TSIZE = 1 << TBITS;
const TMASK = TSIZE - 1;
const NINPUTS = NUM_ORDERS + 2; // orders + match + bias
const NMIXCTX = 2048; // mixer weight sets: (match-length bucket << 8) | order-0 byte

const Predictor = struct {
    a: std.mem.Allocator,

    // per-order count-adaptive StateMaps: u32 = (22-bit prediction << 10) | 10-bit count
    tables: [NUM_ORDERS][]u32,
    ctxhash: [NUM_ORDERS]u32 = [_]u32{0} ** NUM_ORDERS,
    cur_idx: [NUM_ORDERS]usize = [_]usize{0} ** NUM_ORDERS,

    // partial-byte state
    c0: u32 = 1, // 1-prefixed bits of current byte
    bitpos: u5 = 0,

    // byte history (for context hashing + match model)
    hist: [8]u8 = [_]u8{0} ** 8, // last 8 bytes (ring not needed; shift)

    // match model
    buf: []u8,
    buf_len: usize = 0,
    match_ht: []u32, // hash -> position+1 (0 = empty)
    match_ptr: usize = 0,
    match_len: u32 = 0,
    pred_bit: u1 = 0,
    match_valid: bool = false,
    // learned match confidence: P(actual bit=1 | match length bucket, predicted bit)
    match_sm: []u32,
    match_ctx: usize = 0,
    match_used: bool = false,

    // mixer: weights[ctx][input], i32 fixed point
    weights: []i32,
    mix_ctx: usize = 0,
    inputs: [NINPUTS]i32 = [_]i32{0} ** NINPUTS,
    mixed_p: u32 = 2048,

    // SSE
    apm1: APM,
    apm2: APM,
    final_p: u32 = 2048,

    const MATCH_HBITS = 22;
    const MATCH_HSIZE = 1 << MATCH_HBITS;
    const MATCH_MINLEN = 4; // bytes hashed to seed a match

    fn init(a: std.mem.Allocator, max_len: usize) !Predictor {
        initStretch();
        initDt();
        var p = Predictor{
            .a = a,
            .tables = undefined,
            .buf = try a.alloc(u8, @max(max_len, 1)),
            .match_ht = try a.alloc(u32, MATCH_HSIZE),
            .match_sm = try a.alloc(u32, 256),
            .weights = try a.alloc(i32, NMIXCTX * NINPUTS),
            .apm1 = try APM.init(a, 256),
            .apm2 = try APM.init(a, 0x10000),
        };
        for (&p.tables) |*t| {
            t.* = try a.alloc(u32, TSIZE);
            @memset(t.*, 1 << 31); // prediction = 0.5, count = 0
        }
        @memset(p.match_ht, 0);
        @memset(p.match_sm, 1 << 31);
        @memset(p.weights, 0);
        return p;
    }

    fn deinit(self: *Predictor) void {
        for (self.tables) |t| self.a.free(t);
        self.a.free(self.buf);
        self.a.free(self.match_ht);
        self.a.free(self.match_sm);
        self.a.free(self.weights);
        self.apm1.deinit();
        self.apm2.deinit();
    }

    inline fn hashBytes(self: *Predictor, k: u32) u32 {
        // hash the last k bytes of history
        var h: u32 = 0x811C_9DC5 +% k *% 0x9E37_79B1;
        var i: u32 = 0;
        while (i < k) : (i += 1) {
            h = (h ^ self.hist[i]) *% 0x0100_0193;
        }
        return h;
    }

    /// Recompute per-order base context hashes at a byte boundary.
    fn refreshContexts(self: *Predictor) void {
        for (orders, 0..) |k, i| {
            if (k == 0) {
                // sparse: hash bytes at lag 1 and 3 (skip-gram)
                self.ctxhash[i] = (@as(u32, self.hist[0]) *% 0x9E37_79B1) ^ (@as(u32, self.hist[2]) *% 0x85EB_CA6B);
            } else {
                self.ctxhash[i] = self.hashBytes(k);
            }
        }
    }

    /// Predict P(next bit = 1) as a 12-bit value.
    fn predict(self: *Predictor) u32 {
        // per-order model lookups, combined with the partial byte c0
        var ni: usize = 0;
        for (0..NUM_ORDERS) |i| {
            const idx: usize = (@as(usize, self.ctxhash[i] ^ (self.c0 *% 0x6F4A_7C15)) & TMASK);
            self.cur_idx[i] = idx;
            const p12: i32 = @intCast(self.tables[i][idx] >> 20); // 22-bit pred -> 12-bit
            self.inputs[ni] = stretch(@intCast(clampP(p12)));
            ni += 1;
        }

        // match model input: predict the next bit from the matched byte (while
        // the bits already coded this byte agree with it), and read a LEARNED
        // probability for "match of this length predicts bit b" from a StateMap
        // — far better calibrated than a fixed confidence ramp.
        var match_in: i32 = 0;
        self.match_valid = false;
        self.match_used = false;
        var mbucket: usize = 0;
        if (self.match_len > 0 and self.match_ptr < self.buf_len) {
            const pbyte: u32 = self.buf[self.match_ptr];
            const bp: u32 = self.bitpos; // 0..7 bits consumed so far
            const top: u32 = if (bp == 0) 0 else (pbyte >> @as(u5, @intCast(8 - bp)));
            const expected: u32 = (@as(u32, 1) << @as(u5, @intCast(bp))) | top;
            if (expected == self.c0) {
                self.match_valid = true;
                self.match_used = true;
                const sh: u5 = @intCast(7 - bp);
                self.pred_bit = @intCast((pbyte >> sh) & 1);
                const lb: usize = @intCast(@min(self.match_len, @as(u32, 63)));
                mbucket = @min(self.match_len, @as(u32, 7));
                self.match_ctx = (lb << 1) | @as(usize, self.pred_bit);
                match_in = stretch(@intCast(clampP(smPredict12(self.match_sm[self.match_ctx]))));
            }
        }
        self.inputs[ni] = match_in;
        ni += 1;
        self.inputs[ni] = 256; // bias
        ni += 1;

        // mixer: weight set selected by match-length bucket + order-0 byte, so
        // the mix learns to trust the match more as it lengthens.
        self.mix_ctx = ((mbucket << 8) | self.hist[0]) & (NMIXCTX - 1);
        const w = self.weights[self.mix_ctx * NINPUTS ..][0..NINPUTS];
        var dot: i64 = 0;
        for (0..NINPUTS) |k| dot += @as(i64, w[k]) * @as(i64, self.inputs[k]);
        var pm: i32 = @intCast(@as(i64, @intCast(dot)) >> 16);
        if (pm < -2047) pm = -2047;
        if (pm > 2047) pm = 2047;
        self.mixed_p = clampP(squash(pm));

        // SSE: two APM stages, averaged
        const p1 = self.apm1.pp(@intCast(self.mixed_p), self.hist[0]);
        const p2 = self.apm2.pp(@intCast(self.mixed_p), self.c0 & 0xFFFF);
        var pf = (@as(i32, @intCast(self.mixed_p)) + p1 + 2 * p2) >> 2;
        self.final_p = clampP(pf);
        _ = &pf;
        return self.final_p;
    }

    /// Update all models with the actual bit, then advance partial-byte state.
    fn update(self: *Predictor, bit: u1) void {
        // per-order + match count-adaptive StateMap updates
        for (0..NUM_ORDERS) |i| smUpdate(self.tables[i], self.cur_idx[i], bit);
        if (self.match_used) smUpdate(self.match_sm, self.match_ctx, bit);

        // mixer weight update
        const err: i32 = (@as(i32, bit) << 12) - @as(i32, @intCast(self.mixed_p));
        const w = self.weights[self.mix_ctx * NINPUTS ..][0..NINPUTS];
        for (0..NINPUTS) |k| {
            w[k] += (self.inputs[k] * err) >> 10;
        }

        // SSE update
        self.apm1.update(bit, 7);
        self.apm2.update(bit, 7);

        // advance partial byte
        self.c0 = (self.c0 << 1) | bit;
        self.bitpos += 1;
        if (self.bitpos == 8) {
            const byte: u8 = @truncate(self.c0); // low 8 bits
            self.byteBoundary(byte);
            self.c0 = 1;
            self.bitpos = 0;
        }
    }

    fn byteBoundary(self: *Predictor, byte: u8) void {
        // match model: extend or re-seed
        if (self.match_len > 0 and self.match_ptr < self.buf_len and self.buf[self.match_ptr] == byte) {
            self.match_ptr += 1;
            self.match_len +%= 1;
        } else {
            self.match_len = 0;
        }

        // append to history buffer
        if (self.buf_len < self.buf.len) {
            self.buf[self.buf_len] = byte;
            self.buf_len += 1;
        }

        // shift byte history (hist[0] = most recent)
        var i: usize = self.hist.len - 1;
        while (i > 0) : (i -= 1) self.hist[i] = self.hist[i - 1];
        self.hist[0] = byte;

        // seed a new match from the last MATCH_MINLEN bytes
        if (self.buf_len >= MATCH_MINLEN) {
            var h: u32 = 0x811C_9DC5;
            var k: usize = 0;
            while (k < MATCH_MINLEN) : (k += 1) h = (h ^ self.buf[self.buf_len - 1 - k]) *% 0x0100_0193;
            const slot = h & (MATCH_HSIZE - 1);
            if (self.match_len == 0) {
                const cand = self.match_ht[slot];
                if (cand != 0 and cand <= self.buf_len) {
                    self.match_ptr = cand; // predict buf[cand] next
                    self.match_len = 1;
                }
            }
            self.match_ht[slot] = @intCast(self.buf_len); // position of next byte
        }

        self.refreshContexts();
    }
};

// ---- public API ------------------------------------------------------------

/// Compress `data` with the CM model. Returns owned bytes.
pub fn compress(data: []const u8, a: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    var pred = try Predictor.init(a, data.len);
    defer pred.deinit();
    var enc = Encoder{ .out = &out };

    for (data) |byte| {
        var b: u3 = 0;
        while (true) {
            const bit: u1 = @intCast((byte >> (7 - b)) & 1);
            const p = pred.predict();
            try enc.encode(bit, p);
            pred.update(bit);
            if (b == 7) break;
            b += 1;
        }
    }
    try enc.flush();
    return out.toOwnedSlice();
}

/// Decompress `comp` (CM stream) back to `orig_len` bytes. Returns owned bytes.
pub fn decompress(comp: []const u8, orig_len: usize, a: std.mem.Allocator) ![]u8 {
    const out = try a.alloc(u8, orig_len);
    errdefer a.free(out);
    var pred = try Predictor.init(a, orig_len);
    defer pred.deinit();
    var dec = Decoder.init(comp);

    var i: usize = 0;
    while (i < orig_len) : (i += 1) {
        var byte: u8 = 0;
        var b: u3 = 0;
        while (true) {
            const p = pred.predict();
            const bit = dec.decode(p);
            pred.update(bit);
            byte = (byte << 1) | bit;
            if (b == 7) break;
            b += 1;
        }
        out[i] = byte;
    }
    return out;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "CM round-trips exactly across content types" {
    const a = testing.allocator;
    var rng = @import("math_gen.zig").XorShift32.init(0xC11A);
    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();
    try buf.appendSlice("the quick brown fox jumps over the lazy dog. " ** 200);
    var i: usize = 0;
    while (i < 3000) : (i += 1) try buf.append(@truncate(i / 5));
    while (i < 6000) : (i += 1) try buf.append(rng.nextByte());

    const comp = try compress(buf.items, a);
    defer a.free(comp);
    const back = try decompress(comp, buf.items.len, a);
    defer a.free(back);
    try testing.expectEqualSlices(u8, buf.items, back);
    // on the compressible prefix it must shrink
    try testing.expect(comp.len < buf.items.len);
}

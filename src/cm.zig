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

// Bit-history state machine (indirect context model). A state is a bounded
// (n0,n1) pair — counts of 0/1 bits seen in a context, with the opposite count
// discounted on a flip so the model tracks NONSTATIONARY data (runs, recency).
// state = n0*16 + n1 (n0,n1 in 0..15). A StateMap then maps state -> probability.
// This is what a flat per-context counter can't capture, and it's the lever that
// lets CM rival LZMA on binary code.
var trans: [256][2]u8 = undefined;
var trans_ready = false;
fn initTrans() void {
    if (trans_ready) return;
    var n0: u32 = 0;
    while (n0 < 16) : (n0 += 1) {
        var n1: u32 = 0;
        while (n1 < 16) : (n1 += 1) {
            const s: usize = n0 * 16 + n1;
            // observe a 0:
            const a0: u32 = @min(n0 + 1, 15);
            var a1: u32 = n1;
            if (a1 > 2) a1 = a1 / 2 + 1;
            trans[s][0] = @intCast(a0 * 16 + a1);
            // observe a 1:
            const b1: u32 = @min(n1 + 1, 15);
            var b0: u32 = n0;
            if (b0 > 2) b0 = b0 / 2 + 1;
            trans[s][1] = @intCast(b0 * 16 + b1);
        }
    }
    trans_ready = true;
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

// Context orders hashed from the full history buffer (0 = sparse skip-gram).
// More/deeper orders help binary; CM is cold-only so the memory (16 MB/table)
// is fine. Order hashes come from `buf`, so they're not capped at 8 bytes.
const WORD: u32 = 0xFFFF_FFFF; // sentinel: a word-context model (alnum/_ run), not an order-k history
const WORD2: u32 = 0xFFFF_FFFE; // sentinel: previous-word + current-word context (text/code structure)
const orders = [_]u32{ 1, 2, 3, 4, 6, 8, 12, 16, 0, WORD, WORD2 };
const NUM_ORDERS = orders.len;
const TBITS = 22; // 4M entries per model table (16 MB)
const TSIZE = 1 << TBITS;
const TMASK = TSIZE - 1;
const NMATCH = 2; // two match models: short-range and long-range
const match_min = [NMATCH]u32{ 4, 8 }; // bytes hashed to seed each
const MATCH_HBITS = 22;
const MATCH_HSIZE = 1 << MATCH_HBITS;
const NINPUTS = NUM_ORDERS + NMATCH + 1; // orders + matches + bias
const NMIXCTX = 2048; // mixer weight sets: (match bucket << 8) | last byte

const MatchState = struct {
    ht: []u32,
    ptr: usize = 0,
    len: u32 = 0,
    sm: []u32, // learned confidence: P(bit=1 | len bucket, predicted bit)
    ctx: usize = 0,
    used: bool = false,
};

const Predictor = struct {
    a: std.mem.Allocator,

    // indirect context models: per-context bit-history STATE (u8), then a shared
    // per-model StateMap maps state -> probability (count-adaptive).
    tables: [NUM_ORDERS][]u8,
    model_sm: [NUM_ORDERS][]u32,
    ctxhash: [NUM_ORDERS]u32 = [_]u32{0} ** NUM_ORDERS,
    cur_idx: [NUM_ORDERS]usize = [_]usize{0} ** NUM_ORDERS,
    cur_state: [NUM_ORDERS]u8 = [_]u8{0} ** NUM_ORDERS,

    // partial-byte state
    c0: u32 = 1, // 1-prefixed bits of current byte
    bitpos: u5 = 0,
    last_byte: u8 = 0,
    word_hash: u32 = 0, // rolling hash of the current word (alnum/_ run), reset on a separator
    prev_word: u32 = 0, // hash of the last completed word (for the word-pair context)

    // history buffer (context hashing + match models)
    buf: []u8,
    buf_len: usize = 0,

    match: [NMATCH]MatchState,

    // mixer
    weights: []i32,
    mix_ctx: usize = 0,
    inputs: [NINPUTS]i32 = [_]i32{0} ** NINPUTS,
    mixed_p: u32 = 2048,

    // SSE
    apm1: APM,
    apm2: APM,
    final_p: u32 = 2048,

    fn init(a: std.mem.Allocator, max_len: usize) !Predictor {
        initStretch();
        initDt();
        initTrans();
        var p = Predictor{
            .a = a,
            .tables = undefined,
            .model_sm = undefined,
            .buf = try a.alloc(u8, @max(max_len, 1)),
            .match = undefined,
            .weights = try a.alloc(i32, NMIXCTX * NINPUTS),
            .apm1 = try APM.init(a, 256),
            .apm2 = try APM.init(a, 0x10000),
        };
        for (&p.tables) |*t| {
            t.* = try a.alloc(u8, TSIZE);
            @memset(t.*, 0); // state (0,0)
        }
        for (&p.model_sm) |*sm| {
            sm.* = try a.alloc(u32, 256); // state -> probability
            @memset(sm.*, 1 << 31);
        }
        for (&p.match) |*m| {
            m.* = .{ .ht = try a.alloc(u32, MATCH_HSIZE), .sm = try a.alloc(u32, 256) };
            @memset(m.ht, 0);
            @memset(m.sm, 1 << 31);
        }
        @memset(p.weights, 0);
        return p;
    }

    fn deinit(self: *Predictor) void {
        for (self.tables) |t| self.a.free(t);
        for (self.model_sm) |sm| self.a.free(sm);
        for (self.match) |m| {
            self.a.free(m.ht);
            self.a.free(m.sm);
        }
        self.a.free(self.buf);
        self.a.free(self.weights);
        self.apm1.deinit();
        self.apm2.deinit();
    }

    /// Recompute per-order base context hashes from the history buffer.
    fn refreshContexts(self: *Predictor) void {
        const L = self.buf_len;
        for (orders, 0..) |k, i| {
            if (k == 0) {
                // sparse skip-gram: bytes at lag 2 and 4
                const b2: u32 = if (L >= 2) self.buf[L - 2] else 0;
                const b4: u32 = if (L >= 4) self.buf[L - 4] else 0;
                self.ctxhash[i] = (b2 *% 0x9E37_79B1) ^ (b4 *% 0x85EB_CA6B) ^ 0x1234_5678;
            } else if (k == WORD) {
                // word-context model: predict from the whole current word (great for text + identifiers)
                self.ctxhash[i] = (self.word_hash *% 0x9E37_79B1) ^ 0xABCD_1234;
            } else if (k == WORD2) {
                // word-pair: previous completed word + current word prefix (language/structure model)
                self.ctxhash[i] = (self.prev_word *% 0x85EB_CA6B) ^ (self.word_hash *% 0xC2B2_AE35) ^ 0x55AA_33CC;
            } else {
                var h: u32 = 0x811C_9DC5 +% k *% 0x9E37_79B1;
                var j: u32 = 0;
                while (j < k and j < L) : (j += 1) h = (h ^ self.buf[L - 1 - j]) *% 0x0100_0193;
                self.ctxhash[i] = h;
            }
        }
    }

    /// Predict P(next bit = 1) as a 12-bit value.
    fn predict(self: *Predictor) u32 {
        var ni: usize = 0;
        for (0..NUM_ORDERS) |i| {
            const idx: usize = (@as(usize, self.ctxhash[i] ^ (self.c0 *% 0x6F4A_7C15)) & TMASK);
            self.cur_idx[i] = idx;
            const state = self.tables[i][idx];
            self.cur_state[i] = state;
            const p12: i32 = smPredict12(self.model_sm[i][state]);
            self.inputs[ni] = stretch(@intCast(clampP(p12)));
            ni += 1;
        }

        // match model inputs: predict next bit from each matched byte (while the
        // bits coded so far this byte still agree), read a LEARNED probability
        // keyed by (length bucket, predicted bit). The longest match drives the
        // mixer's weight-set selection.
        var mbucket: usize = 0;
        const bp: u32 = self.bitpos;
        for (&self.match) |*m| {
            m.used = false;
            var in: i32 = 0;
            if (m.len > 0 and m.ptr < self.buf_len) {
                const pbyte: u32 = self.buf[m.ptr];
                const top: u32 = if (bp == 0) 0 else (pbyte >> @as(u5, @intCast(8 - bp)));
                const expected: u32 = (@as(u32, 1) << @as(u5, @intCast(bp))) | top;
                if (expected == self.c0) {
                    m.used = true;
                    const sh: u5 = @intCast(7 - bp);
                    const pb: u1 = @intCast((pbyte >> sh) & 1);
                    const lb: usize = @intCast(@min(m.len, @as(u32, 63)));
                    m.ctx = (lb << 1) | @as(usize, pb);
                    in = stretch(@intCast(clampP(smPredict12(m.sm[m.ctx]))));
                    mbucket = @max(mbucket, @min(m.len, @as(u32, 7)));
                }
            }
            self.inputs[ni] = in;
            ni += 1;
        }
        self.inputs[ni] = 256; // bias
        ni += 1;

        self.mix_ctx = ((mbucket << 8) | self.last_byte) & (NMIXCTX - 1);
        const w = self.weights[self.mix_ctx * NINPUTS ..][0..NINPUTS];
        var dot: i64 = 0;
        for (0..NINPUTS) |k| dot += @as(i64, w[k]) * @as(i64, self.inputs[k]);
        var pm: i32 = @intCast(@as(i64, @intCast(dot)) >> 16);
        if (pm < -2047) pm = -2047;
        if (pm > 2047) pm = 2047;
        self.mixed_p = clampP(squash(pm));

        const p1 = self.apm1.pp(@intCast(self.mixed_p), self.last_byte);
        const p2 = self.apm2.pp(@intCast(self.mixed_p), self.c0 & 0xFFFF);
        const pf = (@as(i32, @intCast(self.mixed_p)) + p1 + 2 * p2) >> 2;
        self.final_p = clampP(pf);
        return self.final_p;
    }

    fn update(self: *Predictor, bit: u1) void {
        // calibrate each model's state->prob map, then advance the per-context state
        for (0..NUM_ORDERS) |i| {
            smUpdate(self.model_sm[i], self.cur_state[i], bit);
            self.tables[i][self.cur_idx[i]] = trans[self.cur_state[i]][bit];
        }
        for (&self.match) |*m| if (m.used) smUpdate(m.sm, m.ctx, bit);

        const err: i32 = (@as(i32, bit) << 12) - @as(i32, @intCast(self.mixed_p));
        const w = self.weights[self.mix_ctx * NINPUTS ..][0..NINPUTS];
        for (0..NINPUTS) |k| w[k] += (self.inputs[k] * err) >> 10;

        self.apm1.update(bit, 7);
        self.apm2.update(bit, 7);

        self.c0 = (self.c0 << 1) | bit;
        self.bitpos += 1;
        if (self.bitpos == 8) {
            self.byteBoundary(@truncate(self.c0));
            self.c0 = 1;
            self.bitpos = 0;
        }
    }

    fn byteBoundary(self: *Predictor, byte: u8) void {
        // extend each match if it predicted this byte, else drop it
        for (&self.match) |*m| {
            if (m.len > 0 and m.ptr < self.buf_len and self.buf[m.ptr] == byte) {
                m.ptr += 1;
                m.len +%= 1;
            } else {
                m.len = 0;
            }
        }

        if (self.buf_len < self.buf.len) {
            self.buf[self.buf_len] = byte;
            self.buf_len += 1;
        }
        self.last_byte = byte;

        // re-seed each match model from a hash of its last `min` bytes
        for (&self.match, 0..) |*m, k| {
            const minlen = match_min[k];
            if (self.buf_len >= minlen) {
                var h: u32 = 0x811C_9DC5 +% @as(u32, @intCast(k)) *% 0x9E37_79B1;
                var j: u32 = 0;
                while (j < minlen) : (j += 1) h = (h ^ self.buf[self.buf_len - 1 - j]) *% 0x0100_0193;
                const slot = h & (MATCH_HSIZE - 1);
                if (m.len == 0) {
                    const cand = m.ht[slot];
                    if (cand != 0 and cand < self.buf_len) {
                        m.ptr = cand;
                        m.len = 1;
                    }
                }
                m.ht[slot] = @intCast(self.buf_len);
            }
        }

        // word model: extend the rolling word hash on alnum/_; on a separator, retire the word to prev_word
        const wc = (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_';
        if (wc) {
            self.word_hash = (self.word_hash *% 0x6F4A_7C15) +% byte +% 1;
        } else {
            if (self.word_hash != 0) self.prev_word = self.word_hash;
            self.word_hash = 0;
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

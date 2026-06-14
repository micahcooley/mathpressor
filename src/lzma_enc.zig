//! lzma_enc.zig — a from-scratch, pure-Zig LZMA1 encoder.
//!
//! WHY THIS EXISTS: on truly-opaque data (a monolithic game pak), full mode's
//! only loss to 7-Zip is that liblzma's optimal parser is ~0.3% weaker than the
//! LZMA SDK's. liblzma's encoder is a black box we can't improve; 7-Zip's is C++
//! we won't vendor (pure-Zig constraint). The only way to close that last gap is
//! our own LZMA encoder whose parse we control — this module. Output is the
//! standard LZMA stream, so DECODE is free (liblzma / our RangeDecoder reads it).
//!
//! STATUS: correct greedy+lazy parse (this file) — produces bit-exact,
//! liblzma-decodable .lzma. It matches liblzma's *fast* modes, not yet 9e: the
//! ratio win over 7-Zip needs the OPTIMAL parse (cost-model forward DP), which
//! is the next layer built on these exact-format primitives. Verified by
//! decoding our output with `xz -d --format=lzma`.
//!
//! Reference: the LZMA specification (lzma.txt, Igor Pavlov) — array sizes,
//! probability layout, state machine and slot coding follow it exactly so the
//! reference decoder accepts the stream.

const std = @import("std");

// ---- range-coder constants (shared with bcj2.zig's coder) ------------------
const kTopValue: u32 = 1 << 24;
const kNumBitModelTotalBits: u5 = 11;
const kBitModelTotal: u32 = 1 << 11;
const kNumMoveBits: u5 = 5;
const kProbInit: u16 = kBitModelTotal / 2;

// ---- LZMA structural constants ---------------------------------------------
const kNumStates = 12;
const kNumPosBitsMax = 4;
const kNumLenToPosStates = 4;
const kNumAlignBits = 4;
const kAlignTableSize = 1 << kNumAlignBits;
const kStartPosModelIndex = 4;
const kEndPosModelIndex = 14;
const kNumFullDistances = 1 << (kEndPosModelIndex >> 1); // 128
const kMatchMinLen = 2;
const kMatchMaxLen = 273;
const kNumLenSymbols = 256 + 16; // low(8)+mid(8)+high(256)

// ---- adaptive bit probability ----------------------------------------------
inline fn updProb0(p: *u16) void {
    p.* += @intCast((kBitModelTotal - p.*) >> kNumMoveBits);
}
inline fn updProb1(p: *u16) void {
    p.* -= @intCast(p.* >> kNumMoveBits);
}

// ---- price model (bit-costs in 1/16-bit units) -----------------------------
// The optimal parser needs the *cost* of each coding choice, not just to make
// it. Prices come from the standard LZMA ProbPrices table (LzmaEnc.c).
const kNumMoveReducingBits = 2;
const kNumBitPriceShiftBits = 4;
const kBitPrice: u32 = 1 << kNumBitPriceShiftBits; // a full bit = 16 units

var prob_prices: [kBitModelTotal >> kNumMoveReducingBits]u32 = undefined;
var prices_ready = false;
fn initPrices() void {
    if (prices_ready) return;
    var i: u32 = 0;
    while (i < kBitModelTotal) : (i += (1 << kNumMoveReducingBits)) {
        var w: u32 = i;
        var bit_count: u32 = 0;
        var j: u32 = 0;
        while (j < kNumBitPriceShiftBits) : (j += 1) {
            w = w *% w;
            bit_count <<= 1;
            while (w >= (1 << 16)) {
                w >>= 1;
                bit_count += 1;
            }
        }
        prob_prices[i >> kNumMoveReducingBits] =
            (@as(u32, kNumBitModelTotalBits) << kNumBitPriceShiftBits) - 15 - bit_count;
    }
    prices_ready = true;
}

inline fn priceBit(prob: u16, bit: u1) u32 {
    const idx = if (bit == 0) prob >> kNumMoveReducingBits else (kBitModelTotal - prob) >> kNumMoveReducingBits;
    return prob_prices[idx];
}

fn priceTree(probs: []const u16, num_bits: u6, symbol: u32) u32 {
    var price: u32 = 0;
    var m: u32 = 1;
    var i: u6 = num_bits;
    while (i != 0) {
        i -= 1;
        const bit: u1 = @intCast((symbol >> @intCast(i)) & 1);
        price += priceBit(probs[m], bit);
        m = (m << 1) | bit;
    }
    return price;
}

fn priceTreeReverse(probs: []const u16, num_bits: u6, symbol_in: u32) u32 {
    var price: u32 = 0;
    var m: u32 = 1;
    var symbol = symbol_in;
    var i: u6 = 0;
    while (i < num_bits) : (i += 1) {
        const bit: u1 = @intCast(symbol & 1);
        symbol >>= 1;
        price += priceBit(probs[m], bit);
        m = (m << 1) | bit;
    }
    return price;
}

fn priceLiteral(probs: []const u16, symbol: u8, match_byte: u8, matched: bool) u32 {
    var price: u32 = 0;
    var ctx: u32 = 1;
    var i: u8 = 8;
    if (!matched) {
        while (i != 0) {
            i -= 1;
            const sh: u3 = @intCast(i);
            const bit: u1 = @intCast((symbol >> sh) & 1);
            price += priceBit(probs[ctx], bit);
            ctx = (ctx << 1) | bit;
        }
    } else {
        var same = true;
        while (i != 0) {
            i -= 1;
            const sh: u3 = @intCast(i);
            const lit_bit: u1 = @intCast((symbol >> sh) & 1);
            if (same) {
                const m_bit: u1 = @intCast((match_byte >> sh) & 1);
                const off: u32 = (@as(u32, m_bit) + 1) << 8;
                price += priceBit(probs[off + ctx], lit_bit);
                ctx = (ctx << 1) | lit_bit;
                if (m_bit != lit_bit) same = false;
            } else {
                price += priceBit(probs[ctx], lit_bit);
                ctx = (ctx << 1) | lit_bit;
            }
        }
    }
    return price;
}

inline fn litNextState(state: u32) u32 {
    return if (state < 4) 0 else if (state < 10) state - 3 else state - 6;
}
inline fn matchNextState(state: u32) u32 {
    return if (state < 7) 7 else 10;
}
inline fn repNextState(state: u32) u32 {
    return if (state < 7) 8 else 11;
}
inline fn shortRepNextState(state: u32) u32 {
    return if (state < 7) 9 else 11;
}

const RangeEncoder = struct {
    low: u64 = 0,
    range: u32 = 0xFFFF_FFFF,
    cache: u8 = 0,
    cache_size: u64 = 1,
    out: *std.ArrayList(u8),

    fn shiftLow(self: *RangeEncoder) !void {
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

    inline fn normalize(self: *RangeEncoder) !void {
        while (self.range < kTopValue) {
            self.range <<= 8;
            try self.shiftLow();
        }
    }

    fn encodeBit(self: *RangeEncoder, prob: *u16, bit: u1) !void {
        const bound = (self.range >> kNumBitModelTotalBits) * prob.*;
        if (bit == 0) {
            self.range = bound;
            updProb0(prob);
        } else {
            self.low += bound;
            self.range -= bound;
            updProb1(prob);
        }
        try self.normalize();
    }

    fn encodeDirectBits(self: *RangeEncoder, value: u32, num_bits: u6) !void {
        var i: u6 = num_bits;
        while (i != 0) {
            i -= 1;
            self.range >>= 1;
            const b: u32 = (value >> @intCast(i)) & 1;
            // low += range if bit set
            self.low += self.range & (0 -% b);
            try self.normalize();
        }
    }

    /// MSB-first bit tree (probs is the tree array; index 0 unused, m starts 1).
    fn encodeBitTree(self: *RangeEncoder, probs: []u16, num_bits: u6, symbol: u32) !void {
        var m: u32 = 1;
        var i: u6 = num_bits;
        while (i != 0) {
            i -= 1;
            const bit: u1 = @intCast((symbol >> @intCast(i)) & 1);
            try self.encodeBit(&probs[m], bit);
            m = (m << 1) | bit;
        }
    }

    /// LSB-first reverse bit tree (used for the align bits + spec distances).
    fn encodeBitTreeReverse(self: *RangeEncoder, probs: []u16, num_bits: u6, symbol_in: u32) !void {
        var m: u32 = 1;
        var symbol = symbol_in;
        var i: u6 = 0;
        while (i < num_bits) : (i += 1) {
            const bit: u1 = @intCast(symbol & 1);
            symbol >>= 1;
            try self.encodeBit(&probs[m], bit);
            m = (m << 1) | bit;
        }
    }

    fn flush(self: *RangeEncoder) !void {
        var i: usize = 0;
        while (i < 5) : (i += 1) try self.shiftLow();
    }
};

// ---- length coder ----------------------------------------------------------
const LenCoder = struct {
    choice: u16 = kProbInit,
    choice2: u16 = kProbInit,
    low: [1 << kNumPosBitsMax][8]u16 = [_][8]u16{[_]u16{kProbInit} ** 8} ** (1 << kNumPosBitsMax),
    mid: [1 << kNumPosBitsMax][8]u16 = [_][8]u16{[_]u16{kProbInit} ** 8} ** (1 << kNumPosBitsMax),
    high: [256]u16 = [_]u16{kProbInit} ** 256,

    /// len_index = matchLen - kMatchMinLen (0-based).
    fn encode(self: *LenCoder, rc: *RangeEncoder, len_index: u32, pos_state: u32) !void {
        if (len_index < 8) {
            try rc.encodeBit(&self.choice, 0);
            try rc.encodeBitTree(self.low[pos_state][0..], 3, len_index);
        } else {
            try rc.encodeBit(&self.choice, 1);
            const l = len_index - 8;
            if (l < 8) {
                try rc.encodeBit(&self.choice2, 0);
                try rc.encodeBitTree(self.mid[pos_state][0..], 3, l);
            } else {
                try rc.encodeBit(&self.choice2, 1);
                try rc.encodeBitTree(self.high[0..], 8, l - 8);
            }
        }
    }

    fn price(self: *const LenCoder, len_index: u32, pos_state: u32) u32 {
        if (len_index < 8) {
            return priceBit(self.choice, 0) + priceTree(self.low[pos_state][0..], 3, len_index);
        }
        const l = len_index - 8;
        if (l < 8) {
            return priceBit(self.choice, 1) + priceBit(self.choice2, 0) +
                priceTree(self.mid[pos_state][0..], 3, l);
        }
        return priceBit(self.choice, 1) + priceBit(self.choice2, 1) +
            priceTree(self.high[0..], 8, l - 8);
    }
};

// ---- the encoder -----------------------------------------------------------
const Match = struct { len: u32, dist: u32 }; // dist is the true distance (>=1)

pub const Options = struct {
    lc: u4 = 3,
    lp: u4 = 0,
    pb: u4 = 2,
    dict_size: u32 = 1 << 26, // 64 MiB
    nice_len: u32 = 64,
    max_depth: u32 = 96,
};

const Encoder = struct {
    a: std.mem.Allocator,
    opt: Options,

    // probability models
    is_match: [kNumStates << kNumPosBitsMax]u16 = [_]u16{kProbInit} ** (kNumStates << kNumPosBitsMax),
    is_rep: [kNumStates]u16 = [_]u16{kProbInit} ** kNumStates,
    is_rep_g0: [kNumStates]u16 = [_]u16{kProbInit} ** kNumStates,
    is_rep_g1: [kNumStates]u16 = [_]u16{kProbInit} ** kNumStates,
    is_rep_g2: [kNumStates]u16 = [_]u16{kProbInit} ** kNumStates,
    is_rep0_long: [kNumStates << kNumPosBitsMax]u16 = [_]u16{kProbInit} ** (kNumStates << kNumPosBitsMax),
    pos_slot: [kNumLenToPosStates][1 << 6]u16 = [_][1 << 6]u16{[_]u16{kProbInit} ** (1 << 6)} ** kNumLenToPosStates,
    spec_pos: [kNumFullDistances - kEndPosModelIndex]u16 = [_]u16{kProbInit} ** (kNumFullDistances - kEndPosModelIndex),
    align_probs: [kAlignTableSize]u16 = [_]u16{kProbInit} ** kAlignTableSize,
    len_coder: LenCoder = .{},
    rep_len_coder: LenCoder = .{},
    literal: []u16, // 0x300 << (lc+lp)

    // state
    state: u32 = 0,
    reps: [4]u32 = .{ 0, 0, 0, 0 }, // 0-based distances (true distance - 1)

    // match finder: hash-4 chains for >=4-byte matches.
    head: []i32,
    chain: []i32,
    hash_mask: u32,

    fn posSlot(dist: u32) u32 {
        if (dist < kStartPosModelIndex) return dist;
        const n: u32 = 31 - @as(u32, @clz(dist)); // index of the top set bit
        const sh: u5 = @intCast(n - 1);
        return (n << 1) | ((dist >> sh) & 1);
    }

    fn encodeDistance(self: *Encoder, rc: *RangeEncoder, dist0: u32, len: u32) !void {
        const len_state = @min(len - kMatchMinLen, kNumLenToPosStates - 1);
        const slot = posSlot(dist0);
        try rc.encodeBitTree(self.pos_slot[len_state][0..], 6, slot);
        if (slot >= kStartPosModelIndex) {
            const footer_bits: u6 = @intCast((slot >> 1) - 1);
            const base: u32 = (2 | (slot & 1)) << @as(u5, @intCast(footer_bits));
            const reduced = dist0 - base;
            if (slot < kEndPosModelIndex) {
                // spec_pos is offset by (base - slot); index 0 of the tree (m) starts at 1.
                const off = base - slot;
                try rc.encodeBitTreeReverse(self.spec_pos[off..], footer_bits, reduced);
            } else {
                try rc.encodeDirectBits(reduced >> kNumAlignBits, footer_bits - kNumAlignBits);
                try rc.encodeBitTreeReverse(self.align_probs[0..], kNumAlignBits, reduced & (kAlignTableSize - 1));
            }
        }
    }

    fn priceDistance(self: *const Encoder, dist0: u32, len: u32) u32 {
        const len_state = @min(len - kMatchMinLen, kNumLenToPosStates - 1);
        const slot = posSlot(dist0);
        var p = priceTree(self.pos_slot[len_state][0..], 6, slot);
        if (slot >= kStartPosModelIndex) {
            const footer_bits: u6 = @intCast((slot >> 1) - 1);
            const base: u32 = (2 | (slot & 1)) << @as(u5, @intCast(footer_bits));
            const reduced = dist0 - base;
            if (slot < kEndPosModelIndex) {
                const off = base - slot;
                p += priceTreeReverse(self.spec_pos[off..], footer_bits, reduced);
            } else {
                p += (@as(u32, footer_bits) - kNumAlignBits) * kBitPrice;
                p += priceTreeReverse(self.align_probs[0..], kNumAlignBits, reduced & (kAlignTableSize - 1));
            }
        }
        return p;
    }

    /// Fill `out` with (len, dist) pairs: for each achievable length the best
    /// (smallest) distance, lengths strictly increasing. Inserts `pos` into the
    /// match finder. Returns the number of pairs written.
    fn getMatches(self: *Encoder, data: []const u8, pos: usize, out: []Match) usize {
        var n: usize = 0;
        if (pos + 4 > data.len) {
            self.insert(data, pos);
            return 0;
        }
        const max_len = @min(@as(u32, kMatchMaxLen), @as(u32, @intCast(data.len - pos)));
        var best_len: u32 = kMatchMinLen - 1;
        const min_pos: i64 = @as(i64, @intCast(pos)) - @as(i64, @intCast(self.opt.dict_size));

        const h = hash4(data, pos, self.hash_mask);
        var cur = self.head[h];
        var depth: u32 = 0;
        while (cur >= 0 and @as(i64, cur) >= min_pos and depth < self.opt.max_depth) : (depth += 1) {
            const src: usize = @intCast(cur);
            if (best_len < max_len and data[src + best_len] == data[pos + best_len]) {
                var l: u32 = 0;
                while (l < max_len and data[src + l] == data[pos + l]) l += 1;
                if (l > best_len) {
                    out[n] = .{ .len = l, .dist = @intCast(pos - src) };
                    n += 1;
                    best_len = l;
                    if (l >= max_len or n >= out.len) break;
                }
            }
            cur = self.chain[src];
        }
        self.insert(data, pos);
        return n;
    }

    fn litProbs(self: *Encoder, pos: usize, prev: u8) []u16 {
        const lp_mask: u32 = (@as(u32, 1) << self.opt.lp) - 1;
        const lc = self.opt.lc;
        const idx = 0x300 * (((@as(u32, @intCast(pos)) & lp_mask) << lc) + (@as(u32, prev) >> @intCast(8 - lc)));
        return self.literal[idx..][0..0x300];
    }

    fn encodeLiteral(_: *Encoder, rc: *RangeEncoder, probs: []u16, symbol: u8, match_byte: u8, matched: bool) !void {
        var ctx: u32 = 1;
        if (!matched) {
            var i: u8 = 8;
            while (i != 0) {
                i -= 1;
                const sh: u3 = @intCast(i);
                const bit: u1 = @intCast((symbol >> sh) & 1);
                try rc.encodeBit(&probs[ctx], bit);
                ctx = (ctx << 1) | bit;
            }
        } else {
            var same = true;
            var i: u8 = 8;
            while (i != 0) {
                i -= 1;
                const sh: u3 = @intCast(i);
                const lit_bit: u1 = @intCast((symbol >> sh) & 1);
                if (same) {
                    const m_bit: u1 = @intCast((match_byte >> sh) & 1);
                    const off: u32 = (@as(u32, m_bit) + 1) << 8;
                    try rc.encodeBit(&probs[off + ctx], lit_bit);
                    ctx = (ctx << 1) | lit_bit;
                    if (m_bit != lit_bit) same = false;
                } else {
                    try rc.encodeBit(&probs[ctx], lit_bit);
                    ctx = (ctx << 1) | lit_bit;
                }
            }
        }
    }

    // --- match finder (hash-4 chains) ---
    fn hash4(data: []const u8, i: usize, mask: u32) u32 {
        const v = (@as(u32, data[i]) | (@as(u32, data[i + 1]) << 8) |
            (@as(u32, data[i + 2]) << 16) | (@as(u32, data[i + 3]) << 24));
        return (v *% 2654435761) >> 8 & mask;
    }
    inline fn hash2(data: []const u8, i: usize) u32 {
        return @as(u32, data[i]) | (@as(u32, data[i + 1]) << 8);
    }
    inline fn hash3(data: []const u8, i: usize) u32 {
        const v = @as(u32, data[i]) | (@as(u32, data[i + 1]) << 8) | (@as(u32, data[i + 2]) << 16);
        return (v *% 2654435761) >> 16 & 0xFFFF;
    }

    fn findMatch(self: *Encoder, data: []const u8, pos: usize) Match {
        var best = Match{ .len = 0, .dist = 0 };
        if (pos + 4 > data.len) return best;
        const limit = data.len;
        const max_len = @min(@as(u32, kMatchMaxLen), @as(u32, @intCast(limit - pos)));
        // 1) try the recent reps first (cheap, and rep matches code shorter)
        for (self.reps) |r| {
            const dist = r + 1;
            if (dist > pos) continue;
            const src = pos - dist;
            var l: u32 = 0;
            while (l < max_len and data[src + l] == data[pos + l]) l += 1;
            if (l >= 2 and l > best.len) best = .{ .len = l, .dist = dist };
        }
        // 2) hash-chain search for longer/closer literal matches
        const h = hash4(data, pos, self.hash_mask);
        var cur = self.head[h];
        var depth: u32 = 0;
        const min_pos: i64 = @as(i64, @intCast(pos)) - @as(i64, @intCast(self.opt.dict_size));
        while (cur >= 0 and @as(i64, cur) >= min_pos and depth < self.opt.max_depth) : (depth += 1) {
            const src: usize = @intCast(cur);
            // quick reject: must beat current best at best.len
            if (best.len > 0 and best.len < max_len and data[src + best.len] != data[pos + best.len]) {
                cur = self.chain[src];
                continue;
            }
            var l: u32 = 0;
            while (l < max_len and data[src + l] == data[pos + l]) l += 1;
            if (l > best.len) {
                best = .{ .len = l, .dist = @intCast(pos - src) };
                if (l >= self.opt.nice_len) break;
            }
            cur = self.chain[src];
        }
        return best;
    }

    fn insert(self: *Encoder, data: []const u8, pos: usize) void {
        if (pos + 4 > data.len) return;
        const h = hash4(data, pos, self.hash_mask);
        self.chain[pos] = self.head[h];
        self.head[h] = @intCast(pos);
    }

    fn repIndex(self: *Encoder, dist: u32) ?usize {
        const d0 = dist - 1;
        for (self.reps, 0..) |r, i| if (r == d0) return i;
        return null;
    }

    // --- emission helpers (no match-finder insert; used by the optimal parse,
    //     which inserts during the DP) ---
    fn emitLit(self: *Encoder, rc: *RangeEncoder, data: []const u8, pos: usize, pos_state: u32) !void {
        const idx = (self.state << kNumPosBitsMax) + pos_state;
        try rc.encodeBit(&self.is_match[idx], 0);
        const prev: u8 = if (pos == 0) 0 else data[pos - 1];
        const probs = self.litProbs(pos, prev);
        if (self.state < 7) {
            try self.encodeLiteral(rc, probs, data[pos], 0, false);
        } else {
            try self.encodeLiteral(rc, probs, data[pos], data[pos - (self.reps[0] + 1)], true);
        }
        self.state = litNextState(self.state);
    }

    fn emitMatch(self: *Encoder, rc: *RangeEncoder, len: u32, dist: u32, pos_state: u32) !void {
        const idx = (self.state << kNumPosBitsMax) + pos_state;
        try rc.encodeBit(&self.is_match[idx], 1);
        const d0 = dist - 1;
        if (self.repIndex(dist)) |ri| {
            try rc.encodeBit(&self.is_rep[self.state], 1);
            if (ri == 0) {
                try rc.encodeBit(&self.is_rep_g0[self.state], 0);
                if (len == 1) {
                    try rc.encodeBit(&self.is_rep0_long[idx], 0);
                    self.state = shortRepNextState(self.state);
                    return;
                }
                try rc.encodeBit(&self.is_rep0_long[idx], 1);
            } else {
                try rc.encodeBit(&self.is_rep_g0[self.state], 1);
                if (ri == 1) {
                    try rc.encodeBit(&self.is_rep_g1[self.state], 0);
                } else {
                    try rc.encodeBit(&self.is_rep_g1[self.state], 1);
                    try rc.encodeBit(&self.is_rep_g2[self.state], @intCast(ri - 2));
                }
                const d = self.reps[ri];
                var k = ri;
                while (k > 0) : (k -= 1) self.reps[k] = self.reps[k - 1];
                self.reps[0] = d;
            }
            try self.rep_len_coder.encode(rc, len - kMatchMinLen, pos_state);
            self.state = repNextState(self.state);
        } else {
            try rc.encodeBit(&self.is_rep[self.state], 0);
            self.reps[3] = self.reps[2];
            self.reps[2] = self.reps[1];
            self.reps[1] = self.reps[0];
            self.reps[0] = d0;
            try self.len_coder.encode(rc, len - kMatchMinLen, pos_state);
            try self.encodeDistance(rc, d0, len);
            self.state = matchNextState(self.state);
        }
    }
};

// One node of the forward DP window. `dist == 0` means "literal"; otherwise this
// node was reached by a (len, dist) match (a shortrep is len==1, dist==rep0+1).
const OptNode = struct {
    price: u32,
    state: u32,
    reps: [4]u32,
    from: u32,
    len: u32,
    dist: u32,
};

/// Compress `data` to a standalone `.lzma` (LZMA_alone) buffer that liblzma /
/// `xz -d --format=lzma` decodes. Caller owns the returned slice.
pub fn compress(data: []const u8, a: std.mem.Allocator, opt_in: Options) ![]u8 {
    const opt = opt_in;
    if (opt.lc + opt.lp > 4) return error.BadParams; // liblzma constraint

    // hash table sized to the input (cap so tiny inputs stay cheap)
    var hbits: u5 = 16;
    while ((@as(u32, 1) << hbits) < data.len and hbits < 24) hbits += 1;
    const hsize = @as(u32, 1) << hbits;

    const lit_size: usize = @as(usize, 0x300) << @intCast(opt.lc + opt.lp);
    const literal = try a.alloc(u16, lit_size);
    defer a.free(literal);
    @memset(literal, kProbInit);

    const head = try a.alloc(i32, hsize);
    defer a.free(head);
    @memset(head, -1);
    const chain = try a.alloc(i32, @max(data.len, 1));
    defer a.free(chain);

    var enc = Encoder{
        .a = a,
        .opt = opt,
        .literal = literal,
        .head = head,
        .chain = chain,
        .hash_mask = hsize - 1,
    };

    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    // .lzma header: props byte, dict_size (LE32), uncompressed size (LE64).
    const props: u8 = @intCast((@as(u32, opt.pb) * 5 + opt.lp) * 9 + opt.lc);
    try out.append(props);
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], opt.dict_size, .little);
    std.mem.writeInt(u64, hdr[4..12], data.len, .little);
    try out.appendSlice(&hdr);

    var rc = RangeEncoder{ .out = &out };
    const pb_mask: u32 = (@as(u32, 1) << opt.pb) - 1;

    var pos: usize = 0;
    while (pos < data.len) {
        const pos_state = @as(u32, @intCast(pos)) & pb_mask;
        const is_match_idx = (enc.state << kNumPosBitsMax) + pos_state;

        // current match, and a one-step-ahead match for lazy evaluation.
        const m = enc.findMatch(data, pos);
        // never emit a match in the last byte etc.; ensure within bounds
        if (m.len >= 2 and pos + m.len <= data.len) {
            // lazy: if the next position has a strictly longer match, defer.
            if (m.len < enc.opt.nice_len and pos + 1 < data.len) {
                enc.insert(data, pos);
                const m2 = enc.findMatch(data, pos + 1);
                // undo the insert's effect on subsequent logic by continuing;
                // (insert is idempotent for correctness — chain just has pos now)
                if (m2.len > m.len) {
                    // emit a literal at pos, advance by 1
                    const prev: u8 = if (pos == 0) 0 else data[pos - 1];
                    try rc.encodeBit(&enc.is_match[is_match_idx], 0);
                    const probs = enc.litProbs(pos, prev);
                    if (enc.state < 7) {
                        try enc.encodeLiteral(&rc, probs, data[pos], 0, false);
                    } else {
                        const mb = data[pos - (enc.reps[0] + 1)];
                        try enc.encodeLiteral(&rc, probs, data[pos], mb, true);
                    }
                    enc.state = if (enc.state < 4) 0 else if (enc.state < 10) enc.state - 3 else enc.state - 6;
                    pos += 1;
                    continue;
                }
            } else {
                enc.insert(data, pos);
            }

            // emit the match
            try rc.encodeBit(&enc.is_match[is_match_idx], 1);
            const len = m.len;
            if (enc.repIndex(m.dist)) |ri| {
                // rep match
                try rc.encodeBit(&enc.is_rep[enc.state], 1);
                if (ri == 0) {
                    try rc.encodeBit(&enc.is_rep_g0[enc.state], 0);
                    try rc.encodeBit(&enc.is_rep0_long[is_match_idx], 1); // len>=2
                } else {
                    try rc.encodeBit(&enc.is_rep_g0[enc.state], 1);
                    if (ri == 1) {
                        try rc.encodeBit(&enc.is_rep_g1[enc.state], 0);
                    } else {
                        try rc.encodeBit(&enc.is_rep_g1[enc.state], 1);
                        try rc.encodeBit(&enc.is_rep_g2[enc.state], @intCast(ri - 2));
                    }
                    // move-to-front the reps
                    const d = enc.reps[ri];
                    var k = ri;
                    while (k > 0) : (k -= 1) enc.reps[k] = enc.reps[k - 1];
                    enc.reps[0] = d;
                }
                try enc.rep_len_coder.encode(&rc, len - kMatchMinLen, pos_state);
                enc.state = if (enc.state < 7) 8 else 11;
            } else {
                // new distance
                try rc.encodeBit(&enc.is_rep[enc.state], 0);
                enc.reps[3] = enc.reps[2];
                enc.reps[2] = enc.reps[1];
                enc.reps[1] = enc.reps[0];
                enc.reps[0] = m.dist - 1;
                try enc.len_coder.encode(&rc, len - kMatchMinLen, pos_state);
                try enc.encodeDistance(&rc, m.dist - 1, len);
                enc.state = if (enc.state < 7) 7 else 10;
            }
            // insert the covered positions into the match finder
            var k: usize = 1;
            while (k < len) : (k += 1) enc.insert(data, pos + k);
            pos += len;
        } else {
            // literal
            try rc.encodeBit(&enc.is_match[is_match_idx], 0);
            const prev: u8 = if (pos == 0) 0 else data[pos - 1];
            const probs = enc.litProbs(pos, prev);
            if (enc.state < 7) {
                try enc.encodeLiteral(&rc, probs, data[pos], 0, false);
            } else {
                const mb = data[pos - (enc.reps[0] + 1)];
                try enc.encodeLiteral(&rc, probs, data[pos], mb, true);
            }
            enc.state = if (enc.state < 4) 0 else if (enc.state < 10) enc.state - 3 else enc.state - 6;
            enc.insert(data, pos);
            pos += 1;
        }
    }

    try rc.flush();
    return out.toOwnedSlice();
}

/// Optimal-parse compressor: a windowed forward DP over the price model picks
/// the minimum-cost sequence of literals / matches / rep-matches, instead of the
/// greedy `compress` above. This is what lifts ratio from "fast preset" class to
/// "9e" class and is the path to beating 7-Zip. Output is identical-format
/// standard .lzma (liblzma-decodable).
pub fn compressOpt(data: []const u8, a: std.mem.Allocator, opt_in: Options) ![]u8 {
    initPrices();
    const opt = opt_in;
    if (opt.lc + opt.lp > 4) return error.BadParams;

    var hbits: u5 = 16;
    while ((@as(u32, 1) << hbits) < data.len and hbits < 24) hbits += 1;
    const hsize = @as(u32, 1) << hbits;

    const lit_size: usize = @as(usize, 0x300) << @intCast(opt.lc + opt.lp);
    const literal = try a.alloc(u16, lit_size);
    defer a.free(literal);
    @memset(literal, kProbInit);
    const head = try a.alloc(i32, hsize);
    defer a.free(head);
    @memset(head, -1);
    const chain = try a.alloc(i32, @max(data.len, 1));
    defer a.free(chain);

    var enc = Encoder{ .a = a, .opt = opt, .literal = literal, .head = head, .chain = chain, .hash_mask = hsize - 1 };

    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    const props: u8 = @intCast((@as(u32, opt.pb) * 5 + opt.lp) * 9 + opt.lc);
    try out.append(props);
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], opt.dict_size, .little);
    std.mem.writeInt(u64, hdr[4..12], data.len, .little);
    try out.appendSlice(&hdr);

    var rc = RangeEncoder{ .out = &out };
    const pb_mask: u32 = (@as(u32, 1) << opt.pb) - 1;
    const INF: u32 = 0xFFFF_FFFF;

    const WIN: usize = 1024;
    const opts = try a.alloc(OptNode, WIN + 1);
    defer a.free(opts);
    var matches: [kMatchMaxLen + 2]Match = undefined;
    var ops: [WIN]Match = undefined; // backtracked op list (len, dist); dist 0 = literal

    var anchor: usize = 0;
    while (anchor < data.len) {
        const max_win = @min(WIN, data.len - anchor);
        opts[0] = .{ .price = 0, .state = enc.state, .reps = enc.reps, .from = 0, .len = 0, .dist = 0 };
        var z: usize = 1;
        while (z <= max_win) : (z += 1) opts[z].price = INF;

        var cur: usize = 0;
        while (cur < max_win) : (cur += 1) {
            const p = anchor + cur;
            const nmatch = enc.getMatches(data, p, &matches); // inserts p
            if (opts[cur].price == INF) continue;
            const base = opts[cur].price;
            const st = opts[cur].state;
            const reps = opts[cur].reps;
            const pos_state: u32 = @as(u32, @intCast(p)) & pb_mask;
            const im_idx = (st << kNumPosBitsMax) + pos_state;
            const im0 = priceBit(enc.is_match[im_idx], 0);
            const im1 = priceBit(enc.is_match[im_idx], 1);

            // (1) literal
            {
                const prev: u8 = if (p == 0) 0 else data[p - 1];
                const probs = enc.litProbs(p, prev);
                const lp: u32 = if (st < 7)
                    priceLiteral(probs, data[p], 0, false)
                else
                    priceLiteral(probs, data[p], data[p - (reps[0] + 1)], true);
                const np = base + im0 + lp;
                if (np < opts[cur + 1].price)
                    opts[cur + 1] = .{ .price = np, .state = litNextState(st), .reps = reps, .from = @intCast(cur), .len = 1, .dist = 0 };
            }

            const rep_base = base + im1 + priceBit(enc.is_rep[st], 1);
            const new_base = base + im1 + priceBit(enc.is_rep[st], 0);
            const win_left: u32 = @intCast(max_win - cur);

            // (2) rep matches
            for (reps, 0..) |r, ri| {
                const dist = r + 1;
                if (dist > p) continue;
                const src = p - dist;
                var maxl: u32 = @min(@as(u32, kMatchMaxLen), win_left);
                if (@as(usize, maxl) > data.len - p) maxl = @intCast(data.len - p);
                var l: u32 = 0;
                while (l < maxl and data[src + l] == data[p + l]) l += 1;
                var rep_sel: u32 = 0;
                if (ri == 0) {
                    rep_sel = priceBit(enc.is_rep_g0[st], 0);
                } else {
                    rep_sel = priceBit(enc.is_rep_g0[st], 1);
                    rep_sel += if (ri == 1) priceBit(enc.is_rep_g1[st], 0) else (priceBit(enc.is_rep_g1[st], 1) + priceBit(enc.is_rep_g2[st], @intCast(ri - 2)));
                }
                if (ri == 0 and l >= 1) {
                    // short rep (length 1) — only valid when the byte at rep0 matches
                    const np = rep_base + rep_sel + priceBit(enc.is_rep0_long[im_idx], 0);
                    if (np < opts[cur + 1].price)
                        opts[cur + 1] = .{ .price = np, .state = shortRepNextState(st), .reps = reps, .from = @intCast(cur), .len = 1, .dist = dist };
                }
                if (l >= kMatchMinLen) {
                    var nreps = reps;
                    if (ri != 0) {
                        const d = nreps[ri];
                        var k = ri;
                        while (k > 0) : (k -= 1) nreps[k] = nreps[k - 1];
                        nreps[0] = d;
                    }
                    const rep0long: u32 = if (ri == 0) priceBit(enc.is_rep0_long[im_idx], 1) else 0;
                    var len: u32 = kMatchMinLen;
                    while (len <= l) : (len += 1) {
                        const np = rep_base + rep_sel + rep0long + enc.rep_len_coder.price(len - kMatchMinLen, pos_state);
                        if (np < opts[cur + len].price)
                            opts[cur + len] = .{ .price = np, .state = repNextState(st), .reps = nreps, .from = @intCast(cur), .len = len, .dist = dist };
                    }
                }
            }

            // (3) new-distance matches
            var mi: usize = 0;
            var start_len: u32 = kMatchMinLen;
            while (mi < nmatch) : (mi += 1) {
                const md = matches[mi];
                const d0 = md.dist - 1;
                var nreps = reps;
                nreps[3] = nreps[2];
                nreps[2] = nreps[1];
                nreps[1] = nreps[0];
                nreps[0] = d0;
                var len = start_len;
                const top = @min(md.len, win_left);
                while (len <= top) : (len += 1) {
                    const np = new_base + enc.len_coder.price(len - kMatchMinLen, pos_state) + enc.priceDistance(d0, len);
                    if (np < opts[cur + len].price)
                        opts[cur + len] = .{ .price = np, .state = matchNextState(st), .reps = nreps, .from = @intCast(cur), .len = len, .dist = md.dist };
                }
                start_len = md.len + 1;
            }
        }

        // backtrack from max_win to 0, collect ops in reverse
        var nops: usize = 0;
        var idx: usize = max_win;
        while (idx != 0) {
            const node = opts[idx];
            ops[nops] = .{ .len = node.len, .dist = node.dist };
            nops += 1;
            idx = node.from;
        }
        // emit forward (reverse of collection order)
        var pos = anchor;
        var oi: usize = nops;
        while (oi != 0) {
            oi -= 1;
            const op = ops[oi];
            const pos_state: u32 = @as(u32, @intCast(pos)) & pb_mask;
            if (op.dist == 0) {
                try enc.emitLit(&rc, data, pos, pos_state);
                pos += 1;
            } else {
                try enc.emitMatch(&rc, op.len, op.dist, pos_state);
                pos += op.len;
            }
        }
        anchor += max_win;
    }

    try rc.flush();
    return out.toOwnedSlice();
}

// --- tests: round-trip our output through xz's liblzma decoder is done in
// main.zig's CLI (lzmaenc bench); here we just sanity-check it runs & is smaller
// than the input on compressible data.
test "lzma_enc produces a smaller stream on repetitive data" {
    const a = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast((i / 16) & 0xFF);
    const z = try compress(&buf, a, .{});
    defer a.free(z);
    try std.testing.expect(z.len < buf.len);
}

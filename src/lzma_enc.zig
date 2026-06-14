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
pub const Match = struct { len: u32, dist: u32 }; // dist is the true distance (>=1)

pub const Options = struct {
    lc: u4 = 3,
    lp: u4 = 0,
    pb: u4 = 2,
    dict_size: u32 = 1 << 26, // 64 MiB
    nice_len: u32 = 64,
    max_depth: u32 = 96,
    dist_penalty: u32 = 0, // experimental far-distance bias (price units per slot)
    rep_penalty: u32 = 0, // experimental: bias the DP away from reps toward new matches
    window: usize = 1024, // optimal-parse window (price refreshes at each window)
    kbest: usize = 4, // multi-state DP: candidates kept per position
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
    spec_pos: [kNumFullDistances - kEndPosModelIndex + 1]u16 = [_]u16{kProbInit} ** (kNumFullDistances - kEndPosModelIndex + 1),
    align_probs: [kAlignTableSize]u16 = [_]u16{kProbInit} ** kAlignTableSize,
    len_coder: LenCoder = .{},
    rep_len_coder: LenCoder = .{},
    literal: []u16, // 0x300 << (lc+lp)

    // state
    state: u32 = 0,
    reps: [4]u32 = .{ 0, 0, 0, 0 }, // 0-based distances (true distance - 1)

    // match finder. `head` = latest position per hash-4 (shared). Greedy
    // `compress` uses `chain` (hash-4 chains); the optimal parser uses `son`
    // (BT4 binary tree — best distance-per-length, what liblzma/7-Zip use).
    head: []i32,
    chain: []i32 = &[_]i32{},
    // BT4 tree. `son` is a CYCLIC buffer of `2 * cyc` entries indexed by
    // `(pos & cyc_mask) * 2` — not absolute position. Matches are bounded to the
    // last `cyc` positions anyway (min_pos), so a full-length son array was pure
    // waste (7.7 GB for a 961 MB tar); the cyclic buffer is ~1 GB at the same dict
    // and identical match quality. `cyc` is the pow2 window (== declared dict_size).
    son: []i32 = &[_]i32{}, // 2 entries/slot: left=son[s*2], right=son[s*2+1]
    cyc: u32 = 0, // cyclic window size (pow2 >= requested dict_size)
    cyc_mask: u32 = 0, // cyc - 1
    head2: []i32 = &[_]i32{}, // 1<<16 exact 2-byte index (short matches)
    head3: []i32 = &[_]i32{}, // 1<<16 3-byte hash
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
        // EXPERIMENT: far-distance penalty. The fixed-window price model can't see
        // that committing to close distances trains the model into a cheaper basin
        // (liblzma converges there; our locally-cheapest DP falls into a far/rep
        // basin). A static penalty ~ slot approximates that amortized cost.
        return p + slot * self.opt.dist_penalty;
    }

    /// BT4 match finder: fill `out` with (len, dist) pairs — for each achievable
    /// length the *closest* distance, lengths strictly increasing — and insert
    /// `pos` into the binary tree. This is the optimal distance-per-length the
    /// hash chain couldn't give, and what lets the optimal parse reach 9e class.
    fn getMatches(self: *Encoder, data: []const u8, pos: usize, out: []Match) usize {
        var n: usize = 0;
        if (pos + 4 > data.len) return 0; // tail: never a match source
        const max_len = @min(@as(u32, kMatchMaxLen), @as(u32, @intCast(data.len - pos)));
        // Window is `cyc` positions [pos-cyc+1, pos] — one less than cyc so every
        // live position maps to a distinct cyclic slot (max distance cyc-1 < cyc,
        // the declared dict). `min_pos` is the oldest still-referenceable position.
        const min_pos: i64 = @as(i64, @intCast(pos)) - @as(i64, @intCast(self.cyc)) + 1;
        const mask = self.cyc_mask;
        var best_len: u32 = kMatchMinLen - 1;

        // len-2 / len-3 matches from the hash-2 / hash-3 heads. The >=4 BT4 below
        // is blind to these (4-byte hash), but liblzma uses them heavily — the
        // parse diverges from liblzma at the very first short match without them.
        // Kept strictly len 2 then 3 then >=4 so the DP's per-length logic holds.
        {
            const h2 = hash2(data, pos);
            const c2 = self.head2[h2];
            self.head2[h2] = @intCast(pos);
            if (c2 >= 0 and @as(i64, c2) >= min_pos) {
                const src: usize = @intCast(c2);
                if (data[src] == data[pos] and data[src + 1] == data[pos + 1]) {
                    out[n] = .{ .len = 2, .dist = @intCast(pos - src) };
                    n += 1;
                    best_len = 2;
                }
            }
            const h3 = hash3(data, pos);
            const c3 = self.head3[h3];
            self.head3[h3] = @intCast(pos);
            if (c3 >= 0 and @as(i64, c3) >= min_pos) {
                const src: usize = @intCast(c3);
                if (data[src] == data[pos] and data[src + 1] == data[pos + 1] and data[src + 2] == data[pos + 2]) {
                    out[n] = .{ .len = 3, .dist = @intCast(pos - src) };
                    n += 1;
                    best_len = 3;
                }
            }
        }

        const h = hash4(data, pos, self.hash_mask);
        var cur_match = self.head[h];
        self.head[h] = @intCast(pos);

        var ptr0: usize = (pos & mask) * 2 + 1; // pos's right-child slot
        var ptr1: usize = (pos & mask) * 2; // pos's left-child slot
        var len0: u32 = 0;
        var len1: u32 = 0;
        var cut: u32 = self.opt.max_depth;
        while (true) {
            if (cut == 0 or cur_match < 0 or @as(i64, cur_match) < min_pos) {
                self.son[ptr0] = -1;
                self.son[ptr1] = -1;
                break;
            }
            cut -= 1;
            const cm: usize = @intCast(cur_match);
            const pair = (cm & mask) * 2;
            var len = @min(len0, len1);
            if (data[cm + len] == data[pos + len]) {
                len += 1;
                while (len != max_len and data[cm + len] == data[pos + len]) len += 1;
                if (len > best_len) {
                    out[n] = .{ .len = len, .dist = @intCast(pos - cm) };
                    n += 1;
                    best_len = len;
                }
                if (len == max_len) {
                    self.son[ptr1] = self.son[pair];
                    self.son[ptr0] = self.son[pair + 1];
                    break;
                }
            }
            if (data[cm + len] < data[pos + len]) {
                self.son[ptr1] = cur_match;
                ptr1 = pair + 1;
                cur_match = self.son[ptr1];
                len1 = len;
            } else {
                self.son[ptr0] = cur_match;
                ptr0 = pair;
                cur_match = self.son[ptr0];
                len0 = len;
            }
        }
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

    /// Emit a match using an EXPLICIT decision (no rep re-derivation) — used by
    /// the transcoder to faithfully replay another encoder's exact token choices
    /// through our model. rep_idx: -1 = new match; 0..3 = that rep. is_short =
    /// rep0 length-1 shortrep.
    fn emitMatchExplicit(self: *Encoder, rc: *RangeEncoder, rep_idx: i32, is_short: bool, len: u32, dist0: u32, pos_state: u32) !void {
        const idx = (self.state << kNumPosBitsMax) + pos_state;
        try rc.encodeBit(&self.is_match[idx], 1);
        if (rep_idx < 0) {
            try rc.encodeBit(&self.is_rep[self.state], 0);
            self.reps[3] = self.reps[2];
            self.reps[2] = self.reps[1];
            self.reps[1] = self.reps[0];
            self.reps[0] = dist0;
            try self.len_coder.encode(rc, len - kMatchMinLen, pos_state);
            try self.encodeDistance(rc, dist0, len);
            self.state = matchNextState(self.state);
            return;
        }
        try rc.encodeBit(&self.is_rep[self.state], 1);
        const ri: usize = @intCast(rep_idx);
        if (ri == 0) {
            try rc.encodeBit(&self.is_rep_g0[self.state], 0);
            if (is_short) {
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
    from_k: u32 = 0, // which K-best candidate at `from` (multi-state DP)
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

/// Size of the BT4 cyclic match-finder window: the smallest power of two that is
/// >= the requested dict_size, but never larger than the data (a window past the
/// input can't hold a match). This is the declared dict in the .lzma header and
/// bounds max match distance to `cyc - 1`, so every live position maps to a unique
/// cyclic slot. Capped at 1<<28 (2 GB son) as a memory backstop.
fn cyclicWindow(dict_size: u32, data_len: usize) u32 {
    const want: u64 = @min(@as(u64, dict_size), @max(@as(u64, data_len), 1));
    var cyc: u32 = 1 << 12; // 4096 floor
    while (cyc < want and cyc < (1 << 28)) cyc <<= 1;
    return cyc;
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
    const cyc = cyclicWindow(opt.dict_size, data.len);
    const son = try a.alloc(i32, 2 * @as(usize, cyc));
    defer a.free(son);
    const head2 = try a.alloc(i32, 1 << 16);
    defer a.free(head2);
    @memset(head2, -1);
    const head3 = try a.alloc(i32, 1 << 16);
    defer a.free(head3);
    @memset(head3, -1);

    var enc = Encoder{ .a = a, .opt = opt, .literal = literal, .head = head, .son = son, .cyc = cyc, .cyc_mask = cyc - 1, .head2 = head2, .head3 = head3, .hash_mask = hsize - 1 };

    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    const props: u8 = @intCast((@as(u32, opt.pb) * 5 + opt.lp) * 9 + opt.lc);
    try out.append(props);
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], cyc, .little);
    std.mem.writeInt(u64, hdr[4..12], data.len, .little);
    try out.appendSlice(&hdr);

    var rc = RangeEncoder{ .out = &out };
    const pb_mask: u32 = (@as(u32, 1) << opt.pb) - 1;
    const INF: u32 = 0xFFFF_FFFF;

    const WIN: usize = opt.window;
    const OPTS_CAP = WIN + kMatchMaxLen + 1; // matches may reach past WIN without truncation
    const opts = try a.alloc(OptNode, OPTS_CAP);
    defer a.free(opts);
    var matches: [kMatchMaxLen + 2]Match = undefined;
    const ops = try a.alloc(Match, WIN + 1); // backtracked op list (len, dist); dist 0 = literal
    defer a.free(ops);

    var anchor: usize = 0;
    while (anchor < data.len) {
        const remaining = data.len - anchor;
        const cap_scan = @min(WIN, remaining);
        opts[0] = .{ .price = 0, .state = enc.state, .reps = enc.reps, .from = 0, .len = 0, .dist = 0 };
        var z: usize = 1;
        const init_to = @min(OPTS_CAP - 1, cap_scan + kMatchMaxLen);
        while (z <= init_to) : (z += 1) opts[z].price = INF;

        var stop: usize = cap_scan; // window end (positions the DP path consumes)
        var forced_len: u32 = 0; // a >=nice_len match emitted whole after the path
        var forced_dist: u32 = 0;

        var cur: usize = 0;
        while (cur < cap_scan) : (cur += 1) {
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
            const max_here: u32 = @intCast(remaining - cur); // longest any match can be

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

            const rep_base = base + im1 + priceBit(enc.is_rep[st], 1) + enc.opt.rep_penalty;
            const new_base = base + im1 + priceBit(enc.is_rep[st], 0);
            var longest: u32 = 0;
            var longest_dist: u32 = 0;

            // (2) rep matches
            for (reps, 0..) |r, ri| {
                const dist = r + 1;
                if (dist > p) continue;
                const src = p - dist;
                const maxl: u32 = @min(@as(u32, kMatchMaxLen), max_here);
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
                        if (np <= opts[cur + len].price) // prefer match (and longer) on ties, like liblzma
                            opts[cur + len] = .{ .price = np, .state = repNextState(st), .reps = nreps, .from = @intCast(cur), .len = len, .dist = dist };
                    }
                    if (l > longest) {
                        longest = l;
                        longest_dist = dist;
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
                while (len <= md.len) : (len += 1) {
                    const np = new_base + enc.len_coder.price(len - kMatchMinLen, pos_state) + enc.priceDistance(d0, len);
                    if (np <= opts[cur + len].price) // prefer longer/new on ties, like liblzma
                        opts[cur + len] = .{ .price = np, .state = matchNextState(st), .reps = nreps, .from = @intCast(cur), .len = len, .dist = md.dist };
                }
                start_len = md.len + 1;
                if (md.len > longest) {
                    longest = md.len;
                    longest_dist = md.dist;
                }
            }

            // long-match early stop: a >=nice_len match is essentially always
            // worth taking whole — emit the optimal path up to here, then it,
            // instead of letting the window boundary truncate it.
            if (longest >= enc.opt.nice_len) {
                stop = cur;
                forced_len = longest;
                forced_dist = longest_dist;
                break;
            }
        }

        // backtrack from `stop` to 0, collect ops in reverse
        var nops: usize = 0;
        var idx: usize = stop;
        while (idx != 0) {
            const node = opts[idx];
            ops[nops] = .{ .len = node.len, .dist = node.dist };
            nops += 1;
            idx = node.from;
        }
        // emit the optimal path forward (reverse of collection order)
        var pos = anchor;
        var oi: usize = nops;
        while (oi != 0) {
            oi -= 1;
            const op = ops[oi];
            const ps: u32 = @as(u32, @intCast(pos)) & pb_mask;
            if (op.dist == 0) {
                try enc.emitLit(&rc, data, pos, ps);
                pos += 1;
            } else {
                try enc.emitMatch(&rc, op.len, op.dist, ps);
                pos += op.len;
            }
        }
        anchor += stop;

        // emit the forced long match whole, then skip-insert its covered bytes
        if (forced_len > 0) {
            const ps: u32 = @as(u32, @intCast(anchor)) & pb_mask;
            try enc.emitMatch(&rc, forced_len, forced_dist, ps);
            var k: usize = 1;
            while (k < forced_len) : (k += 1) _ = enc.getMatches(data, anchor + k, &matches);
            anchor += forced_len;
        }
    }

    try rc.flush();
    return out.toOwnedSlice();
}

// K-best insertion into a multi-state node's candidate list (ascending price).
fn kInsert(opts: []OptNode, kc: usize, target: usize, cand: OptNode) void {
    const base = target * kc;
    // Dedup by (state, reps): keep only the CHEAPEST candidate per distinct
    // rep-history, so the K slots hold diverse states instead of near-duplicates.
    // This makes a small K as effective as a much larger naive K — fewer
    // candidates to relax from per position, i.e. a big speedup at equal ratio.
    var i: usize = 0;
    while (i < kc and opts[base + i].price != 0xFFFF_FFFF) : (i += 1) {
        const e = opts[base + i];
        if (e.state == cand.state and e.reps[0] == cand.reps[0] and e.reps[1] == cand.reps[1] and e.reps[2] == cand.reps[2] and e.reps[3] == cand.reps[3]) {
            if (cand.price < e.price) {
                opts[base + i] = cand;
                var j = i;
                while (j > 0 and opts[base + j - 1].price > opts[base + j].price) : (j -= 1) {
                    const tmp = opts[base + j - 1];
                    opts[base + j - 1] = opts[base + j];
                    opts[base + j] = tmp;
                }
            }
            return;
        }
    }
    if (cand.price >= opts[base + kc - 1].price) return;
    var k2: usize = kc - 1;
    while (k2 > 0 and opts[base + k2 - 1].price > cand.price) : (k2 -= 1) {
        opts[base + k2] = opts[base + k2 - 1];
    }
    opts[base + k2] = cand;
}

/// Multi-state (K-best) optimal parse: keep the top-K (price, state, reps)
/// candidates per position, so a slightly-pricier path with BETTER reps survives
/// to enable a cheaper continuation — the rep-setup paths a single-state DP (and
/// liblzma's single opt[] array) lose. More powerful than single-state, so it can
/// beat liblzma, not just match it.
pub fn compressOptK(data: []const u8, a: std.mem.Allocator, opt_in: Options) ![]u8 {
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
    const cyc = cyclicWindow(opt.dict_size, data.len);
    const son = try a.alloc(i32, 2 * @as(usize, cyc));
    defer a.free(son);
    const head2 = try a.alloc(i32, 1 << 16);
    defer a.free(head2);
    @memset(head2, -1);
    const head3 = try a.alloc(i32, 1 << 16);
    defer a.free(head3);
    @memset(head3, -1);
    var enc = Encoder{ .a = a, .opt = opt, .literal = literal, .head = head, .son = son, .cyc = cyc, .cyc_mask = cyc - 1, .head2 = head2, .head3 = head3, .hash_mask = hsize - 1 };

    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    const props: u8 = @intCast((@as(u32, opt.pb) * 5 + opt.lp) * 9 + opt.lc);
    try out.append(props);
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], cyc, .little);
    std.mem.writeInt(u64, hdr[4..12], data.len, .little);
    try out.appendSlice(&hdr);

    var rc = RangeEncoder{ .out = &out };
    const pb_mask: u32 = (@as(u32, 1) << opt.pb) - 1;
    const INF: u32 = 0xFFFF_FFFF;

    const K: usize = opt.kbest;
    const WIN: usize = opt.window;
    const OPTS_CAP = WIN + kMatchMaxLen + 1;
    const opts = try a.alloc(OptNode, OPTS_CAP * K);
    defer a.free(opts);
    var matches: [kMatchMaxLen + 2]Match = undefined;
    const ops = try a.alloc(Match, WIN + 1);
    defer a.free(ops);

    var anchor: usize = 0;
    while (anchor < data.len) {
        const remaining = data.len - anchor;
        const cap_scan = @min(WIN, remaining);
        const init_to = @min(OPTS_CAP, cap_scan + kMatchMaxLen + 1);
        var z: usize = 0;
        while (z < init_to) : (z += 1) {
            var kk: usize = 0;
            while (kk < K) : (kk += 1) opts[z * K + kk].price = INF;
        }
        opts[0] = .{ .price = 0, .state = enc.state, .reps = enc.reps, .from = 0, .len = 0, .dist = 0 };

        var stop: usize = cap_scan;
        var forced_len: u32 = 0;
        var forced_dist: u32 = 0;
        var cur: usize = 0;
        while (cur < cap_scan) : (cur += 1) {
            const p = anchor + cur;
            const nmatch = enc.getMatches(data, p, &matches); // inserts p
            const max_here: u32 = @intCast(remaining - cur);
            const pos_state: u32 = @as(u32, @intCast(p)) & pb_mask;
            var longest: u32 = 0;
            var longest_dist: u32 = 0;
            if (nmatch > 0) {
                longest = matches[nmatch - 1].len;
                longest_dist = matches[nmatch - 1].dist;
            }
            var k: usize = 0;
            while (k < K) : (k += 1) {
                const node = opts[cur * K + k];
                if (node.price == INF) continue;
                const base = node.price;
                const st = node.state;
                const reps = node.reps;
                const im_idx = (st << kNumPosBitsMax) + pos_state;
                const im0 = priceBit(enc.is_match[im_idx], 0);
                const im1 = priceBit(enc.is_match[im_idx], 1);
                { // literal
                    const prev: u8 = if (p == 0) 0 else data[p - 1];
                    const probs = enc.litProbs(p, prev);
                    const lp: u32 = if (st < 7) priceLiteral(probs, data[p], 0, false) else priceLiteral(probs, data[p], data[p - (reps[0] + 1)], true);
                    kInsert(opts, K, cur + 1, .{ .price = base + im0 + lp, .state = litNextState(st), .reps = reps, .from = @intCast(cur), .from_k = @intCast(k), .len = 1, .dist = 0 });
                }
                const rep_base = base + im1 + priceBit(enc.is_rep[st], 1);
                const new_base = base + im1 + priceBit(enc.is_rep[st], 0);
                for (reps, 0..) |r, ri| {
                    const dist = r + 1;
                    if (dist > p) continue;
                    const src = p - dist;
                    const maxl: u32 = @min(@as(u32, kMatchMaxLen), max_here);
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
                        kInsert(opts, K, cur + 1, .{ .price = rep_base + rep_sel + priceBit(enc.is_rep0_long[im_idx], 0), .state = shortRepNextState(st), .reps = reps, .from = @intCast(cur), .from_k = @intCast(k), .len = 1, .dist = dist });
                    }
                    if (l >= kMatchMinLen) {
                        var nreps = reps;
                        if (ri != 0) {
                            const d = nreps[ri];
                            var z2 = ri;
                            while (z2 > 0) : (z2 -= 1) nreps[z2] = nreps[z2 - 1];
                            nreps[0] = d;
                        }
                        const rep0long: u32 = if (ri == 0) priceBit(enc.is_rep0_long[im_idx], 1) else 0;
                        var len: u32 = kMatchMinLen;
                        while (len <= l) : (len += 1) {
                            kInsert(opts, K, cur + len, .{ .price = rep_base + rep_sel + rep0long + enc.rep_len_coder.price(len - kMatchMinLen, pos_state), .state = repNextState(st), .reps = nreps, .from = @intCast(cur), .from_k = @intCast(k), .len = len, .dist = dist });
                        }
                    }
                }
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
                    while (len <= md.len) : (len += 1) {
                        kInsert(opts, K, cur + len, .{ .price = new_base + enc.len_coder.price(len - kMatchMinLen, pos_state) + enc.priceDistance(d0, len), .state = matchNextState(st), .reps = nreps, .from = @intCast(cur), .from_k = @intCast(k), .len = len, .dist = md.dist });
                    }
                    start_len = md.len + 1;
                }
            }
            if (longest >= enc.opt.nice_len) {
                stop = cur;
                forced_len = longest;
                forced_dist = longest_dist;
                break;
            }
        }
        // backtrack from the cheapest candidate at `stop`
        var nops: usize = 0;
        var idx: usize = stop;
        var bk: u32 = 0;
        while (idx != 0) {
            const node = opts[idx * K + bk];
            ops[nops] = .{ .len = node.len, .dist = node.dist };
            nops += 1;
            const nf = node.from;
            const nfk = node.from_k;
            idx = nf;
            bk = nfk;
        }
        var pos = anchor;
        var oi: usize = nops;
        while (oi != 0) {
            oi -= 1;
            const op = ops[oi];
            const ps: u32 = @as(u32, @intCast(pos)) & pb_mask;
            if (op.dist == 0) {
                try enc.emitLit(&rc, data, pos, ps);
                pos += 1;
            } else {
                try enc.emitMatch(&rc, op.len, op.dist, ps);
                pos += op.len;
            }
        }
        anchor += stop;
        if (forced_len > 0) {
            const ps: u32 = @as(u32, @intCast(anchor)) & pb_mask;
            try enc.emitMatch(&rc, forced_len, forced_dist, ps);
            var kf: usize = 1;
            while (kf < forced_len) : (kf += 1) _ = enc.getMatches(data, anchor + kf, &matches);
            anchor += forced_len;
        }
    }
    try rc.flush();
    return out.toOwnedSlice();
}

/// Parallel chunked multi-state compression: split `data` into `chunk_size`
/// pieces, compress each independently with compressOptK across a thread pool,
/// and pack them with a small index. Bounds the multi-state encode time to
/// ~total/cores (the K-best parse is ~0.08 MB/s single-thread). Cross-chunk
/// matches are lost, but opaque-data redundancy is mostly local. Block format:
///   [u32 chunk_size][u32 n_chunks][n_chunks × u32 comp_len][chunk .lzma streams]
pub fn compressOptKChunked(data: []const u8, a: std.mem.Allocator, chunk_size: usize, kbest: usize) ![]u8 {
    const n_chunks = (data.len + chunk_size - 1) / chunk_size;
    const results = try a.alloc(?[]u8, n_chunks);
    defer {
        for (results) |r| if (r) |rr| a.free(rr);
        a.free(results);
    }
    @memset(results, null);

    const Worker = struct {
        fn run(base: std.mem.Allocator, all: []const u8, ci: usize, cs: usize, kb: usize, slot: *?[]u8) void {
            const start = ci * cs;
            const end = @min(start + cs, all.len);
            const chunk = all[start..end];
            var kd: u32 = 1 << 20;
            while (kd < chunk.len and kd < (1 << 27)) kd <<= 1;
            slot.* = compressOptK(chunk, base, .{ .dict_size = kd, .nice_len = 273, .max_depth = 1024, .window = 1024, .kbest = kb }) catch null;
        }
    };
    var pool: std.Thread.Pool = undefined;
    const njobs = @min(@as(usize, 8), (std.Thread.getCpuCount() catch 4));
    try pool.init(.{ .allocator = a, .n_jobs = @intCast(njobs) });
    defer pool.deinit();
    var wg = std.Thread.WaitGroup{};
    var ci: usize = 0;
    while (ci < n_chunks) : (ci += 1) {
        pool.spawnWg(&wg, Worker.run, .{ a, data, ci, chunk_size, kbest, &results[ci] });
    }
    pool.waitAndWork(&wg);
    for (results) |r| if (r == null) return error.ChunkFailed;

    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(chunk_size), .little);
    std.mem.writeInt(u32, hdr[4..8], @intCast(n_chunks), .little);
    try out.appendSlice(&hdr);
    for (results) |r| {
        var lb: [4]u8 = undefined;
        std.mem.writeInt(u32, &lb, @intCast(r.?.len), .little);
        try out.appendSlice(&lb);
    }
    for (results) |r| try out.appendSlice(r.?);
    return out.toOwnedSlice();
}

/// Decode a chunked multi-state block back to `total_size` bytes.
pub fn decodeOptKChunked(block: []const u8, a: std.mem.Allocator, total_size: usize) ![]u8 {
    if (block.len < 8) return error.Truncated;
    const n_chunks = std.mem.readInt(u32, block[4..8], .little);
    var off: usize = 8;
    const lens = try a.alloc(u32, n_chunks);
    defer a.free(lens);
    var i: usize = 0;
    while (i < n_chunks) : (i += 1) {
        lens[i] = std.mem.readInt(u32, block[off..][0..4], .little);
        off += 4;
    }
    const out = try a.alloc(u8, total_size);
    errdefer a.free(out);
    var o: usize = 0;
    i = 0;
    while (i < n_chunks) : (i += 1) {
        const cl = lens[i];
        const dec = try decode(block[off..][0..cl], a, null);
        defer a.free(dec);
        @memcpy(out[o..][0..dec.len], dec);
        o += dec.len;
        off += cl;
    }
    if (o != total_size) return error.SizeMismatch;
    return out;
}

test "chunked multi-state round-trips" {
    const al = std.testing.allocator;
    var buf: [40000]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast((i * 5 + i / 7) & 0xFF);
    const z = try compressOptKChunked(&buf, al, 16384, 8);
    defer al.free(z);
    const back = try decodeOptKChunked(z, al, buf.len);
    defer al.free(back);
    try std.testing.expectEqualSlices(u8, &buf, back);
}

/// Decisive diagnostic: decode an LZMA stream's token sequence and RE-EMIT it
/// through our own encoder/model. If the result ~= the input size, our model is
/// byte-exact and any ratio gap vs that stream is purely our PARSE/search — not
/// the model or prices. Returns our re-encoded length.
pub fn transcodeLen(stream: []const u8, known_size: ?usize, a: std.mem.Allocator) !usize {
    if (stream.len < 13) return error.Truncated;
    const props = stream[0];
    const lc: u4 = @intCast(props % 9);
    const r = props / 9;
    const lp: u4 = @intCast(r % 5);
    const pb: u4 = @intCast(r / 5);
    const raw_size = std.mem.readInt(u64, stream[5..13], .little);
    const out_size: usize = if (raw_size == std.math.maxInt(u64)) (known_size orelse return error.UnknownSize) else @intCast(raw_size);

    initPrices();
    const out = try a.alloc(u8, out_size);
    defer a.free(out);
    const dlit = try a.alloc(u16, @as(usize, 0x300) << @intCast(lc + lp));
    defer a.free(dlit);
    @memset(dlit, kProbInit);

    // decoder model
    var is_match = [_]u16{kProbInit} ** (kNumStates << kNumPosBitsMax);
    var is_rep = [_]u16{kProbInit} ** kNumStates;
    var is_rep_g0 = [_]u16{kProbInit} ** kNumStates;
    var is_rep_g1 = [_]u16{kProbInit} ** kNumStates;
    var is_rep_g2 = [_]u16{kProbInit} ** kNumStates;
    var is_rep0_long = [_]u16{kProbInit} ** (kNumStates << kNumPosBitsMax);
    var pos_slot = [_][1 << 6]u16{[_]u16{kProbInit} ** (1 << 6)} ** kNumLenToPosStates;
    var spec_pos = [_]u16{kProbInit} ** (kNumFullDistances - kEndPosModelIndex + 1);
    var align_probs = [_]u16{kProbInit} ** kAlignTableSize;
    var len_coder = DecLenCoder{};
    var rep_len_coder = DecLenCoder{};

    // our own encoder (fresh model) to re-emit into
    const elit = try a.alloc(u16, @as(usize, 0x300) << @intCast(lc + lp));
    defer a.free(elit);
    @memset(elit, kProbInit);
    var enc = Encoder{ .a = a, .opt = .{ .lc = lc, .lp = lp, .pb = pb }, .literal = elit, .head = &[_]i32{}, .hash_mask = 0 };
    var eout = std.ArrayList(u8).init(a);
    defer eout.deinit();
    var rce = RangeEncoder{ .out = &eout };

    var rc = RangeDecoder.init(stream[13..]);
    var state: u32 = 0;
    var reps = [4]u32{ 0, 0, 0, 0 };
    const pb_mask: u32 = (@as(u32, 1) << pb) - 1;
    const lp_mask: u32 = (@as(u32, 1) << lp) - 1;
    var o: usize = 0;
    while (o < out_size) {
        const ps: u32 = @as(u32, @intCast(o)) & pb_mask;
        const im = (state << kNumPosBitsMax) + ps;
        if (rc.decodeBit(&is_match[im]) == 0) {
            const prev: u8 = if (o == 0) 0 else out[o - 1];
            const idx = 0x300 * (((@as(u32, @intCast(o)) & lp_mask) << lc) + (@as(u32, prev) >> @intCast(8 - lc)));
            const probs = dlit[idx..][0..0x300];
            var sym: u32 = 1;
            if (state < 7) {
                while (sym < 0x100) sym = (sym << 1) | rc.decodeBit(&probs[sym]);
            } else {
                var mb: u32 = out[o - (reps[0] + 1)];
                while (sym < 0x100) {
                    mb <<= 1;
                    const match_bit = mb & 0x100;
                    const b = rc.decodeBit(&probs[0x100 + match_bit + sym]);
                    sym = (sym << 1) | b;
                    if (match_bit != (@as(u32, b) << 8)) {
                        while (sym < 0x100) sym = (sym << 1) | rc.decodeBit(&probs[sym]);
                        break;
                    }
                }
            }
            out[o] = @intCast(sym & 0xFF);
            try enc.emitLit(&rce, out, o, ps);
            o += 1;
            state = litNextState(state);
            continue;
        }
        var len: u32 = undefined;
        var rep_idx: i32 = -1;
        var dist0_new: u32 = 0;
        if (rc.decodeBit(&is_rep[state]) == 1) {
            if (rc.decodeBit(&is_rep_g0[state]) == 0) {
                rep_idx = 0;
                if (rc.decodeBit(&is_rep0_long[im]) == 0) {
                    try enc.emitMatchExplicit(&rce, 0, true, 1, reps[0], ps);
                    state = shortRepNextState(state);
                    out[o] = out[o - (reps[0] + 1)];
                    o += 1;
                    continue;
                }
            } else {
                var d: u32 = undefined;
                if (rc.decodeBit(&is_rep_g1[state]) == 0) {
                    rep_idx = 1;
                    d = reps[1];
                    reps[1] = reps[0];
                } else if (rc.decodeBit(&is_rep_g2[state]) == 0) {
                    rep_idx = 2;
                    d = reps[2];
                    reps[2] = reps[1];
                    reps[1] = reps[0];
                } else {
                    rep_idx = 3;
                    d = reps[3];
                    reps[3] = reps[2];
                    reps[2] = reps[1];
                    reps[1] = reps[0];
                }
                reps[0] = d;
            }
            len = rep_len_coder.decode(&rc, ps) + kMatchMinLen;
            state = repNextState(state);
        } else {
            reps[3] = reps[2];
            reps[2] = reps[1];
            reps[1] = reps[0];
            len = len_coder.decode(&rc, ps) + kMatchMinLen;
            const len_state = @min(len - kMatchMinLen, kNumLenToPosStates - 1);
            const slot = rc.decodeTree(pos_slot[len_state][0..], 6);
            var dist0: u32 = slot;
            if (slot >= kStartPosModelIndex) {
                const footer: u6 = @intCast((slot >> 1) - 1);
                dist0 = (2 | (slot & 1)) << @as(u5, @intCast(footer));
                if (slot < kEndPosModelIndex) {
                    const off = dist0 - slot;
                    var m: u32 = 1;
                    var add: u32 = 0;
                    var i: u6 = 0;
                    while (i < footer) : (i += 1) {
                        const b = rc.decodeBit(&spec_pos[off + m]);
                        m = (m << 1) | b;
                        add |= @as(u32, b) << @intCast(i);
                    }
                    dist0 += add;
                } else {
                    dist0 += rc.decodeDirect(footer - kNumAlignBits) << kNumAlignBits;
                    dist0 += rc.decodeTreeReverse(align_probs[0..], kNumAlignBits);
                }
            }
            if (dist0 == 0xFFFF_FFFF) break;
            reps[0] = dist0;
            dist0_new = dist0;
            state = matchNextState(state);
        }
        // replay the EXACT decision through our model
        try enc.emitMatchExplicit(&rce, rep_idx, false, len, dist0_new, ps);
        const dist = reps[0] + 1;
        var k: u32 = 0;
        while (k < len) : (k += 1) {
            out[o] = out[o - dist];
            o += 1;
        }
    }
    try rce.flush();
    // write the decoded bytes so callers can verify the decoder is faithful
    if (std.fs.cwd().createFile("/tmp/transcode_out.bin", .{})) |df| {
        defer df.close();
        df.writeAll(out) catch {};
    } else |_| {}
    return eout.items.len;
}

/// Diagnostic: run the BT4 match finder up to `pos` and return the matches it
/// surfaces there — to check whether close matches are being found.
pub fn probeMatchesAt(data: []const u8, pos: usize, opt: Options, a: std.mem.Allocator, out: []Match) !usize {
    var hbits: u5 = 16;
    while ((@as(u32, 1) << hbits) < data.len and hbits < 24) hbits += 1;
    const hsize = @as(u32, 1) << hbits;
    const head = try a.alloc(i32, hsize);
    defer a.free(head);
    @memset(head, -1);
    const son = try a.alloc(i32, 2 * @max(data.len, 1));
    defer a.free(son);
    const head2 = try a.alloc(i32, 1 << 16);
    defer a.free(head2);
    @memset(head2, -1);
    const head3 = try a.alloc(i32, 1 << 16);
    defer a.free(head3);
    @memset(head3, -1);
    var enc = Encoder{ .a = a, .opt = opt, .literal = &[_]u16{}, .head = head, .son = son, .head2 = head2, .head3 = head3, .hash_mask = hsize - 1 };
    var scratch: [kMatchMaxLen + 2]Match = undefined;
    var i: usize = 0;
    while (i < pos) : (i += 1) _ = enc.getMatches(data, i, &scratch);
    return enc.getMatches(data, pos, out);
}

// ===========================================================================
// FORENSIC TOOL: an LZMA decoder that dumps token statistics. Lets us compare
// liblzma's actual parse decisions to ours on the SAME data — the only way to
// see *where* a 6% gap hides when matches, prices, and params are all identical.
// ===========================================================================
const RangeDecoder = struct {
    code: u32 = 0,
    range: u32 = 0xFFFF_FFFF,
    src: []const u8,
    pos: usize = 0,
    fn nextByte(self: *RangeDecoder) u8 {
        if (self.pos >= self.src.len) return 0;
        const b = self.src[self.pos];
        self.pos += 1;
        return b;
    }
    fn init(src: []const u8) RangeDecoder {
        var d = RangeDecoder{ .src = src };
        _ = d.nextByte();
        var i: usize = 0;
        while (i < 4) : (i += 1) d.code = (d.code << 8) | d.nextByte();
        return d;
    }
    fn decodeBit(self: *RangeDecoder, prob: *u16) u1 {
        const bound = (self.range >> kNumBitModelTotalBits) * prob.*;
        var bit: u1 = undefined;
        if (self.code < bound) {
            self.range = bound;
            updProb0(prob);
            bit = 0;
        } else {
            self.code -= bound;
            self.range -= bound;
            updProb1(prob);
            bit = 1;
        }
        while (self.range < kTopValue) {
            self.range <<= 8;
            self.code = (self.code << 8) | self.nextByte();
        }
        return bit;
    }
    fn decodeDirect(self: *RangeDecoder, num_bits: u6) u32 {
        var res: u32 = 0;
        var i: u6 = num_bits;
        while (i != 0) : (i -= 1) {
            self.range >>= 1;
            self.code -%= self.range;
            const t: u32 = 0 -% (self.code >> 31);
            self.code +%= self.range & t;
            while (self.range < kTopValue) {
                self.range <<= 8;
                self.code = (self.code << 8) | self.nextByte();
            }
            res = (res << 1) +% (t +% 1);
        }
        return res;
    }
    fn decodeTree(self: *RangeDecoder, probs: []u16, num_bits: u6) u32 {
        var m: u32 = 1;
        var i: u6 = 0;
        while (i < num_bits) : (i += 1) m = (m << 1) | self.decodeBit(&probs[m]);
        return m - (@as(u32, 1) << @as(u5, @intCast(num_bits)));
    }
    fn decodeTreeReverse(self: *RangeDecoder, probs: []u16, num_bits: u6) u32 {
        var m: u32 = 1;
        var res: u32 = 0;
        var i: u6 = 0;
        while (i < num_bits) : (i += 1) {
            const b = self.decodeBit(&probs[m]);
            m = (m << 1) | b;
            res |= @as(u32, b) << @intCast(i);
        }
        return res;
    }
};

/// Decode a standalone .lzma (LZMA_alone) stream produced by compress/compressOpt/
/// compressOptK back to the original bytes. Pure Zig — no liblzma needed. For
/// unknown-size streams pass `known_size`. Caller owns the returned slice.
pub fn decode(stream: []const u8, a: std.mem.Allocator, known_size: ?usize) ![]u8 {
    if (stream.len < 13) return error.Truncated;
    const props = stream[0];
    const lc: u4 = @intCast(props % 9);
    const r = props / 9;
    const lp: u4 = @intCast(r % 5);
    const pb: u4 = @intCast(r / 5);
    const raw_size = std.mem.readInt(u64, stream[5..13], .little);
    const out_size: usize = if (raw_size == std.math.maxInt(u64)) (known_size orelse return error.UnknownSize) else @intCast(raw_size);

    const out = try a.alloc(u8, out_size);
    errdefer a.free(out);
    const lit = try a.alloc(u16, @as(usize, 0x300) << @intCast(lc + lp));
    defer a.free(lit);
    @memset(lit, kProbInit);
    var is_match = [_]u16{kProbInit} ** (kNumStates << kNumPosBitsMax);
    var is_rep = [_]u16{kProbInit} ** kNumStates;
    var is_rep_g0 = [_]u16{kProbInit} ** kNumStates;
    var is_rep_g1 = [_]u16{kProbInit} ** kNumStates;
    var is_rep_g2 = [_]u16{kProbInit} ** kNumStates;
    var is_rep0_long = [_]u16{kProbInit} ** (kNumStates << kNumPosBitsMax);
    var pos_slot = [_][1 << 6]u16{[_]u16{kProbInit} ** (1 << 6)} ** kNumLenToPosStates;
    var spec_pos = [_]u16{kProbInit} ** (kNumFullDistances - kEndPosModelIndex + 1);
    var align_probs = [_]u16{kProbInit} ** kAlignTableSize;
    var len_coder = DecLenCoder{};
    var rep_len_coder = DecLenCoder{};

    var rc = RangeDecoder.init(stream[13..]);
    var state: u32 = 0;
    var reps = [4]u32{ 0, 0, 0, 0 };
    const pb_mask: u32 = (@as(u32, 1) << pb) - 1;
    const lp_mask: u32 = (@as(u32, 1) << lp) - 1;
    var o: usize = 0;
    while (o < out_size) {
        const pos_state = @as(u32, @intCast(o)) & pb_mask;
        const im = (state << kNumPosBitsMax) + pos_state;
        if (rc.decodeBit(&is_match[im]) == 0) {
            const prev: u8 = if (o == 0) 0 else out[o - 1];
            const idx = 0x300 * (((@as(u32, @intCast(o)) & lp_mask) << lc) + (@as(u32, prev) >> @intCast(8 - lc)));
            const probs = lit[idx..][0..0x300];
            var sym: u32 = 1;
            if (state < 7) {
                while (sym < 0x100) sym = (sym << 1) | rc.decodeBit(&probs[sym]);
            } else {
                var mb: u32 = out[o - (reps[0] + 1)];
                while (sym < 0x100) {
                    mb <<= 1;
                    const match_bit = mb & 0x100;
                    const b = rc.decodeBit(&probs[0x100 + match_bit + sym]);
                    sym = (sym << 1) | b;
                    if (match_bit != (@as(u32, b) << 8)) {
                        while (sym < 0x100) sym = (sym << 1) | rc.decodeBit(&probs[sym]);
                        break;
                    }
                }
            }
            out[o] = @intCast(sym & 0xFF);
            o += 1;
            state = litNextState(state);
            continue;
        }
        var len: u32 = undefined;
        if (rc.decodeBit(&is_rep[state]) == 1) {
            if (rc.decodeBit(&is_rep_g0[state]) == 0) {
                if (rc.decodeBit(&is_rep0_long[im]) == 0) {
                    state = shortRepNextState(state);
                    out[o] = out[o - (reps[0] + 1)];
                    o += 1;
                    continue;
                }
            } else {
                var dist: u32 = undefined;
                if (rc.decodeBit(&is_rep_g1[state]) == 0) {
                    dist = reps[1];
                    reps[1] = reps[0];
                } else if (rc.decodeBit(&is_rep_g2[state]) == 0) {
                    dist = reps[2];
                    reps[2] = reps[1];
                    reps[1] = reps[0];
                } else {
                    dist = reps[3];
                    reps[3] = reps[2];
                    reps[2] = reps[1];
                    reps[1] = reps[0];
                }
                reps[0] = dist;
            }
            len = rep_len_coder.decode(&rc, pos_state) + kMatchMinLen;
            state = repNextState(state);
        } else {
            reps[3] = reps[2];
            reps[2] = reps[1];
            reps[1] = reps[0];
            len = len_coder.decode(&rc, pos_state) + kMatchMinLen;
            const len_state = @min(len - kMatchMinLen, kNumLenToPosStates - 1);
            const slot = rc.decodeTree(pos_slot[len_state][0..], 6);
            var dist0: u32 = slot;
            if (slot >= kStartPosModelIndex) {
                const footer: u6 = @intCast((slot >> 1) - 1);
                dist0 = (2 | (slot & 1)) << @as(u5, @intCast(footer));
                if (slot < kEndPosModelIndex) {
                    const off = dist0 - slot;
                    var m: u32 = 1;
                    var add: u32 = 0;
                    var i: u6 = 0;
                    while (i < footer) : (i += 1) {
                        const b = rc.decodeBit(&spec_pos[off + m]);
                        m = (m << 1) | b;
                        add |= @as(u32, b) << @intCast(i);
                    }
                    dist0 += add;
                } else {
                    dist0 += rc.decodeDirect(footer - kNumAlignBits) << kNumAlignBits;
                    dist0 += rc.decodeTreeReverse(align_probs[0..], kNumAlignBits);
                }
            }
            if (dist0 == 0xFFFF_FFFF) break;
            reps[0] = dist0;
            state = matchNextState(state);
        }
        const dist = reps[0] + 1;
        if (dist > o) return error.BadDistance;
        var k: u32 = 0;
        while (k < len and o < out_size) : (k += 1) {
            out[o] = out[o - dist];
            o += 1;
        }
    }
    return out;
}

test "compressOptK round-trips through our own decoder" {
    const al = std.testing.allocator;
    var buf: [8192]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast((i * 7 + (i / 13)) & 0xFF);
    const z = try compressOptK(&buf, al, .{ .kbest = 8 });
    defer al.free(z);
    const back = try decode(z, al, null);
    defer al.free(back);
    try std.testing.expectEqualSlices(u8, &buf, back);
}

pub const TokenStats = struct {
    out_len: usize = 0,
    n_lit: u64 = 0,
    n_newmatch: u64 = 0,
    n_rep: u64 = 0, // rep0..3 with len>=2
    n_shortrep: u64 = 0,
    newmatch_bytes: u64 = 0,
    rep_bytes: u64 = 0,
    rep0_used: u64 = 0,
    rep_far_used: u64 = 0, // rep1/2/3
    sum_newmatch_dist: u64 = 0,
};

const DecLenCoder = struct {
    choice: u16 = kProbInit,
    choice2: u16 = kProbInit,
    low: [1 << kNumPosBitsMax][8]u16 = [_][8]u16{[_]u16{kProbInit} ** 8} ** (1 << kNumPosBitsMax),
    mid: [1 << kNumPosBitsMax][8]u16 = [_][8]u16{[_]u16{kProbInit} ** 8} ** (1 << kNumPosBitsMax),
    high: [256]u16 = [_]u16{kProbInit} ** 256,
    fn decode(self: *DecLenCoder, rc: *RangeDecoder, pos_state: u32) u32 {
        if (rc.decodeBit(&self.choice) == 0) return rc.decodeTree(self.low[pos_state][0..], 3);
        if (rc.decodeBit(&self.choice2) == 0) return 8 + rc.decodeTree(self.mid[pos_state][0..], 3);
        return 16 + rc.decodeTree(self.high[0..], 8);
    }
};

/// Decode a .lzma (alone) stream and return token statistics. For unknown-size
/// streams (liblzma writes size = u64 max + an end marker) pass `known_size`.
pub fn dumpStats(stream: []const u8, a: std.mem.Allocator, known_size: ?usize, tok: ?*std.ArrayList(u8)) !TokenStats {
    if (stream.len < 13) return error.Truncated;
    const props = stream[0];
    const lc: u4 = @intCast(props % 9);
    const r = props / 9;
    const lp: u4 = @intCast(r % 5);
    const pb: u4 = @intCast(r / 5);
    const raw_size = std.mem.readInt(u64, stream[5..13], .little);
    const out_size: usize = if (raw_size == std.math.maxInt(u64)) (known_size orelse return error.UnknownSize) else @intCast(raw_size);

    const out = try a.alloc(u8, out_size);
    defer a.free(out);
    const lit = try a.alloc(u16, @as(usize, 0x300) << @intCast(lc + lp));
    defer a.free(lit);
    @memset(lit, kProbInit);

    var is_match = [_]u16{kProbInit} ** (kNumStates << kNumPosBitsMax);
    var is_rep = [_]u16{kProbInit} ** kNumStates;
    var is_rep_g0 = [_]u16{kProbInit} ** kNumStates;
    var is_rep_g1 = [_]u16{kProbInit} ** kNumStates;
    var is_rep_g2 = [_]u16{kProbInit} ** kNumStates;
    var is_rep0_long = [_]u16{kProbInit} ** (kNumStates << kNumPosBitsMax);
    var pos_slot = [_][1 << 6]u16{[_]u16{kProbInit} ** (1 << 6)} ** kNumLenToPosStates;
    var spec_pos = [_]u16{kProbInit} ** (kNumFullDistances - kEndPosModelIndex + 1);
    var align_probs = [_]u16{kProbInit} ** kAlignTableSize;
    var len_coder = DecLenCoder{};
    var rep_len_coder = DecLenCoder{};

    var rc = RangeDecoder.init(stream[13..]);
    var st: TokenStats = .{ .out_len = out_size };
    var state: u32 = 0;
    var reps = [4]u32{ 0, 0, 0, 0 };
    const pb_mask: u32 = (@as(u32, 1) << pb) - 1;
    const lp_mask: u32 = (@as(u32, 1) << lp) - 1;
    var o: usize = 0;
    while (o < out_size) {
        const tpos = o;
        const pos_state = @as(u32, @intCast(o)) & pb_mask;
        const im = (state << kNumPosBitsMax) + pos_state;
        if (rc.decodeBit(&is_match[im]) == 0) {
            const prev: u8 = if (o == 0) 0 else out[o - 1];
            const idx = 0x300 * (((@as(u32, @intCast(o)) & lp_mask) << lc) + (@as(u32, prev) >> @intCast(8 - lc)));
            const probs = lit[idx..][0..0x300];
            var sym: u32 = 1;
            if (state < 7) {
                while (sym < 0x100) sym = (sym << 1) | rc.decodeBit(&probs[sym]);
            } else {
                var mb: u32 = out[o - (reps[0] + 1)];
                while (sym < 0x100) {
                    mb <<= 1;
                    const match_bit = mb & 0x100;
                    const b = rc.decodeBit(&probs[0x100 + match_bit + sym]);
                    sym = (sym << 1) | b;
                    if (match_bit != (@as(u32, b) << 8)) {
                        while (sym < 0x100) sym = (sym << 1) | rc.decodeBit(&probs[sym]);
                        break;
                    }
                }
            }
            out[o] = @intCast(sym & 0xFF);
            o += 1;
            state = litNextState(state);
            st.n_lit += 1;
            if (tok) |t| try t.writer().print("{d} L 1 0\n", .{tpos});
            continue;
        }
        var len: u32 = undefined;
        if (rc.decodeBit(&is_rep[state]) == 1) {
            if (rc.decodeBit(&is_rep_g0[state]) == 0) {
                if (rc.decodeBit(&is_rep0_long[im]) == 0) {
                    state = shortRepNextState(state);
                    if (tok) |t| try t.writer().print("{d} S 1 {d}\n", .{ tpos, reps[0] + 1 });
                    out[o] = out[o - (reps[0] + 1)];
                    o += 1;
                    st.n_shortrep += 1;
                    continue;
                }
                st.rep0_used += 1;
            } else {
                var dist: u32 = undefined;
                if (rc.decodeBit(&is_rep_g1[state]) == 0) {
                    dist = reps[1];
                    reps[1] = reps[0];
                } else if (rc.decodeBit(&is_rep_g2[state]) == 0) {
                    dist = reps[2];
                    reps[2] = reps[1];
                    reps[1] = reps[0];
                } else {
                    dist = reps[3];
                    reps[3] = reps[2];
                    reps[2] = reps[1];
                    reps[1] = reps[0];
                }
                reps[0] = dist;
                st.rep_far_used += 1;
            }
            len = rep_len_coder.decode(&rc, pos_state) + kMatchMinLen;
            state = repNextState(state);
            st.n_rep += 1;
            st.rep_bytes += len;
            if (tok) |t| try t.writer().print("{d} R {d} {d}\n", .{ tpos, len, reps[0] + 1 });
        } else {
            reps[3] = reps[2];
            reps[2] = reps[1];
            reps[1] = reps[0];
            len = len_coder.decode(&rc, pos_state) + kMatchMinLen;
            const len_state = @min(len - kMatchMinLen, kNumLenToPosStates - 1);
            const slot = rc.decodeTree(pos_slot[len_state][0..], 6);
            var dist0: u32 = slot;
            if (slot >= kStartPosModelIndex) {
                const footer: u6 = @intCast((slot >> 1) - 1);
                dist0 = (2 | (slot & 1)) << @as(u5, @intCast(footer));
                if (slot < kEndPosModelIndex) {
                    const off = dist0 - slot;
                    // reverse tree on spec_pos[off..]
                    var m: u32 = 1;
                    var add: u32 = 0;
                    var i: u6 = 0;
                    while (i < footer) : (i += 1) {
                        const b = rc.decodeBit(&spec_pos[off + m]);
                        m = (m << 1) | b;
                        add |= @as(u32, b) << @intCast(i);
                    }
                    dist0 += add;
                } else {
                    dist0 += rc.decodeDirect(footer - kNumAlignBits) << kNumAlignBits;
                    dist0 += rc.decodeTreeReverse(align_probs[0..], kNumAlignBits);
                }
            }
            if (dist0 == 0xFFFF_FFFF) break; // end-of-stream marker
            reps[0] = dist0;
            st.n_newmatch += 1;
            st.newmatch_bytes += len;
            st.sum_newmatch_dist += dist0 + 1;
            if (tok) |t| try t.writer().print("{d} M {d} {d}\n", .{ tpos, len, dist0 + 1 });
            state = matchNextState(state);
        }
        // copy len bytes from reps[0]
        const dist = reps[0] + 1;
        var k: u32 = 0;
        while (k < len) : (k += 1) {
            out[o] = out[o - dist];
            o += 1;
        }
    }
    return st;
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

//! BCJ2 — 7-Zip's x86 branch converter, version 2.
//!
//! In-place BCJ (the LZMA_FILTER_X86 we already use in full mode) rewrites every
//! E8/E9 relative branch operand to an absolute address in a single stream. That
//! helps LZMA find matches in addresses, but it also converts false positives
//! (E8/E9 bytes that aren't really branches) and leaves the 4 address bytes in
//! the main stream where they look random.
//!
//! BCJ2 does better by splitting the data into FOUR streams:
//!   - main : the original bytes, but with the 4-byte operand of every CONVERTED
//!            branch removed (so the main stream has far fewer "random" bytes).
//!   - call : 4-byte big-endian ABSOLUTE addresses of converted E8 (CALL).
//!   - jump : 4-byte big-endian ABSOLUTE addresses of converted E9/0F8x (JMP/Jcc).
//!   - rc   : a range-coded control bit per E8/E9/0F8x saying whether it was
//!            converted. The bit is modeled with an adaptive probability per
//!            context (previous byte for E8), so on real code it costs ~nothing.
//!
//! Splitting addresses into their own streams (which cluster) and keeping the
//! conversion decision out of the main stream is what gives BCJ2 its edge over
//! in-place BCJ on real binaries. The caller LZMA-compresses main/call/jump
//! separately; rc is already entropy-coded.
//!
//! Pure transform — no compression here. encode/decode are exact inverses; this
//! file owns the range coder and the x86 scan only.

const std = @import("std");

// ---- LZMA-style binary range coder ----------------------------------------

const kTopValue: u32 = 1 << 24;
const kNumBitModelTotalBits: u5 = 11;
const kBitModelTotal: u32 = 1 << 11; // 2048
const kNumMoveBits: u5 = 5;
const kProbInit: u16 = kBitModelTotal / 2; // 1024

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

    fn encodeBit(self: *RangeEncoder, prob: *u16, bit: u1) !void {
        const bound = (self.range >> kNumBitModelTotalBits) * prob.*;
        if (bit == 0) {
            self.range = bound;
            prob.* += @intCast((kBitModelTotal - prob.*) >> kNumMoveBits);
        } else {
            self.low += bound;
            self.range -= bound;
            prob.* -= @intCast(prob.* >> kNumMoveBits);
        }
        while (self.range < kTopValue) {
            self.range <<= 8;
            try self.shiftLow();
        }
    }

    fn flush(self: *RangeEncoder) !void {
        var i: usize = 0;
        while (i < 5) : (i += 1) try self.shiftLow();
    }
};

const RangeDecoder = struct {
    code: u32 = 0,
    range: u32 = 0xFFFF_FFFF,
    src: []const u8,
    pos: usize = 0,

    fn nextByte(self: *RangeDecoder) u8 {
        if (self.pos >= self.src.len) return 0; // ran dry — treated as 0 padding
        const b = self.src[self.pos];
        self.pos += 1;
        return b;
    }

    fn init(src: []const u8) RangeDecoder {
        var d = RangeDecoder{ .src = src };
        _ = d.nextByte(); // first byte is always 0
        var i: usize = 0;
        while (i < 4) : (i += 1) d.code = (d.code << 8) | d.nextByte();
        return d;
    }

    fn decodeBit(self: *RangeDecoder, prob: *u16) u1 {
        const bound = (self.range >> kNumBitModelTotalBits) * prob.*;
        var bit: u1 = undefined;
        if (self.code < bound) {
            self.range = bound;
            prob.* += @intCast((kBitModelTotal - prob.*) >> kNumMoveBits);
            bit = 0;
        } else {
            self.code -= bound;
            self.range -= bound;
            prob.* -= @intCast(prob.* >> kNumMoveBits);
            bit = 1;
        }
        while (self.range < kTopValue) {
            self.range <<= 8;
            self.code = (self.code << 8) | self.nextByte();
        }
        return bit;
    }
};

// ---- x86 branch scan -------------------------------------------------------

// Probability slots: index 0 = E9 (JMP), 1 = 0F8x (Jcc), 2+prevByte = E8 (CALL).
const NUM_PROBS = 2 + 256;

/// True when an x86 branch's relative-operand MSByte (b[3]) marks a likely-real
/// near branch — the standard BCJ heuristic (operand points within ±16 MB).
inline fn test86MSByte(b: u8) bool {
    return b == 0x00 or b == 0xFF;
}

/// Is `b0` (with `prev` the preceding byte) the start of a convertible x86
/// branch with a 4-byte rel32 operand? Returns the prob slot index, or null.
inline fn branchProbIndex(b0: u8, prev: u8) ?usize {
    if (b0 == 0xE8) return 2 + @as(usize, prev); // CALL rel32
    if (b0 == 0xE9) return 0; // JMP rel32
    return null;
}

pub const Streams = struct {
    main: []u8,
    call: []u8,
    jump: []u8,
    rc: []u8,

    pub fn deinit(self: *Streams, a: std.mem.Allocator) void {
        a.free(self.main);
        a.free(self.call);
        a.free(self.jump);
        a.free(self.rc);
    }
};

/// Split `src` into the four BCJ2 streams. The 0F8x (Jcc) form is handled too:
/// a 2-byte opcode 0F 80..8F followed by rel32. All owned; caller frees.
pub fn encode(src: []const u8, a: std.mem.Allocator) !Streams {
    var main = std.ArrayList(u8).init(a);
    errdefer main.deinit();
    var call = std.ArrayList(u8).init(a);
    errdefer call.deinit();
    var jump = std.ArrayList(u8).init(a);
    errdefer jump.deinit();
    var rc_buf = std.ArrayList(u8).init(a);
    errdefer rc_buf.deinit();

    var probs = [_]u16{kProbInit} ** NUM_PROBS;
    var enc = RangeEncoder{ .out = &rc_buf };

    var i: usize = 0;
    while (i < src.len) {
        const b0 = src[i];
        const prev: u8 = if (i > 0) src[i - 1] else 0;

        // Detect E8/E9 (1-byte opcode) or 0F 8x (2-byte Jcc) with room for rel32.
        var is_jcc = false;
        var prob_idx: ?usize = branchProbIndex(b0, prev);
        if (prob_idx == null and b0 == 0x0F and i + 1 < src.len and (src[i + 1] & 0xF0) == 0x80) {
            is_jcc = true;
            prob_idx = 1;
        }

        if (prob_idx) |pi| {
            const op_len: usize = if (is_jcc) 2 else 1; // bytes before the rel32
            const opnd = i + op_len;
            if (opnd + 4 <= src.len) {
                // Always emit the opcode byte(s) to main first.
                try main.append(b0);
                if (is_jcc) try main.append(src[i + 1]);

                const rel = std.mem.readInt(u32, src[opnd..][0..4], .little);
                const msb: u8 = @truncate(rel >> 24);
                const convert = test86MSByte(msb);
                try enc.encodeBit(&probs[pi], @intFromBool(convert));
                if (convert) {
                    // abs = rel + (position just AFTER the full instruction)
                    const abs = rel +% @as(u32, @truncate(opnd + 4));
                    var be: [4]u8 = undefined;
                    std.mem.writeInt(u32, &be, abs, .big);
                    if (b0 == 0xE8) {
                        try call.appendSlice(&be);
                    } else {
                        try jump.appendSlice(&be);
                    }
                    // 4 operand bytes are removed from main.
                    i = opnd + 4;
                    continue;
                } else {
                    // Not converted: operand stays in main verbatim.
                    try main.appendSlice(src[opnd..][0..4]);
                    i = opnd + 4;
                    continue;
                }
            }
        }

        try main.append(b0);
        i += 1;
    }

    try enc.flush();

    return .{
        .main = try main.toOwnedSlice(),
        .call = try call.toOwnedSlice(),
        .jump = try jump.toOwnedSlice(),
        .rc = try rc_buf.toOwnedSlice(),
    };
}

/// Reconstruct the original bytes from the four streams. `out_len` is the known
/// original length (stored by the caller).
pub fn decode(
    main: []const u8,
    call: []const u8,
    jump: []const u8,
    rc: []const u8,
    out_len: usize,
    a: std.mem.Allocator,
) ![]u8 {
    var out = try a.alloc(u8, out_len);
    errdefer a.free(out);

    var probs = [_]u16{kProbInit} ** NUM_PROBS;
    var dec = RangeDecoder.init(rc);

    var mi: usize = 0; // main read cursor
    var ci: usize = 0; // call read cursor
    var ji: usize = 0; // jump read cursor
    var o: usize = 0; // output write cursor

    while (o < out_len) {
        if (mi >= main.len) return error.CorruptBcj2; // truncated main stream
        const b0 = main[mi];
        mi += 1;
        const prev: u8 = if (o > 0) out[o - 1] else 0;
        out[o] = b0;
        o += 1;

        var is_jcc = false;
        var prob_idx: ?usize = branchProbIndex(b0, prev);
        if (prob_idx == null and b0 == 0x0F and mi < main.len and (main[mi] & 0xF0) == 0x80) {
            // Peek: a 0F followed by 8x in the main stream is a Jcc only if the
            // encoder treated it as one. The encoder always wrote the 8x byte to
            // main right after 0F, and only branches with room for a rel32 were
            // modeled — but a 0F8x at the very tail (no operand room) was NOT
            // modeled. We mirror that by requiring 4 more output bytes to fit.
            if (o + 1 + 4 <= out_len) {
                is_jcc = true;
                prob_idx = 1;
            }
        }

        if (prob_idx) |pi| {
            // E8/E9 at the tail (no operand room) were not modeled by the encoder.
            if (!is_jcc and o + 4 > out_len) {
                // Unmodeled tail E8/E9 — bytes (if any) are plain main bytes.
                continue;
            }
            if (is_jcc) {
                // Emit the 8x byte from main (room already verified above).
                out[o] = main[mi];
                mi += 1;
                o += 1;
            }

            const bit = dec.decodeBit(&probs[pi]);
            if (bit == 1) {
                if (b0 == 0xE8) {
                    if (ci + 4 > call.len) return error.CorruptBcj2;
                } else {
                    if (ji + 4 > jump.len) return error.CorruptBcj2;
                }
                const be = if (b0 == 0xE8) call[ci..][0..4] else jump[ji..][0..4];
                if (b0 == 0xE8) ci += 4 else ji += 4;
                const abs = std.mem.readInt(u32, be, .big);
                const rel = abs -% @as(u32, @truncate(o + 4));
                std.mem.writeInt(u32, out[o..][0..4], rel, .little);
                o += 4;
            } else {
                // Operand was left in main verbatim.
                if (mi + 4 > main.len) return error.CorruptBcj2;
                @memcpy(out[o..][0..4], main[mi..][0..4]);
                mi += 4;
                o += 4;
            }
        }
    }

    return out;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "BCJ2 range coder + transform is an exact involution (random + code-like)" {
    const a = testing.allocator;
    var rng = @import("math_gen.zig").XorShift32.init(0xB1C2);

    // Several payloads: pure random, and "code-like" with many E8/E9/0F8x.
    var cases = std.ArrayList([]u8).init(a);
    defer {
        for (cases.items) |c| a.free(c);
        cases.deinit();
    }

    // pure random
    {
        const buf = try a.alloc(u8, 20000);
        for (buf) |*p| p.* = rng.nextByte();
        try cases.append(buf);
    }
    // code-like: scatter E8/E9/0F8x with plausible near operands
    {
        const buf = try a.alloc(u8, 40000);
        for (buf) |*p| p.* = rng.nextByte();
        var i: usize = 0;
        while (i + 8 < buf.len) : (i += 17) {
            const pick = rng.nextByte() % 3;
            if (pick == 0) {
                buf[i] = 0xE8;
            } else if (pick == 1) {
                buf[i] = 0xE9;
            } else {
                buf[i] = 0x0F;
                buf[i + 1] = 0x80 | (rng.nextByte() & 0x0F);
            }
            // near operand: MSByte 0x00 or 0xFF so it converts
            buf[i + 4] = if (rng.nextByte() & 1 == 0) 0x00 else 0xFF;
        }
        try cases.append(buf);
    }
    // edge: branch opcodes right at the tail (no operand room)
    {
        const buf = try a.alloc(u8, 10);
        for (buf) |*p| p.* = 0xE8;
        try cases.append(buf);
    }

    for (cases.items) |data| {
        var s = try encode(data, a);
        defer s.deinit(a);
        const back = try decode(s.main, s.call, s.jump, s.rc, data.len, a);
        defer a.free(back);
        try testing.expectEqualSlices(u8, data, back);
    }
}

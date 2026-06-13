//! vm.zig — The Mathpressor Bytecode Interpreter.
//!
//! Assets are stored as tiny mathematical programs. This VM walks the bytecode
//! and *synthesises* the asset directly into memory — no decompression, no
//! dictionary look-ups. Every operation is deterministic integer arithmetic.
//!
//! Memory contract: the VM never owns a global allocator. The caller hands it
//! an allocator (an ArenaAllocator in production) and owns the lifetime.

const std = @import("std");
const math_gen = @import("math_gen.zig");

// ---------------------------------------------------------------------------
// Instruction Set Architecture
// ---------------------------------------------------------------------------

/// Mathpressor opcodes. Non-exhaustive (`_`) so stray bytes map to an error.
pub const Opcode = enum(u8) {
    /// 0x01 — u32 seed. Reseeds the deterministic PRNG.
    seed = 0x01,
    /// 0x02 — u8 dst, u16 w, u16 h, u8 freq.
    /// Generates fractal integer noise into slot `dst`; makes it current.
    int_noise = 0x02,
    /// 0x03 — no payload. Inverts the current buffer (255 − p).
    invert = 0x03,
    /// 0x04 — i16 value. Saturating brightness add to every pixel.
    add_const = 0x04,
    /// 0x05 — u8 src. Multiply current buffer by slot `src`: cur*src/255.
    blend_mult = 0x05,
    /// 0x06 — u8 src, u8 dst. Copy slot `src` to slot `dst`; selects `dst`.
    copy = 0x06,
    /// 0x07 — u8 steps, u8 birth_limit, u8 survive_limit.
    /// Run Moore-neighbourhood cellular automata on the current buffer.
    cellular = 0x07,
    /// 0x08 — u8 src_slot, u8 strength.
    /// Domain-warp the current buffer using slot `src_slot` as displacement.
    warp = 0x08,
    /// 0x09 — u8 lo, u8 hi.
    /// Contrast-stretch: remap [lo,hi] → [0,255], clamp outside.
    level = 0x09,
    /// 0x0A — u8 pivot. Values < pivot → 0; values ≥ pivot → 255.
    threshold = 0x0A,
    /// 0x0B — u8 src_slot, u8 alpha.
    /// Alpha-blend: cur = cur*(255−alpha)/255 + src*alpha/255.
    mix = 0x0B,
    /// 0x0C — u8 dst, u16 w, u16 h, u8 value.
    /// Fill slot `dst` with a constant byte; makes it current. Matches real-
    /// world padding/sparse sections (zero pages, 0xFF flash images).
    const_fill = 0x0C,
    /// 0x0D — u8 dst, u16 w, u16 h, u8 start, u8 step.
    /// Linear byte ramp over the flat buffer: buf[i] = start + step·i (mod 256).
    /// Matches lookup tables and index ramps common in binary formats.
    ramp = 0x0D,
    /// 0x0E — u8 dst, u16 w, u16 h, u8 plen, then plen literal bytes.
    /// Tile a short literal pattern over the flat buffer: buf[i] = pat[i % plen].
    /// Matches repeated structs / fixed-stride records.
    repeat = 0x0E,
    /// 0xFF — no payload. Ends execution and locks the current buffer.
    halt = 0xFF,
    _,
};

pub const SLOT_COUNT = 4;
pub const MAX_DIM = 4096;

pub const VmError = error{
    InvalidOpcode,
    UnexpectedEnd,
    SlotOutOfRange,
    CanvasUninitialized,
    DimensionMismatch,
    InvalidDimensions,
    NoOutput,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Virtual machine
// ---------------------------------------------------------------------------

pub const Vm = struct {
    allocator: std.mem.Allocator,
    prng: math_gen.XorShift32,
    width: u32 = 0,
    height: u32 = 0,
    slots: [SLOT_COUNT]?[]u8 = .{null} ** SLOT_COUNT,
    cur: u8 = 0,
    halted: bool = false,

    pub fn init(allocator: std.mem.Allocator) Vm {
        return .{
            .allocator = allocator,
            .prng = math_gen.XorShift32.init(1),
        };
    }

    fn canvasLen(self: *const Vm) usize {
        return @as(usize, self.width) * @as(usize, self.height);
    }

    fn ensureSlot(self: *Vm, idx: u8) VmError![]u8 {
        if (idx >= SLOT_COUNT) return VmError.SlotOutOfRange;
        if (self.slots[idx]) |buf| return buf;
        const buf = self.allocator.alloc(u8, self.canvasLen()) catch return VmError.OutOfMemory;
        @memset(buf, 0);
        self.slots[idx] = buf;
        return buf;
    }

    fn curBuf(self: *Vm) VmError![]u8 {
        if (self.width == 0) return VmError.CanvasUninitialized;
        return self.slots[self.cur] orelse VmError.CanvasUninitialized;
    }

    /// Execute `code` to completion. Returns the locked pixel buffer on success
    /// (a view into VM-owned memory, valid until the backing allocator is freed).
    pub fn execute(self: *Vm, code: []const u8) VmError![]const u8 {
        var ip: usize = 0;
        while (ip < code.len) {
            const op: Opcode = @enumFromInt(code[ip]);
            ip += 1;
            switch (op) {
                .seed => {
                    self.prng = math_gen.XorShift32.init(try readU32(code, &ip));
                },
                .int_noise => {
                    const dst = try readU8(code, &ip);
                    const w = try readU16(code, &ip);
                    const h = try readU16(code, &ip);
                    const freq = try readU8(code, &ip);
                    try self.opIntNoise(dst, w, h, freq);
                },
                .invert => {
                    const buf = try self.curBuf();
                    for (buf) |*p| p.* = 255 - p.*;
                },
                .add_const => {
                    const v = try readI16(code, &ip);
                    const buf = try self.curBuf();
                    for (buf) |*p| p.* = clampU8(@as(i32, p.*) + v);
                },
                .blend_mult => {
                    try self.opBlendMult(try readU8(code, &ip));
                },
                .copy => {
                    const src = try readU8(code, &ip);
                    const dst = try readU8(code, &ip);
                    try self.opCopy(src, dst);
                },
                .cellular => {
                    const steps = try readU8(code, &ip);
                    const birth = try readU8(code, &ip);
                    const survive = try readU8(code, &ip);
                    try self.opCellular(steps, birth, survive);
                },
                .warp => {
                    const src = try readU8(code, &ip);
                    const strength = try readU8(code, &ip);
                    try self.opWarp(src, strength);
                },
                .level => {
                    const lo = try readU8(code, &ip);
                    const hi = try readU8(code, &ip);
                    const buf = try self.curBuf();
                    math_gen.levelRemap(buf, lo, hi);
                },
                .threshold => {
                    const pivot = try readU8(code, &ip);
                    const buf = try self.curBuf();
                    for (buf) |*p| p.* = if (p.* >= pivot) 255 else 0;
                },
                .mix => {
                    const src = try readU8(code, &ip);
                    const alpha = try readU8(code, &ip);
                    try self.opMix(src, alpha);
                },
                .const_fill => {
                    const dst = try readU8(code, &ip);
                    const w = try readU16(code, &ip);
                    const h = try readU16(code, &ip);
                    const value = try readU8(code, &ip);
                    const buf = try self.initCanvasSlot(dst, w, h);
                    @memset(buf, value);
                },
                .ramp => {
                    const dst = try readU8(code, &ip);
                    const w = try readU16(code, &ip);
                    const h = try readU16(code, &ip);
                    const start = try readU8(code, &ip);
                    const step = try readU8(code, &ip);
                    const buf = try self.initCanvasSlot(dst, w, h);
                    // (step·i) mod 256 == (step ·% (i mod 256)) — u8 wrap is exact.
                    for (buf, 0..) |*p, i| p.* = start +% (step *% @as(u8, @truncate(i)));
                },
                .repeat => {
                    const dst = try readU8(code, &ip);
                    const w = try readU16(code, &ip);
                    const h = try readU16(code, &ip);
                    const plen = try readU8(code, &ip);
                    if (plen == 0) return VmError.InvalidDimensions;
                    if (ip + plen > code.len) return VmError.UnexpectedEnd;
                    const pat = code[ip..][0..plen];
                    ip += plen;
                    const buf = try self.initCanvasSlot(dst, w, h);
                    for (buf, 0..) |*p, i| p.* = pat[i % plen];
                },
                .halt => {
                    self.halted = true;
                    return self.curBuf();
                },
                _ => return VmError.InvalidOpcode,
            }
        }
        return VmError.NoOutput;
    }

    /// Shared canvas-establishing prologue for buffer-producing ops: validates
    /// dims, locks the canvas size, allocates the slot, and selects it.
    fn initCanvasSlot(self: *Vm, dst: u8, w: u16, h: u16) VmError![]u8 {
        if (dst >= SLOT_COUNT) return VmError.SlotOutOfRange;
        if (w == 0 or h == 0 or w > MAX_DIM or h > MAX_DIM) return VmError.InvalidDimensions;
        if (self.width == 0) {
            self.width = w;
            self.height = h;
        } else if (self.width != w or self.height != h) {
            return VmError.DimensionMismatch;
        }
        const buf = try self.ensureSlot(dst);
        self.cur = dst;
        return buf;
    }

    fn opIntNoise(self: *Vm, dst: u8, w: u16, h: u16, freq: u8) VmError!void {
        const buf = try self.initCanvasSlot(dst, w, h);
        const noise_seed = self.prng.next();
        math_gen.fillFractalNoise(buf, self.width, self.height, noise_seed, freq);
    }

    fn opBlendMult(self: *Vm, src: u8) VmError!void {
        if (src >= SLOT_COUNT) return VmError.SlotOutOfRange;
        const dst_buf = try self.curBuf();
        const src_buf = self.slots[src] orelse return VmError.CanvasUninitialized;
        for (dst_buf, src_buf) |*d, s| {
            d.* = @intCast((@as(u32, d.*) * @as(u32, s)) / 255);
        }
    }

    fn opCopy(self: *Vm, src: u8, dst: u8) VmError!void {
        if (src >= SLOT_COUNT or dst >= SLOT_COUNT) return VmError.SlotOutOfRange;
        const src_buf = self.slots[src] orelse return VmError.CanvasUninitialized;
        const dst_buf = try self.ensureSlot(dst);
        @memcpy(dst_buf, src_buf);
        self.cur = dst;
    }

    fn opCellular(self: *Vm, steps: u8, birth: u8, survive: u8) VmError!void {
        if (steps == 0) return;
        const buf = try self.curBuf();
        const tmp = self.allocator.alloc(u8, self.canvasLen()) catch return VmError.OutOfMemory;
        defer self.allocator.free(tmp);
        var i: u8 = 0;
        while (i < steps) : (i += 1) {
            math_gen.cellularStep(buf, tmp, self.width, self.height, birth, survive);
            @memcpy(buf, tmp);
        }
    }

    fn opWarp(self: *Vm, src: u8, strength: u8) VmError!void {
        if (src >= SLOT_COUNT) return VmError.SlotOutOfRange;
        const dst_buf = try self.curBuf();
        const disp_buf = self.slots[src] orelse return VmError.CanvasUninitialized;
        // We need a scratch copy of the *current* buffer to sample from while
        // writing warped values into it. A temporary allocation is fine; with the
        // ArenaAllocator the free is a no-op but the memory is still correctly
        // scoped to the asset's lifetime.
        const scratch = self.allocator.alloc(u8, self.canvasLen()) catch return VmError.OutOfMemory;
        defer self.allocator.free(scratch);
        @memcpy(scratch, dst_buf);
        math_gen.warpSample(dst_buf, scratch, disp_buf, self.width, self.height, strength);
    }

    fn opMix(self: *Vm, src: u8, alpha: u8) VmError!void {
        if (src >= SLOT_COUNT) return VmError.SlotOutOfRange;
        const dst_buf = try self.curBuf();
        const src_buf = self.slots[src] orelse return VmError.CanvasUninitialized;
        const ia: u32 = 255 - @as(u32, alpha); // inverse alpha
        for (dst_buf, src_buf) |*d, s| {
            d.* = @intCast(((@as(u32, d.*) * ia) + (@as(u32, s) * @as(u32, alpha))) / 255);
        }
    }
};

// ---------------------------------------------------------------------------
// Operand helpers — explicit little-endian decode → architecture independence
// ---------------------------------------------------------------------------

fn clampU8(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

fn readU8(code: []const u8, ip: *usize) VmError!u8 {
    if (ip.* + 1 > code.len) return VmError.UnexpectedEnd;
    const v = code[ip.*];
    ip.* += 1;
    return v;
}

fn readU16(code: []const u8, ip: *usize) VmError!u16 {
    if (ip.* + 2 > code.len) return VmError.UnexpectedEnd;
    const v = std.mem.readInt(u16, code[ip.*..][0..2], .little);
    ip.* += 2;
    return v;
}

fn readI16(code: []const u8, ip: *usize) VmError!i16 {
    if (ip.* + 2 > code.len) return VmError.UnexpectedEnd;
    const v = std.mem.readInt(i16, code[ip.*..][0..2], .little);
    ip.* += 2;
    return v;
}

fn readU32(code: []const u8, ip: *usize) VmError!u32 {
    if (ip.* + 4 > code.len) return VmError.UnexpectedEnd;
    const v = std.mem.readInt(u32, code[ip.*..][0..4], .little);
    ip.* += 4;
    return v;
}

// ---------------------------------------------------------------------------
// Builder — a tiny assembler for emitting valid Mathpressor bytecode.
// ---------------------------------------------------------------------------

pub const Builder = struct {
    list: std.ArrayList(u8),

    pub fn init(a: std.mem.Allocator) Builder {
        return .{ .list = std.ArrayList(u8).init(a) };
    }
    pub fn deinit(self: *Builder) void {
        self.list.deinit();
    }
    pub fn bytes(self: *const Builder) []const u8 {
        return self.list.items;
    }

    pub fn seed(self: *Builder, s: u32) !void {
        try self.list.append(@intFromEnum(Opcode.seed));
        try self.appendInt(u32, s);
    }
    pub fn intNoise(self: *Builder, dst: u8, w: u16, h: u16, freq: u8) !void {
        try self.list.append(@intFromEnum(Opcode.int_noise));
        try self.list.append(dst);
        try self.appendInt(u16, w);
        try self.appendInt(u16, h);
        try self.list.append(freq);
    }
    pub fn invert(self: *Builder) !void {
        try self.list.append(@intFromEnum(Opcode.invert));
    }
    pub fn addConst(self: *Builder, v: i16) !void {
        try self.list.append(@intFromEnum(Opcode.add_const));
        try self.appendInt(i16, v);
    }
    pub fn blendMult(self: *Builder, src: u8) !void {
        try self.list.append(@intFromEnum(Opcode.blend_mult));
        try self.list.append(src);
    }
    pub fn copy(self: *Builder, src: u8, dst: u8) !void {
        try self.list.append(@intFromEnum(Opcode.copy));
        try self.list.append(src);
        try self.list.append(dst);
    }
    pub fn cellular(self: *Builder, steps: u8, birth: u8, survive: u8) !void {
        try self.list.append(@intFromEnum(Opcode.cellular));
        try self.list.append(steps);
        try self.list.append(birth);
        try self.list.append(survive);
    }
    pub fn warp(self: *Builder, src_slot: u8, strength: u8) !void {
        try self.list.append(@intFromEnum(Opcode.warp));
        try self.list.append(src_slot);
        try self.list.append(strength);
    }
    pub fn level(self: *Builder, lo: u8, hi: u8) !void {
        try self.list.append(@intFromEnum(Opcode.level));
        try self.list.append(lo);
        try self.list.append(hi);
    }
    pub fn threshold(self: *Builder, pivot: u8) !void {
        try self.list.append(@intFromEnum(Opcode.threshold));
        try self.list.append(pivot);
    }
    pub fn mix(self: *Builder, src_slot: u8, alpha: u8) !void {
        try self.list.append(@intFromEnum(Opcode.mix));
        try self.list.append(src_slot);
        try self.list.append(alpha);
    }
    pub fn constFill(self: *Builder, dst: u8, w: u16, h: u16, value: u8) !void {
        try self.list.append(@intFromEnum(Opcode.const_fill));
        try self.list.append(dst);
        try self.appendInt(u16, w);
        try self.appendInt(u16, h);
        try self.list.append(value);
    }
    pub fn ramp(self: *Builder, dst: u8, w: u16, h: u16, start: u8, step: u8) !void {
        try self.list.append(@intFromEnum(Opcode.ramp));
        try self.list.append(dst);
        try self.appendInt(u16, w);
        try self.appendInt(u16, h);
        try self.list.append(start);
        try self.list.append(step);
    }
    pub fn repeat(self: *Builder, dst: u8, w: u16, h: u16, pattern: []const u8) !void {
        std.debug.assert(pattern.len >= 1 and pattern.len <= 255);
        try self.list.append(@intFromEnum(Opcode.repeat));
        try self.list.append(dst);
        try self.appendInt(u16, w);
        try self.appendInt(u16, h);
        try self.list.append(@intCast(pattern.len));
        try self.list.appendSlice(pattern);
    }
    pub fn halt(self: *Builder) !void {
        try self.list.append(@intFromEnum(Opcode.halt));
    }

    fn appendInt(self: *Builder, comptime T: type, v: T) !void {
        var b: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try self.list.appendSlice(&b);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn buildAndRun(arena: *std.heap.ArenaAllocator, code: []const u8) ![]const u8 {
    var m = Vm.init(arena.allocator());
    return m.execute(code);
}

test "all original opcodes still work" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.seed(0xC0FFEE);
    try b.intNoise(0, 24, 24, 4);
    try b.intNoise(1, 24, 24, 8);
    try b.blendMult(0);
    try b.addConst(20);
    try b.invert();
    try b.halt();
    const px = try buildAndRun(&arena, b.bytes());
    try testing.expectEqual(@as(usize, 24 * 24), px.len);
}

test "determinism holds across all opcodes" {
    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    var a2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a2.deinit();

    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.seed(12345);
    try b.intNoise(0, 32, 32, 4);  // base noise
    try b.intNoise(1, 32, 32, 8);  // detail noise
    try b.copy(0, 2);               // slot2 = slot0 (warp source)
    try b.warp(2, 80);              // warp slot1 by slot2
    try b.level(40, 220);           // contrast stretch
    try b.mix(0, 64);               // mix in 25% of original
    try b.threshold(128);           // binarise
    try b.cellular(3, 4, 3);        // cave smoothing
    try b.halt();

    const r1 = try buildAndRun(&a1, b.bytes());
    const r2 = try buildAndRun(&a2, b.bytes());
    try testing.expectEqualSlices(u8, r1, r2);
}

test "OP_COPY duplicates a slot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.seed(1);
    try b.intNoise(0, 16, 16, 4);
    try b.copy(0, 1);
    try b.halt();
    var m = Vm.init(arena.allocator());
    _ = try m.execute(b.bytes());
    try testing.expectEqualSlices(u8, m.slots[0].?, m.slots[1].?);
}

test "OP_THRESHOLD produces only 0 and 255" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.seed(7);
    try b.intNoise(0, 16, 16, 3);
    try b.threshold(128);
    try b.halt();
    const px = try buildAndRun(&arena, b.bytes());
    for (px) |p| try testing.expect(p == 0 or p == 255);
}

test "OP_LEVEL changes contrast deterministically" {
    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    var a2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a2.deinit();
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.seed(99);
    try b.intNoise(0, 16, 16, 4);
    try b.level(60, 200);
    try b.halt();
    const r1 = try buildAndRun(&a1, b.bytes());
    const r2 = try buildAndRun(&a2, b.bytes());
    try testing.expectEqualSlices(u8, r1, r2);
}

test "OP_WARP and OP_MIX are deterministic" {
    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    var a2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a2.deinit();
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.seed(0xABCD);
    try b.intNoise(0, 32, 32, 5);
    try b.intNoise(1, 32, 32, 3);
    try b.warp(0, 120);
    try b.mix(0, 128);
    try b.halt();
    const r1 = try buildAndRun(&a1, b.bytes());
    const r2 = try buildAndRun(&a2, b.bytes());
    try testing.expectEqualSlices(u8, r1, r2);
}

test "OP_CELLULAR smooths a binary field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.seed(42);
    try b.intNoise(0, 32, 32, 4);
    try b.threshold(128);
    try b.cellular(5, 4, 3);
    try b.halt();
    const px = try buildAndRun(&arena, b.bytes());
    for (px) |p| try testing.expect(p == 0 or p == 255);
}

test "errors: missing HALT, bad opcode, truncation, slot range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    {
        var b = Builder.init(testing.allocator);
        defer b.deinit();
        try b.intNoise(0, 8, 8, 2);
        var m = Vm.init(arena.allocator());
        try testing.expectError(VmError.NoOutput, m.execute(b.bytes()));
    }
    {
        var m = Vm.init(arena.allocator());
        try testing.expectError(VmError.InvalidOpcode, m.execute(&[_]u8{0x00}));
    }
    {
        var m = Vm.init(arena.allocator());
        try testing.expectError(VmError.UnexpectedEnd, m.execute(&[_]u8{ 0x01, 0x00 }));
    }
    {
        var b = Builder.init(testing.allocator);
        defer b.deinit();
        try b.intNoise(SLOT_COUNT, 8, 8, 2);
        try b.halt();
        var m = Vm.init(arena.allocator());
        try testing.expectError(VmError.SlotOutOfRange, m.execute(b.bytes()));
    }
}

test "OP_CONST_FILL, OP_RAMP, OP_REPEAT synthesize exactly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    {
        var b = Builder.init(testing.allocator);
        defer b.deinit();
        try b.constFill(0, 16, 16, 0xAB);
        try b.halt();
        const px = try buildAndRun(&arena, b.bytes());
        for (px) |p| try testing.expectEqual(@as(u8, 0xAB), p);
    }
    {
        var b = Builder.init(testing.allocator);
        defer b.deinit();
        try b.ramp(0, 32, 32, 5, 3);
        try b.halt();
        const px = try buildAndRun(&arena, b.bytes());
        for (px, 0..) |p, i| {
            const expect: u8 = 5 +% (3 *% @as(u8, @truncate(i)));
            try testing.expectEqual(expect, p);
        }
    }
    {
        var b = Builder.init(testing.allocator);
        defer b.deinit();
        const pat = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01 };
        try b.repeat(0, 30, 30, &pat);
        try b.halt();
        const px = try buildAndRun(&arena, b.bytes());
        for (px, 0..) |p, i| try testing.expectEqual(pat[i % pat.len], p);
    }
    // Truncated REPEAT payload errors instead of reading past the program.
    {
        var m = Vm.init(arena.allocator());
        const code = [_]u8{ 0x0E, 0, 4, 0, 4, 0, 9, 1, 2 }; // plen=9, only 2 bytes
        try testing.expectError(VmError.UnexpectedEnd, m.execute(&code));
    }
}

test "dimension mismatch is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.intNoise(0, 16, 16, 4);
    try b.intNoise(1, 32, 32, 4);
    try b.halt();
    var m = Vm.init(arena.allocator());
    try testing.expectError(VmError.DimensionMismatch, m.execute(b.bytes()));
}

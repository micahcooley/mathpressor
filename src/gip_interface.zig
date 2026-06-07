//! gip_interface.zig — Ghost Interface Protocol (GIP) boundary.
//!
//! Mathpressor is not a GUI; it is a synthesis daemon that the Ghost Engine
//! drives. This file is the one and only C-ABI surface the engine links against.
//! Everything crossing this boundary is plain integers and raw pointers — no
//! Zig types leak out — so the engine can call it from C, C++, or any FFI.
//!
//! Memory contract: the caller owns both the input bytecode buffer and the
//! output pixel buffer. Internally each call spins up a private
//! `ArenaAllocator`, does all scratch allocation inside it, and tears it down
//! on return. No allocations outlive the call; nothing is hidden.

const std = @import("std");
const vm = @import("vm.zig");

// ---------------------------------------------------------------------------
// GIP status codes (returned in the i32). >= 0 means success and carries the
// number of bytes written; < 0 is an error code.
// ---------------------------------------------------------------------------

pub const GIP_ERR_TRUNCATED: i32 = -1; // bytecode empty or ended mid-instruction
pub const GIP_ERR_INVALID_OPCODE: i32 = -2; // unknown opcode byte
pub const GIP_ERR_OUT_TOO_SMALL: i32 = -3; // output buffer can't hold the asset
pub const GIP_ERR_NO_OUTPUT: i32 = -4; // program never hit OP_HALT
pub const GIP_ERR_DIM_MISMATCH: i32 = -5; // conflicting canvas sizes
pub const GIP_ERR_SLOT_RANGE: i32 = -6; // slot index out of range
pub const GIP_ERR_UNINIT: i32 = -7; // op needed a buffer that didn't exist
pub const GIP_ERR_BAD_DIMS: i32 = -8; // zero/oversized dimensions
pub const GIP_ERR_OOM: i32 = -9; // arena allocation failed
pub const GIP_ERR_NULL: i32 = -10; // null pointer / zero-length argument

fn mapError(e: vm.VmError) i32 {
    return switch (e) {
        error.UnexpectedEnd => GIP_ERR_TRUNCATED,
        error.InvalidOpcode => GIP_ERR_INVALID_OPCODE,
        error.NoOutput => GIP_ERR_NO_OUTPUT,
        error.DimensionMismatch => GIP_ERR_DIM_MISMATCH,
        error.SlotOutOfRange => GIP_ERR_SLOT_RANGE,
        error.CanvasUninitialized => GIP_ERR_UNINIT,
        error.InvalidDimensions => GIP_ERR_BAD_DIMS,
        error.OutOfMemory => GIP_ERR_OOM,
    };
}

// ---------------------------------------------------------------------------
// The exported entry point.
// ---------------------------------------------------------------------------

/// Synthesize a single asset from its bytecode into `out_buffer`.
///
/// Parameters:
///   asset_id       — opaque key the Ghost Engine uses for caching/logging.
///   bytecode_ptr   — pointer to the Mathpressor program.
///   bytecode_len   — its length in bytes.
///   out_buffer_ptr — destination pixel buffer owned by the caller.
///   out_buffer_len — its capacity in bytes.
///
/// Returns the number of bytes written (>= 0) on success, or a negative
/// GIP_ERR_* code on failure.
pub export fn gip_synthesize_asset(
    asset_id: u32,
    bytecode_ptr: [*]const u8,
    bytecode_len: usize,
    out_buffer_ptr: [*]u8,
    out_buffer_len: usize,
) i32 {
    _ = asset_id; // reserved for caching/telemetry on the engine side

    if (bytecode_len == 0) return GIP_ERR_TRUNCATED;
    if (out_buffer_len == 0) return GIP_ERR_NULL;

    // Per-asset arena over the OS page allocator. `defer deinit` guarantees every
    // scratch byte is reclaimed no matter which path we return through.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const code = bytecode_ptr[0..bytecode_len];
    var machine = vm.Vm.init(arena.allocator());
    const pixels = machine.execute(code) catch |e| return mapError(e);

    if (pixels.len > out_buffer_len) return GIP_ERR_OUT_TOO_SMALL;

    const out = out_buffer_ptr[0..out_buffer_len];
    @memcpy(out[0..pixels.len], pixels);
    return @intCast(pixels.len);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn buildValid(a: std.mem.Allocator, w: u16, h: u16) !std.ArrayList(u8) {
    var b = vm.Builder.init(a);
    errdefer b.deinit();
    try b.seed(0xBEEF);
    try b.intNoise(0, w, h, 4);
    try b.halt();
    return b.list;
}

test "GIP synthesize succeeds and reports byte count" {
    var prog = try buildValid(testing.allocator, 16, 16);
    defer prog.deinit();

    var out: [16 * 16]u8 = undefined;
    const rc = gip_synthesize_asset(1, prog.items.ptr, prog.items.len, &out, out.len);
    try testing.expectEqual(@as(i32, 16 * 16), rc);
}

test "GIP is deterministic across calls" {
    var prog = try buildValid(testing.allocator, 24, 24);
    defer prog.deinit();

    var a: [24 * 24]u8 = undefined;
    var b: [24 * 24]u8 = undefined;
    _ = gip_synthesize_asset(1, prog.items.ptr, prog.items.len, &a, a.len);
    _ = gip_synthesize_asset(2, prog.items.ptr, prog.items.len, &b, b.len);
    try testing.expectEqualSlices(u8, &a, &b);
}

test "GIP rejects an undersized output buffer" {
    var prog = try buildValid(testing.allocator, 32, 32);
    defer prog.deinit();

    var tiny: [10]u8 = undefined;
    const rc = gip_synthesize_asset(1, prog.items.ptr, prog.items.len, &tiny, tiny.len);
    try testing.expectEqual(GIP_ERR_OUT_TOO_SMALL, rc);
}

test "GIP maps VM errors to status codes" {
    var out: [4]u8 = undefined;

    // Empty bytecode.
    try testing.expectEqual(GIP_ERR_TRUNCATED, gip_synthesize_asset(1, &[_]u8{}, 0, &out, out.len));
    // Bad opcode.
    {
        const code = [_]u8{0x00};
        try testing.expectEqual(GIP_ERR_INVALID_OPCODE, gip_synthesize_asset(1, &code, code.len, &out, out.len));
    }
    // Truncated seed payload.
    {
        const code = [_]u8{ 0x01, 0x00 };
        try testing.expectEqual(GIP_ERR_TRUNCATED, gip_synthesize_asset(1, &code, code.len, &out, out.len));
    }
}

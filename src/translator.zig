//! translator.zig — The Opportunistic Translator: entropy analysis, math search,
//! and residual delta extraction.
//!
//! DECISION TREE
//! ─────────────
//!   Phase 1 — Entropy gate  (O(n), fast):
//!     entropy ≥ 7.5 bits/byte → FallbackStream immediately, no search.
//!
//!   Phase 2 — Iterative math search  (O(iters × pixels)):
//!     Sweep 5 000 (seed, template, freq) combinations through the VM.
//!     Track the best candidate by total absolute byte error (L1 norm).
//!     a) L1 == 0 → exact bit-perfect match → return MathBytecode.
//!     b) L1 > 0 but ≥ 70 % of bytes are exact → Approximate match:
//!          Compile a residual delta buffer:  delta[i] = raw[i] -% approx[i]
//!          Return both the approximate program AND the delta.
//!          Reconstruction is: vm_output[i] +% delta[i] == raw[i]  (always).
//!     c) Nothing qualifies → FallbackStream.
//!
//! NOTE ON FLOATS: Shannon entropy uses f64 deliberately. The translator runs
//! offline (once, on the developer's machine). The determinism constraint applies
//! only to the runtime VM path; the VM contains zero floats.

const std = @import("std");
const vm_mod = @import("vm.zig");

// ---------------------------------------------------------------------------
// Public result types
// ---------------------------------------------------------------------------

pub const TranslateResult = union(enum) {
    /// Bit-perfect program. Caller must free `[]u8` with the passed allocator.
    math_bytecode: []u8,
    /// Best approximate program + residual delta.
    /// Reconstruct: for each i → vm_execute(bytecode)[i] +% delta[i] == raw[i].
    /// Caller must free both slices.
    approximate: ApproxResult,
    /// No useful match — route to gzip / STORE fallback.
    fallback: FallbackInfo,

    pub const Reason = enum {
        high_entropy,  // entropy ≥ ENTROPY_GATE, search never started
        search_failed, // 5 000 iterations exhausted, nothing qualified
    };
};

pub const ApproxResult = struct {
    /// The closest Mathpressor program found. Caller must free.
    bytecode: []u8,
    /// delta[i] = raw[i] -% approx_pixels[i]. Caller must free.
    /// Apply to VM output to recover the original bytes exactly.
    delta: []u8,
    /// Total L1 norm of the error the approximation leaves behind.
    best_error: u64,
    /// Percentage of bytes the approximate program matched exactly (0-100).
    exact_pct: u64,
};

pub const FallbackInfo = struct {
    reason: TranslateResult.Reason,
    entropy: f64,
};

// ---------------------------------------------------------------------------
// Tuning parameters
// ---------------------------------------------------------------------------

/// Entropy gate. Files above this go straight to fallback without any search.
pub const ENTROPY_GATE: f64 = 7.5;

/// Maximum (seed, template, freq) iterations before giving up.
pub const MAX_ITERATIONS: u32 = 5_000;

/// To qualify for approximate matching, at least this percentage of bytes must
/// be bit-identical between the candidate program's output and the target.
pub const APPROX_MIN_EXACT_PCT: u64 = 70;

/// Upper bound on bytecode length for any built-in template.
/// Used to pre-size the best-candidate buffer without per-iteration allocation.
const MAX_TEMPLATE_CODE_BYTES: usize = 64;

// ---------------------------------------------------------------------------
// Shannon entropy  (floats OK — offline analysis tool, not the VM)
// ---------------------------------------------------------------------------

pub fn shannonEntropy(data: []const u8) f64 {
    if (data.len == 0) return 0;
    var freq = [_]u64{0} ** 256;
    for (data) |b| freq[b] += 1;
    const n: f64 = @floatFromInt(data.len);
    var h: f64 = 0;
    for (freq) |f| {
        if (f == 0) continue;
        const p = @as(f64, @floatFromInt(f)) / n;
        h -= p * @log2(p);
    }
    return h;
}

// ---------------------------------------------------------------------------
// Integer error metrics  (deterministic, zero floats)
// ---------------------------------------------------------------------------

/// L1 norm: sum of per-byte absolute differences.
/// The primary fitness function for the approximate search.
fn computeL1(a: []const u8, b: []const u8) u64 {
    var total: u64 = 0;
    for (a, b) |x, y| total += if (x >= y) x - y else y - x;
    return total;
}

/// Count bytes where `generated[i] == raw[i]`.
fn countExact(raw: []const u8, generated: []const u8) u64 {
    var n: u64 = 0;
    for (raw, generated) |r, g| if (r == g) { n += 1; };
    return n;
}

/// True if ≥ APPROX_MIN_EXACT_PCT% of bytes are an exact match.
fn qualifiesForApprox(raw: []const u8, generated: []const u8) bool {
    if (raw.len == 0) return false;
    const exact = countExact(raw, generated);
    return exact * 100 >= @as(u64, raw.len) * APPROX_MIN_EXACT_PCT;
}

// ---------------------------------------------------------------------------
// Program templates
// ---------------------------------------------------------------------------

const Template = struct {
    name: []const u8,
    buildFn: *const fn (*vm_mod.Builder, u16, u16, u32, u8) anyerror!void,
};

fn tmplSingleNoise(b: *vm_mod.Builder, w: u16, h: u16, seed: u32, freq: u8) !void {
    try b.seed(seed);
    try b.intNoise(0, w, h, freq);
    try b.halt();
}
fn tmplNoiseInvert(b: *vm_mod.Builder, w: u16, h: u16, seed: u32, freq: u8) !void {
    try b.seed(seed);
    try b.intNoise(0, w, h, freq);
    try b.invert();
    try b.halt();
}
fn tmplNoiseBright(b: *vm_mod.Builder, w: u16, h: u16, seed: u32, freq: u8) !void {
    try b.seed(seed);
    try b.intNoise(0, w, h, freq);
    try b.addConst(24);
    try b.invert();
    try b.halt();
}
fn tmplBlendMult(b: *vm_mod.Builder, w: u16, h: u16, seed: u32, freq: u8) !void {
    try b.seed(seed);
    try b.intNoise(0, w, h, freq);
    try b.intNoise(1, w, h, @truncate(freq +% 5));
    try b.blendMult(0);
    try b.addConst(24);
    try b.invert();
    try b.halt();
}
fn tmplCave(b: *vm_mod.Builder, w: u16, h: u16, seed: u32, freq: u8) !void {
    try b.seed(seed);
    try b.intNoise(0, w, h, freq);
    try b.threshold(140);
    try b.cellular(5, 4, 3);
    try b.halt();
}
fn tmplMarble(b: *vm_mod.Builder, w: u16, h: u16, seed: u32, freq: u8) !void {
    try b.seed(seed);
    try b.intNoise(0, w, h, freq);
    try b.intNoise(1, w, h, @truncate(freq +% 4));
    try b.warp(0, 96);
    try b.level(30, 220);
    try b.halt();
}

const TEMPLATES = [_]Template{
    .{ .name = "single_noise", .buildFn = tmplSingleNoise },
    .{ .name = "noise_invert", .buildFn = tmplNoiseInvert },
    .{ .name = "noise_bright", .buildFn = tmplNoiseBright },
    .{ .name = "blend_mult",   .buildFn = tmplBlendMult   },
    .{ .name = "cave",         .buildFn = tmplCave         },
    .{ .name = "marble",       .buildFn = tmplMarble       },
};

const FREQ_SWEEP = [_]u8{ 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20 };

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

/// Analyse `data` and attempt to find a Mathpressor representation.
///
/// `width` × `height` must equal `data.len` exactly.
/// All returned slices are allocated with `alloc`; the caller is responsible
/// for freeing them (see `TranslateResult` for which fields to free).
/// `progress` may be null; if provided it is updated continuously.
pub fn translate(
    data: []const u8,
    width: u32,
    height: u32,
    alloc: std.mem.Allocator,
    progress: ?*TranslateProgress,
) !TranslateResult {

    // -----------------------------------------------------------------------
    // Phase 1 — Entropy gate
    // -----------------------------------------------------------------------
    const ent = shannonEntropy(data);
    if (progress) |p| p.entropy = ent;

    if (ent >= ENTROPY_GATE) {
        return .{ .fallback = .{ .reason = .high_entropy, .entropy = ent } };
    }

    // Canvas size guard: width × height must exactly match the buffer length.
    const canvas_len: usize = @as(usize, width) * @as(usize, height);
    if (canvas_len != data.len or canvas_len == 0 or
        width > vm_mod.MAX_DIM or height > vm_mod.MAX_DIM)
    {
        return .{ .fallback = .{ .reason = .search_failed, .entropy = ent } };
    }

    const w: u16 = @intCast(width);
    const h: u16 = @intCast(height);

    // -----------------------------------------------------------------------
    // Phase 2 — Iterative search with best-candidate tracking
    //
    // Memory layout:
    //   best_code_buf  — pre-allocated in `alloc`; holds bytecode of the best
    //                    candidate seen so far. Avoids per-iteration heap churn.
    //   best_gen_buf   — pre-allocated in `alloc`; holds VM output for the best
    //                    candidate. Populated via memcpy from the scratch arena.
    //   scratch        — per-iteration arena; reset at the top of each iteration
    //                    so candidate programs and VM state never outlive one try.
    //
    // Both best_* buffers are freed via defer in ALL return paths. Slices
    // returned inside TranslateResult are separate allocations (dupe / alloc).
    // -----------------------------------------------------------------------
    var best_code_buf = try alloc.alloc(u8, MAX_TEMPLATE_CODE_BYTES);
    defer alloc.free(best_code_buf);
    const best_gen_buf = try alloc.alloc(u8, data.len);
    defer alloc.free(best_gen_buf);

    var best_code_len: usize = 0;
    var best_error: u64 = std.math.maxInt(u64);
    var has_best: bool = false;
    var best_tmpl_name: []const u8 = "";
    var best_seed: u32 = 0;
    var best_freq: u8 = 0;

    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();

    var iters: u32 = 0;
    var seed: u32 = 1;
    outer: while (iters < MAX_ITERATIONS) {
        for (TEMPLATES) |tmpl| {
            for (FREQ_SWEEP) |freq| {
                if (iters >= MAX_ITERATIONS) break :outer;
                iters += 1;

                // Fresh slate for this candidate: reset but keep backing memory.
                _ = scratch.reset(.retain_capacity);

                var b = vm_mod.Builder.init(scratch.allocator());
                tmpl.buildFn(&b, w, h, seed, freq) catch continue;

                var machine = vm_mod.Vm.init(scratch.allocator());
                const result = machine.execute(b.bytes()) catch continue;

                // Paranoia: VM must produce exactly the expected canvas size.
                if (result.len != data.len) continue;

                if (progress) |p| {
                    p.iterations = iters;
                    p.last_template = tmpl.name;
                }

                // --- Fitness: L1 norm (total absolute byte error) ---
                const l1 = computeL1(result, data);

                if (l1 == 0) {
                    // ── Exact bit-perfect match ──────────────────────────────
                    // Dupe the bytecode out of the scratch arena before we
                    // return (scratch.deinit fires via defer).
                    const code_out = try alloc.dupe(u8, b.bytes());
                    if (progress) |p| {
                        p.match_template = tmpl.name;
                        p.match_seed = seed;
                        p.match_freq = freq;
                    }
                    // best_code_buf and best_gen_buf freed by defers above ✓
                    return .{ .math_bytecode = code_out };
                }

                // --- Track the best candidate seen so far ---
                if (l1 < best_error) {
                    best_error = l1;
                    has_best = true;
                    const cb = b.bytes();
                    // Guard: should never exceed pre-alloc, but be defensive.
                    if (cb.len <= MAX_TEMPLATE_CODE_BYTES) {
                        @memcpy(best_code_buf[0..cb.len], cb);
                        best_code_len = cb.len;
                    }
                    @memcpy(best_gen_buf, result);
                    best_tmpl_name = tmpl.name;
                    best_seed = seed;
                    best_freq = freq;
                    if (progress) |p| p.best_error = l1;
                }
            }
        }
        seed +%= 1;
    }

    // -----------------------------------------------------------------------
    // Post-search: approximate match evaluation
    //
    // If any candidate qualified and ≥ APPROX_MIN_EXACT_PCT% of bytes in its
    // output match the target exactly, we compile a residual delta block.
    //
    // Invariant upheld:  approx_vm_output[i] +% delta[i] == raw[i]  for all i.
    // -----------------------------------------------------------------------
    if (has_best and qualifiesForApprox(data, best_gen_buf)) {
        const exact_count = countExact(data, best_gen_buf);
        const exact_pct = exact_count * 100 / data.len;

        // Allocate the output code slice.
        const code_out = try alloc.dupe(u8, best_code_buf[0..best_code_len]);
        errdefer alloc.free(code_out);

        // Allocate and compute the delta: delta[i] = raw[i] -% approx[i].
        // Wrapping subtraction keeps every delta value in [0, 255] with the
        // wrapping-add inverse: approx[i] +% delta[i] == raw[i].
        const delta = try alloc.alloc(u8, data.len);
        for (delta, data, best_gen_buf) |*d, raw, approx| {
            d.* = raw -% approx;
        }

        if (progress) |p| {
            p.is_approximate  = true;
            p.best_error      = best_error;
            p.exact_pct       = exact_pct;
            p.approx_template = best_tmpl_name;
            p.approx_seed     = best_seed;
            p.approx_freq     = best_freq;
        }

        // best_code_buf / best_gen_buf freed by defers ✓
        return .{ .approximate = .{
            .bytecode   = code_out,
            .delta      = delta,
            .best_error = best_error,
            .exact_pct  = exact_pct,
        }};
    }

    // No useful representation found.
    return .{ .fallback = .{ .reason = .search_failed, .entropy = ent } };
}

// ---------------------------------------------------------------------------
// Progress reporter
// ---------------------------------------------------------------------------

pub const TranslateProgress = struct {
    // Phase 1
    entropy: f64 = 0,
    // Phase 2 — general
    iterations: u32 = 0,
    last_template: []const u8 = "",
    best_error: u64 = std.math.maxInt(u64),
    // Phase 2 — exact match fields
    match_template: []const u8 = "",
    match_seed: u32 = 0,
    match_freq: u8 = 0,
    // Phase 2 — approximate match fields
    is_approximate: bool = false,
    exact_pct: u64 = 0,
    approx_template: []const u8 = "",
    approx_seed: u32 = 0,
    approx_freq: u8 = 0,
};

// ---------------------------------------------------------------------------
// Convenience helpers
// ---------------------------------------------------------------------------

pub const SynthSpec = struct {
    seed: u32,
    freq: u8,
    template: usize = 0,
};

/// Generate a procedural texture via a known template. Returned slice is
/// allocated with `alloc`; caller must free.
pub fn synthesiseKnown(
    spec: SynthSpec,
    width: u32,
    height: u32,
    alloc: std.mem.Allocator,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const w: u16 = @intCast(width);
    const h: u16 = @intCast(height);

    var b = vm_mod.Builder.init(arena.allocator());
    const tmpl = TEMPLATES[@min(spec.template, TEMPLATES.len - 1)];
    try tmpl.buildFn(&b, w, h, spec.seed, spec.freq);

    var machine = vm_mod.Vm.init(arena.allocator());
    const pixels = try machine.execute(b.bytes());
    return alloc.dupe(u8, pixels);
}

/// Quick entropy pre-check before calling translate.
pub fn isCandidate(data: []const u8) bool {
    return shannonEntropy(data) < ENTROPY_GATE;
}

/// Apply a delta buffer to a VM-generated approximation, recovering the
/// original bytes. `approx` and `delta` must have the same length.
/// Result is written into `out` (which must also have the same length).
///
/// This is the reconstruction side of the residual delta engine:
///   out[i] = approx[i] +% delta[i]
pub fn applyDelta(approx: []const u8, delta: []const u8, out: []u8) void {
    for (out, approx, delta) |*o, a, d| o.* = a +% d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "L1 norm: identical buffers → 0" {
    const a = [_]u8{ 10, 20, 200, 100 };
    try testing.expectEqual(@as(u64, 0), computeL1(&a, &a));
}

test "L1 norm: known values" {
    const a = [_]u8{ 0, 255 };
    const b = [_]u8{ 10, 245 };
    // |0-10| + |255-245| = 10 + 10 = 20
    try testing.expectEqual(@as(u64, 20), computeL1(&a, &b));
}

test "qualifiesForApprox: 75% exact → qualifies" {
    // 8 bytes: 6 exact (75%), 2 off.
    const raw  = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const gen  = [_]u8{ 1, 2, 3, 4, 5, 6, 0, 0 }; // last 2 differ
    try testing.expect(qualifiesForApprox(&raw, &gen));
}

test "qualifiesForApprox: 50% exact → does not qualify" {
    const raw = [_]u8{ 1, 2, 3, 4 };
    const gen = [_]u8{ 1, 2, 0, 0 }; // 50% exact
    try testing.expect(!qualifiesForApprox(&raw, &gen));
}

test "entropy of all-zero is 0" {
    const zeros = [_]u8{0} ** 256;
    try testing.expect(shannonEntropy(&zeros) == 0);
}

test "entropy of uniform distribution is near 8" {
    var uniform: [256]u8 = undefined;
    for (&uniform, 0..) |*b, i| b.* = @intCast(i);
    try testing.expect(shannonEntropy(&uniform) > 7.9);
}

test "applyDelta: reconstruction is exact" {
    const raw    = [_]u8{ 10, 200, 50, 130 };
    const approx = [_]u8{  8, 210, 40, 140 };
    var delta: [4]u8 = undefined;
    for (&delta, &raw, &approx) |*d, r, a| d.* = r -% a;

    var out: [4]u8 = undefined;
    applyDelta(&approx, &delta, &out);
    try testing.expectEqualSlices(u8, &raw, &out);
}

test "applyDelta: wrapping arithmetic stays in range" {
    // approx = 5, delta = 255-5+1 = 251 → 5 +% 251 = 0 (mod 256)
    const approx = [_]u8{ 5 };
    const delta  = [_]u8{ @as(u8, 0) -% @as(u8, 5) }; // 251
    var out: [1]u8 = undefined;
    applyDelta(&approx, &delta, &out);
    try testing.expectEqual(@as(u8, 0), out[0]);
}

test "high-entropy data → fallback (high_entropy)" {
    const a = testing.allocator;
    var rng = @import("math_gen.zig").XorShift32.init(0xBAAD);
    const buf = try a.alloc(u8, 2048);
    defer a.free(buf);
    for (buf) |*b| b.* = rng.nextByte();

    try testing.expect(shannonEntropy(buf) >= ENTROPY_GATE);
    const result = try translate(buf, 32, 64, a, null);
    switch (result) {
        .fallback => |f| try testing.expectEqual(
            TranslateResult.Reason.high_entropy, f.reason),
        .math_bytecode => |b| { a.free(b); try testing.expect(false); },
        .approximate   => |r| { a.free(r.bytecode); a.free(r.delta); try testing.expect(false); },
    }
}

test "exact match: single-layer noise texture" {
    const a = testing.allocator;
    const w: u32 = 32;
    const h: u32 = 32;

    const target = try synthesiseKnown(.{ .seed = 7, .freq = 4 }, w, h, a);
    defer a.free(target);

    try testing.expect(shannonEntropy(target) < ENTROPY_GATE);

    var prog = TranslateProgress{};
    const result = try translate(target, w, h, a, &prog);
    switch (result) {
        .math_bytecode => |code| {
            defer a.free(code);
            // Verify the returned code reproduced the target exactly.
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            var m = vm_mod.Vm.init(arena.allocator());
            try testing.expectEqualSlices(u8, target, try m.execute(code));
            try testing.expectEqual(@as(u32, 7), prog.match_seed);
            try testing.expectEqual(@as(u8, 4), prog.match_freq);
        },
        .approximate => |r| { a.free(r.bytecode); a.free(r.delta); try testing.expect(false); },
        .fallback    => try testing.expect(false),
    }
}

test "fallback: pattern with no template match" {
    const a = testing.allocator;
    // Alternating 0/128: entropy ≈ 1 bit/byte (passes gate) but no template
    // produces this pattern, so < 70% of bytes ever match exactly → fallback.
    const buf = try a.alloc(u8, 8 * 8);
    defer a.free(buf);
    for (buf, 0..) |*b, i| b.* = if (i % 2 == 0) @as(u8, 0) else @as(u8, 128);

    const result = try translate(buf, 8, 8, a, null);
    switch (result) {
        .fallback => {},
        .math_bytecode => |b| { a.free(b);               try testing.expect(false); },
        .approximate   => |r| { a.free(r.bytecode); a.free(r.delta); try testing.expect(false); },
    }
}

test "approximate match: dirty texture with 25% pixel corruption" {
    const a = testing.allocator;
    const w: u32 = 16;
    const h: u32 = 16;

    // Generate a clean math texture (seed=7, freq=4, single_noise).
    const clean = try synthesiseKnown(.{ .seed = 7, .freq = 4 }, w, h, a);
    defer a.free(clean);

    // Corrupt exactly 25% of pixels with pseudo-random values.
    // 25% corrupted → 75% exact when the translator finds seed=7 → qualifies.
    const dirty = try a.dupe(u8, clean);
    defer a.free(dirty);
    var rng = @import("math_gen.zig").XorShift32.init(0xBADBAD);
    for (dirty) |*p| {
        if (rng.nextBelow(100) < 25) p.* = rng.nextByte();
    }

    // Sanity: the dirty buffer has lower entropy than pure random.
    try testing.expect(shannonEntropy(dirty) < ENTROPY_GATE);

    var prog = TranslateProgress{};
    const result = try translate(dirty, w, h, a, &prog);

    switch (result) {
        .approximate => |approx| {
            defer a.free(approx.bytecode);
            defer a.free(approx.delta);

            // Reconstruction invariant: approx_vm[i] +% delta[i] == raw[i].
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            var m = vm_mod.Vm.init(arena.allocator());
            const approx_px = try m.execute(approx.bytecode);
            var reconstructed: [16 * 16]u8 = undefined;
            applyDelta(approx_px, approx.delta, &reconstructed);
            try testing.expectEqualSlices(u8, dirty, &reconstructed);

            // Quality: at least 70% of bytes must be exact in the approximation.
            try testing.expect(approx.exact_pct >= APPROX_MIN_EXACT_PCT);

            // The delta buffer is smaller in information content than the
            // corruption: 75%+ of delta bytes are zero (exact positions).
            var zero_deltas: usize = 0;
            for (approx.delta) |d| if (d == 0) { zero_deltas += 1; };
            try testing.expect(zero_deltas * 100 >= dirty.len * APPROX_MIN_EXACT_PCT);
        },
        // If the search happens to find an exact match (very unlikely with
        // 25% corruption but theoretically possible if all corrupted pixels
        // land on values that the noise already generates), accept that too.
        .math_bytecode => |b| {
            defer a.free(b);
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            var m = vm_mod.Vm.init(arena.allocator());
            try testing.expectEqualSlices(u8, dirty, try m.execute(b));
        },
        .fallback => try testing.expect(false),
    }
}

test "isCandidate correctly classifies entropy" {
    const a = testing.allocator;
    var rng = @import("math_gen.zig").XorShift32.init(1);
    const high_ent = try a.alloc(u8, 2048);
    defer a.free(high_ent);
    for (high_ent) |*b| b.* = rng.nextByte();
    try testing.expect(!isCandidate(high_ent));

    const low_ent = [_]u8{64} ** 256;
    try testing.expect(isCandidate(&low_ent));
}

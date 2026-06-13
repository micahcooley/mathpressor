//! main.zig — Entry point and benchmark harness.
//!
//! Usage:
//!   mathpressor                    → synthesis demo (96×96 ASCII preview)
//!   mathpressor bench              → compression-ratio benchmark (5 assets, 512×512)
//!   mathpressor pack_demo          → opportunistic fallback benchmark (pack + unpack)
//!   mathpressor pack <dir> <out>   → pack a directory into a .math container
//!   mathpressor unpack <in> <dir>  → unpack a .math container
//!   mathpressor <prog.mpc> <out>   → synthesize bytecode file → .pgm image

const std = @import("std");
const vm = @import("vm.zig");
const abi = @import("abi.zig");
const container = @import("container.zig");
const translator = @import("translator.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const root = gpa.allocator();

    const args = try std.process.argsAlloc(root);
    defer std.process.argsFree(root, args);

    const out = std.io.getStdOut().writer();

    if (args.len >= 4 and std.mem.eql(u8, args[1], "pack")) {
        try packDirectory(root, args[2], args[3], out);
    } else if (args.len >= 4 and std.mem.eql(u8, args[1], "packfull")) {
        const tier: u8 = if (args.len >= 5) std.fmt.parseInt(u8, args[4], 10) catch 1 else 1;
        try packFullCli(root, args[2], args[3], tier, out);
    } else if (args.len >= 4 and std.mem.eql(u8, args[1], "unpack")) {
        try unpackContainer(root, args[2], args[3], out);
    } else if (args.len == 2 and std.mem.eql(u8, args[1], "bench")) {
        try runBenchmark(root, out);
    } else if (args.len == 2 and std.mem.eql(u8, args[1], "pack_demo")) {
        try runPackDemo(root, out);
    } else if (args.len >= 3) {
        try runFile(root, args[1], args[2], out);
    } else {
        try runDemo(root, out);
    }
}

// ---------------------------------------------------------------------------
// Demo mode
// ---------------------------------------------------------------------------

fn runDemo(root: std.mem.Allocator, out: anytype) !void {
    var b = vm.Builder.init(root);
    defer b.deinit();
    try b.seed(0x00C0FFEE);
    try b.intNoise(0, 96, 96, 4);
    try b.intNoise(1, 96, 96, 9);
    try b.blendMult(0);
    try b.addConst(24);
    try b.invert();
    try b.halt();
    const code = b.bytes();

    try out.print("Mathpressor — procedural asset engine\n", .{});
    try out.print("================================================\n", .{});
    try out.print("bytecode         : {d} bytes\n", .{code.len});

    var arena = std.heap.ArenaAllocator.init(root);
    defer arena.deinit();

    var machine = vm.Vm.init(arena.allocator());
    const pixels = machine.execute(code) catch |e| return e;

    const st = pixelStats(pixels);
    try out.print("synthesised      : {d}x{d} = {d} pixels\n", .{ machine.width, machine.height, pixels.len });
    try out.print("expansion ratio  : {d}x\n", .{pixels.len / code.len});
    try out.print("fnv1a checksum   : 0x{x:0>8}\n", .{container.fnv1a(pixels)});
    try out.print("min/max/mean     : {d} / {d} / {d}\n\n", .{ st.min, st.max, st.mean });

    try printAscii(out, pixels, machine.width, machine.height);

    const mp_out = try root.alloc(u8, pixels.len);
    defer root.free(mp_out);
    const rc = abi.mp_synthesize_asset(0xA55E7, code.ptr, code.len, mp_out.ptr, mp_out.len);
    try out.print("\nC-ABI returned {d} bytes — identical to in-process: {}\n", .{
        rc, std.mem.eql(u8, pixels, mp_out),
    });
    try out.print("Run `mathpressor bench` or `mathpressor pack_demo` for more.\n", .{});
}

// ---------------------------------------------------------------------------
// Synthesis ratio benchmark (5 asset types, 512×512)
// ---------------------------------------------------------------------------

const BenchAsset = struct {
    name: []const u8,
    desc: []const u8,
    buildFn: *const fn (std.mem.Allocator) anyerror![]const u8,
};

fn buildDiffuse(a: std.mem.Allocator) anyerror![]const u8 {
    var b = vm.Builder.init(a);
    defer b.deinit();
    try b.seed(0x00C0FFEE);
    try b.intNoise(0, 512, 512, 4);
    try b.intNoise(1, 512, 512, 9);
    try b.blendMult(0);
    try b.addConst(24);
    try b.invert();
    try b.halt();
    return a.dupe(u8, b.bytes());
}
fn buildCave(a: std.mem.Allocator) anyerror![]const u8 {
    var b = vm.Builder.init(a);
    defer b.deinit();
    try b.seed(0xCAFEBABE);
    try b.intNoise(0, 512, 512, 6);
    try b.threshold(140);
    try b.cellular(5, 4, 3);
    try b.halt();
    return a.dupe(u8, b.bytes());
}
fn buildMarble(a: std.mem.Allocator) anyerror![]const u8 {
    var b = vm.Builder.init(a);
    defer b.deinit();
    try b.seed(0xDEADC0DE);
    try b.intNoise(0, 512, 512, 3);
    try b.intNoise(1, 512, 512, 7);
    try b.warp(0, 96);
    try b.level(30, 220);
    try b.mix(0, 48);
    try b.halt();
    return a.dupe(u8, b.bytes());
}
fn buildDetail(a: std.mem.Allocator) anyerror![]const u8 {
    var b = vm.Builder.init(a);
    defer b.deinit();
    try b.seed(0xFACEFEED);
    try b.intNoise(0, 512, 512, 14);
    try b.intNoise(1, 512, 512, 20);
    try b.mix(0, 128);
    try b.addConst(-20);
    try b.halt();
    return a.dupe(u8, b.bytes());
}
fn buildMossy(a: std.mem.Allocator) anyerror![]const u8 {
    var b = vm.Builder.init(a);
    defer b.deinit();
    try b.seed(0xB16B00B5);
    try b.intNoise(0, 512, 512, 5);
    try b.intNoise(1, 512, 512, 11);
    try b.copy(0, 2);
    try b.threshold(120);
    try b.cellular(4, 4, 3);
    try b.mix(2, 80);
    try b.blendMult(1);
    try b.halt();
    return a.dupe(u8, b.bytes());
}

const ASSETS = [_]BenchAsset{
    .{ .name = "diffuse", .desc = "cloud/fog base texture", .buildFn = buildDiffuse },
    .{ .name = "cave",    .desc = "CA cave/rock mask",      .buildFn = buildCave    },
    .{ .name = "marble",  .desc = "domain-warped veins",    .buildFn = buildMarble  },
    .{ .name = "detail",  .desc = "high-freq roughness map",.buildFn = buildDetail  },
    .{ .name = "mossy",   .desc = "CA patches + noise mask",.buildFn = buildMossy   },
};

fn runBenchmark(root: std.mem.Allocator, out: anytype) !void {
    const RAW: usize = 512 * 512;
    try out.print("\nMATHPRESSOR — BIT-PERFECT SYNTHESIS BENCHMARK (512×512, {d}B raw)\n", .{RAW});
    try out.print("====================================================================\n\n", .{});
    try out.print("  {s:<10}  {s:>6}  {s:>9}  {s:>8}  {s:>8}  {s}\n",
        .{ "asset", "prog", "vs raw", "gzip", "vs gzip", "desc" });
    try out.print("  {s:-<10}  {s:->6}  {s:->9}  {s:->8}  {s:->8}  {s:-<24}\n",
        .{ "", "", "", "", "", "" });

    var total_prog: usize = 0;
    var total_gz: usize = 0;
    for (ASSETS) |asset| {
        const code = try asset.buildFn(root);
        defer root.free(code);
        var arena = std.heap.ArenaAllocator.init(root);
        defer arena.deinit();
        var m = vm.Vm.init(arena.allocator());
        const px = try m.execute(code);
        const gz = try container.gzipCompress(px, root, .default);
        defer root.free(gz);
        try out.print("  {s:<10}  {d:>4}B  {d:>7}x  {d:>6}B  {d:>6}x  {s}\n",
            .{ asset.name, code.len, RAW / code.len, gz.len, gz.len / code.len, asset.desc });
        total_prog += code.len;
        total_gz += gz.len;
    }
    try out.print("\n  {s:<10}  {d:>4}B  {d:>7}x  {d:>5}KB  {d:>6}x\n\n",
        .{ "TOTAL", total_prog, (RAW * ASSETS.len) / total_prog, total_gz / 1024, total_gz / total_prog });
}

// ---------------------------------------------------------------------------
// Opportunistic Fallback Pack Demo
// ---------------------------------------------------------------------------
//
// This is the showcase of the full architecture:
//
//   MOCK GAME DIRECTORY
//     textures/shader_noise.raw  — a 64×64 procedural texture (math-friendly)
//     binary/enemy_ai.bin        — a 2KB pseudo-random binary  (math-hostile)
//
//   TRANSLATOR ROUTING
//     shader_noise.raw  → entropy LOW   → search finds program → MATH_BYTECODE
//     enemy_ai.bin      → entropy HIGH  → skip search          → FALLBACK_STREAM
//
//   CONTAINER PACK  → writes a .math archive in memory
//   CONTAINER UNPACK → reads back and verifies byte-perfect reconstruction

fn runPackDemo(root: std.mem.Allocator, out: anytype) !void {
    const math_gen = @import("math_gen.zig");

    try out.print("\n", .{});
    try out.print("MATHPRESSOR — OPPORTUNISTIC FALLBACK + STORE GUARD + RESIDUAL DEMO\n", .{});
    try out.print("====================================================================\n\n", .{});

    // ------------------------------------------------------------------
    // Mock game directory — four files, one per container route:
    //
    //   textures/shader_noise.raw   → low entropy, procedural → MATH_BYTECODE
    //   textures/dirty_texture.raw  → low entropy, 25% corrupt → MATH_RESIDUAL
    //   data/level_script.txt       → low entropy, repetitive  → FALLBACK_STREAM
    //   binary/bloated_random.bin   → high entropy, random     → STORE (guard)
    // ------------------------------------------------------------------
    const CANVAS_W: u32 = 64;
    const CANVAS_H: u32 = 64;
    const DIRTY_W: u32  = 16;
    const DIRTY_H: u32  = 16;

    try out.print("Generating mock game directory...\n", .{});

    // File 1 — bit-perfect procedural noise texture
    const tex_pixels = try translator.synthesiseKnown(
        .{ .seed = 42, .freq = 4, .template = 0 },
        CANVAS_W, CANVAS_H, root,
    );
    defer root.free(tex_pixels);
    try out.print("  textures/shader_noise.raw   {d:>5}B  entropy={d:.2}  (64×64 procedural noise)\n",
        .{ tex_pixels.len, translator.shannonEntropy(tex_pixels) });

    // File 2 — clean math texture corrupted 25% → tests MATH_RESIDUAL path
    const clean_base = try translator.synthesiseKnown(
        .{ .seed = 7, .freq = 4, .template = 0 },
        DIRTY_W, DIRTY_H, root,
    );
    defer root.free(clean_base);
    const dirty_pixels = try root.dupe(u8, clean_base);
    defer root.free(dirty_pixels);
    var dirty_rng = math_gen.XorShift32.init(0xBADBAD);
    var corrupted_count: usize = 0;
    for (dirty_pixels) |*p| {
        if (dirty_rng.nextBelow(100) < 25) {
            p.* = dirty_rng.nextByte();
            corrupted_count += 1;
        }
    }
    try out.print("  textures/dirty_texture.raw  {d:>5}B  entropy={d:.2}  " ++
        "(16×16, {d}/{d} pixels corrupted)\n",
        .{ dirty_pixels.len, translator.shannonEntropy(dirty_pixels),
           corrupted_count, dirty_pixels.len });

    // File 3 — highly repetitive script text (gzip compresses it well)
    const script_raw = "-- level_01 script\nspawn_enemy(x=100)\nspawn_enemy(x=200)\n" ** 30;
    try out.print("  data/level_script.txt       {d:>5}B  entropy={d:.2}  (repetitive level script)\n",
        .{ script_raw.len, translator.shannonEntropy(script_raw) });

    // File 4 — pseudo-random binary (gzip inflates it → STORE guard fires)
    var bloat_rng = math_gen.XorShift32.init(0xBADF00D);
    const BLOAT_SIZE: usize = 2048;
    const bloat_data = try root.alloc(u8, BLOAT_SIZE);
    defer root.free(bloat_data);
    for (bloat_data) |*b| b.* = bloat_rng.nextByte();
    try out.print("  binary/bloated_random.bin   {d:>5}B  entropy={d:.2}  (XorShift32 pseudo-random)\n\n",
        .{ bloat_data.len, translator.shannonEntropy(bloat_data) });

    // ------------------------------------------------------------------
    // Translator phase — search for math representations
    // ------------------------------------------------------------------
    try out.print("Translator — entropy gate + math search\n", .{});
    try out.print("────────────────────────────────────────\n", .{});

    // Translate shader_noise (expect exact match at seed=42)
    try out.print("  shader_noise.raw  → searching... ", .{});
    var prog1 = translator.TranslateProgress{};
    const tex_result = try translator.translate(tex_pixels, CANVAS_W, CANVAS_H, root, &prog1);
    switch (tex_result) {
        .math_bytecode => |code| try out.print("MATH_BYTECODE ({d}B, {d} iters)\n",
            .{ code.len, prog1.iterations }),
        .approximate   => |r|    try out.print("APPROXIMATE ({d}%% exact)\n", .{r.exact_pct}),
        .fallback      => |f|    try out.print("FALLBACK ({s})\n", .{@tagName(f.reason)}),
    }

    // Translate dirty_texture (expect approximate match — 75% exact)
    try out.print("  dirty_texture.raw → searching... ", .{});
    var prog2 = translator.TranslateProgress{};
    const dirty_result = try translator.translate(dirty_pixels, DIRTY_W, DIRTY_H, root, &prog2);
    switch (dirty_result) {
        .math_bytecode => |code| try out.print("MATH_BYTECODE ({d}B exact)\n", .{code.len}),
        .approximate   => |r|    try out.print("MATH_RESIDUAL ({d}%% exact, err={d}, " ++
            "delta={d}B, {d} iters)\n",
            .{ r.exact_pct, r.best_error, r.delta.len, prog2.iterations }),
        .fallback      => |f|    try out.print("FALLBACK ({s})\n", .{@tagName(f.reason)}),
    }
    try out.print("  level_script.txt  → (binary, STORE guard handles)\n", .{});
    try out.print("  bloated_random.bin→ (binary, STORE guard handles)\n\n", .{});

    // ------------------------------------------------------------------
    // Pack — build the .math container
    // ------------------------------------------------------------------
    try out.print("Packing .math container\n", .{});
    try out.print("────────────────────────\n", .{});

    var cb = container.Builder.init(root);
    defer cb.deinit();

    // File 1: shader_noise — route determined by translator
    switch (tex_result) {
        .math_bytecode => |code| {
            defer root.free(code);
            try cb.addMath("textures/shader_noise.raw", code,
                tex_pixels.len, container.fnv1a(tex_pixels));
            try out.print("  [MATH_BYTECODE]    textures/shader_noise.raw   {d}B program\n",
                .{code.len});
        },
        .approximate => |approx| {
            defer root.free(approx.bytecode);
            defer root.free(approx.delta);
            try cb.addResidual("textures/shader_noise.raw", approx.bytecode, approx.delta,
                tex_pixels.len, container.fnv1a(tex_pixels));
            try out.print("  [MATH_RESIDUAL]    textures/shader_noise.raw   " ++
                "{d}% exact\n", .{approx.exact_pct});
        },
        .fallback => {
            const d = try cb.addBinary("textures/shader_noise.raw", tex_pixels);
            try out.print("  [{s:<14}]  textures/shader_noise.raw   {d}B\n",
                .{ @tagName(d.comp_type), d.stored_size });
        },
    }

    // File 2: dirty_texture — route determined by translator (expect MATH_RESIDUAL)
    switch (dirty_result) {
        .math_bytecode => |code| {
            defer root.free(code);
            try cb.addMath("textures/dirty_texture.raw", code,
                dirty_pixels.len, container.fnv1a(dirty_pixels));
            try out.print("  [MATH_BYTECODE]    textures/dirty_texture.raw  {d}B program\n",
                .{code.len});
        },
        .approximate => |approx| {
            defer root.free(approx.bytecode);
            defer root.free(approx.delta);
            const bc_len = approx.bytecode.len;
            const delta_raw_len = approx.delta.len;
            try cb.addResidual("textures/dirty_texture.raw", approx.bytecode, approx.delta,
                dirty_pixels.len, container.fnv1a(dirty_pixels));
            try out.print("  [MATH_RESIDUAL]    textures/dirty_texture.raw  " ++
                "{d}B bytecode + {d}B delta raw\n",
                .{ bc_len, delta_raw_len });
        },
        .fallback => {
            const d = try cb.addBinary("textures/dirty_texture.raw", dirty_pixels);
            try out.print("  [{s:<14}]  textures/dirty_texture.raw  {d}B\n",
                .{ @tagName(d.comp_type), d.stored_size });
        },
    }

    // File 3: script → gzip vs STORE
    const script_d = try cb.addBinary("data/level_script.txt", script_raw);
    if (script_d.guard_fired) {
        try out.print("  [STORE]            data/level_script.txt       {d}B raw  ← guard fired\n",
            .{script_d.stored_size});
    } else {
        try out.print("  [FALLBACK_STREAM]  data/level_script.txt       {d}B gzip (was {d}B, {d:.1}x)\n",
            .{ script_d.stored_size, script_raw.len,
               @as(f64, @floatFromInt(script_raw.len)) /
                   @as(f64, @floatFromInt(script_d.stored_size)) });
    }

    // File 4: random binary → STORE guard
    const bloat_d = try cb.addBinary("binary/bloated_random.bin", bloat_data);
    if (bloat_d.guard_fired) {
        try out.print("  [STORE]            binary/bloated_random.bin   {d}B raw  " ++
            "← GUARD FIRED (gzip +{d}B)\n",
            .{ bloat_d.stored_size,
               bloat_d.gzip_would_have_been - bloat_d.stored_size });
    } else {
        try out.print("  [FALLBACK_STREAM]  binary/bloated_random.bin   {d}B gzip\n",
            .{bloat_d.stored_size});
    }

    // Serialise to an in-memory buffer.
    var archive_buf = std.ArrayList(u8).init(root);
    defer archive_buf.deinit();
    try cb.write(archive_buf.writer());
    const archive = archive_buf.items;

    const total_input = tex_pixels.len + dirty_pixels.len + script_raw.len + bloat_data.len;
    try out.print("\n  Total input  : {d}B\n", .{total_input});
    try out.print("  .math output : {d}B  (includes {d}B header + FAT overhead)\n",
        .{ archive.len, container.HEADER_SIZE + container.FAT_ENTRY_SIZE * 4 });
    try out.print("  Payload only : {d}B\n",
        .{archive.len - container.HEADER_SIZE - container.FAT_ENTRY_SIZE * 4});
    try out.print("  Ratio        : {d:.2}x vs raw\n\n", .{
        @as(f64, @floatFromInt(total_input)) / @as(f64, @floatFromInt(archive.len)),
    });

    // ------------------------------------------------------------------
    // Unpack + bit-perfect verification
    // ------------------------------------------------------------------
    try out.print("Unpack + bit-perfect verification\n", .{});
    try out.print("──────────────────────────────────\n", .{});

    var rdr = try container.Reader.parse(archive, root);
    defer rdr.deinit();

    const verify_files = [_]struct { path: []const u8, original: []const u8 }{
        .{ .path = "textures/shader_noise.raw",  .original = tex_pixels   },
        .{ .path = "textures/dirty_texture.raw", .original = dirty_pixels  },
        .{ .path = "data/level_script.txt",      .original = script_raw    },
        .{ .path = "binary/bloated_random.bin",  .original = bloat_data    },
    };

    var all_ok = true;
    for (verify_files) |f| {
        const entry = blk: {
            for (rdr.fat) |*e| {
                if (std.mem.eql(u8, e.getPath(), f.path)) break :blk e;
            }
            unreachable;
        };
        const back = try rdr.extract(f.path, root);
        defer root.free(back);
        const ok = std.mem.eql(u8, f.original, back);
        all_ok = all_ok and ok;
        try out.print("  {s:<36}  {s:<14}  bit-perfect: {}\n",
            .{ f.path, @tagName(entry.comp_type), ok });
    }

    try out.print("\n", .{});
    if (all_ok) {
        try out.print("RESULT: All four routes verified bit-perfectly.\n", .{});
        try out.print("  MATH_BYTECODE   — bit-exact synthesis from a tiny program\n", .{});
        try out.print("  MATH_RESIDUAL   — approximate program + gzip delta (4th route)\n", .{});
        try out.print("  FALLBACK_STREAM — gzip compressed (repetitive/structured data)\n", .{});
        try out.print("  STORE           — raw bytes (GUARD prevented gzip inflation)\n", .{});
        try out.print("\n  The container degrades gracefully. No file is ever inflated.\n", .{});
    } else {
        try out.print("RESULT: VERIFICATION FAILED — this is a bug.\n", .{});
    }
}

const TranslateProgress = translator.TranslateProgress;

// ---------------------------------------------------------------------------
// Pack / Unpack CLI
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Parallel pack pipeline
// ---------------------------------------------------------------------------

/// Files larger than this are stream-compressed from disk instead of being
/// loaded into memory (and are never math-translated — the structural gate
/// rejects anything this size anyway).
const STREAM_THRESHOLD: u64 = 256 * 1024 * 1024;

/// Effort tier shared by the C-ABI: 0=Fast, 1=Balanced, 2=Max. Maps to the
/// gzip DEFLATE level, the mathpress search budget, and (full mode) the real
/// `zip` compression level. Standard gzip always had levels 1–9; mathpress
/// always had a search budget — this exposes both as one user-facing dial.
const Effort = struct {
    comp: container.Compressor, // codec + level for data blocks (zstd)
    math_iters: u32,
    zip_level: u8, // real-zip level for full mode (1..9)
    tier: u8, // 0=Fast 1=Balanced 2=Max (gates filter trials)

    fn fromTier(tier: u8) Effort {
        return .{
            .tier = tier,
            .comp = container.Compressor.fromTier(tier),
            // Iterative noise-search budget. The analytical detectors always
            // run — they're O(n) and they're the routes that fire on real
            // files. The noise search only ever matches procedurally-generated
            // content, so it's a Max-tier feature: benchmarked across real
            // corpora it found nothing at any budget while costing 30-70× the
            // pack time once arbitrary-length files became eligible.
            .math_iters = switch (tier) {
                2 => 40_000,
                else => 0,
            },
            .zip_level = switch (tier) {
                0 => 1,
                2 => 9,
                else => 6,
            },
        };
    }
};

// Shared host-progress channel for the C-ABI pack paths. All fields are
// optional/atomic so the CLI (which doesn't report to a GUI) can leave them
// at defaults and the same job wrappers work for both.
const PackProgress = struct {
    progress_ptr: ?*std.atomic.Value(f32) = null,
    ticker_ptr: ?[*]u8 = null,
    ticker_mu: std.Thread.Mutex = .{},
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    total: u32 = 0,
    // Byte-weighted progress: a 900 MB file moves the bar ~900× more than a
    // 1 MB one, so the bar tracks real work instead of file count (which sat
    // near 100% while one big file finished — the "stuck at 99%" lie).
    done_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_bytes: u64 = 0,

    /// Show the file a worker is about to process. Guarded so concurrent
    /// workers never tear the 512-byte ticker buffer the host reads.
    fn setTicker(self: *PackProgress, rel_path: []const u8) void {
        const tp = self.ticker_ptr orelse return;
        self.ticker_mu.lock();
        defer self.ticker_mu.unlock();
        @memset(tp[0..512], 0);
        const n = @min(511, rel_path.len);
        @memcpy(tp[0..n], rel_path[0..n]);
    }

    /// Push the current fraction, capped at 0.95 — the final 5% is the archive
    /// write/finalize phase, set to 1.0 only once the file is actually on disk.
    fn pushFraction(self: *PackProgress) void {
        const pp = self.progress_ptr orelse return;
        var f: f32 = 0;
        if (self.total_bytes > 0) {
            f = @as(f32, @floatFromInt(self.done_bytes.load(.monotonic))) / @as(f32, @floatFromInt(self.total_bytes));
        } else if (self.total > 0) {
            f = @as(f32, @floatFromInt(self.done.load(.monotonic))) / @as(f32, @floatFromInt(self.total));
        }
        pp.store(@min(f, 0.95), .monotonic);
    }

    /// Account `n` bytes of a file as processed (byte-weighted progress).
    fn addBytes(self: *PackProgress, n: u64) void {
        _ = self.done_bytes.fetchAdd(n, .monotonic);
        self.pushFraction();
    }

    /// Mark one job finished (drives progress only when sizes are unavailable).
    fn bump(self: *PackProgress) void {
        _ = self.done.fetchAdd(1, .monotonic);
        if (self.total_bytes == 0) self.pushFraction();
    }
};

/// Cooperative pause/cancel check run at the top of every job.
/// Returns true if the caller should stop (cancel requested).
fn jobShouldStop(cancel_flag: ?*const std.atomic.Value(u8)) bool {
    const cf = cancel_flag orelse return false;
    while (cf.load(.monotonic) == 2) std.time.sleep(50 * std.time.ns_per_ms);
    return cf.load(.monotonic) == 1;
}

const PackCtx = struct {
    alloc: std.mem.Allocator,
    base_dir: []const u8,
    cb: *container.StreamingBuilder,
    cb_mu: std.Thread.Mutex = .{},
    total_raw: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    file_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    print_mu: std.Thread.Mutex = .{},
    out: std.io.AnyWriter,
    cancel_flag: ?*const std.atomic.Value(u8) = null,
    progress: PackProgress = .{},
    effort: Effort = Effort.fromTier(1),
};

fn processFileJob(ctx: *PackCtx, rel_path: []u8) void {
    defer ctx.progress.bump();
    if (jobShouldStop(ctx.cancel_flag)) return;
    ctx.progress.setTicker(rel_path);
    packFileParallel(ctx, rel_path) catch |err| {
        var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  ERROR     {s} ({s})\n",
            .{ rel_path, @errorName(err) }) catch return;
        ctx.print_mu.lock();
        defer ctx.print_mu.unlock();
        ctx.out.writeAll(line) catch {};
    };
}

/// Sum the byte sizes of every job (one stat each) for byte-weighted progress.
fn sumJobBytes(base_dir: []const u8, jobs: []const []u8) u64 {
    var total: u64 = 0;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (jobs) |rel| {
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, rel }) catch continue;
        const st = std.fs.cwd().statFile(full) catch continue;
        total += st.size;
    }
    return total;
}

/// Parallel driver for the per-file (no solid grouping) VFS pack path.
fn runStreamJobsParallel(
    root: std.mem.Allocator,
    ctx: *PackCtx,
    jobs: []const []u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) !void {
    ctx.progress = .{
        .progress_ptr = progress_ptr,
        .ticker_ptr = ticker_ptr,
        .total = @intCast(jobs.len),
        .total_bytes = sumJobBytes(ctx.base_dir, jobs),
    };

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = root, .n_jobs = null });
    defer pool.deinit();

    var wg = std.Thread.WaitGroup{};
    for (jobs) |rel_path| pool.spawnWg(&wg, processFileJob, .{ ctx, rel_path });
    pool.waitAndWork(&wg);

    if (cancel_flag.load(.monotonic) == 1) return error.Cancelled;
    ctx.progress.setTicker("Finalizing archive…");
}

fn packFileParallel(ctx: *PackCtx, rel_path: []u8) !void {
    if (rel_path.len >= container.MAX_PATH_LEN) {
        var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf,
            "  SKIP      {s} (path too long: {d} chars)\n", .{ rel_path, rel_path.len });
        ctx.print_mu.lock();
        defer ctx.print_mu.unlock();
        try ctx.out.writeAll(line);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build full path and open the file.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ ctx.base_dir, rel_path });

    // Symlinks: store the target path, never follow the link.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.cwd().readLink(full_path, &link_buf)) |target| {
        {
            ctx.cb_mu.lock();
            defer ctx.cb_mu.unlock();
            try ctx.cb.addSymlink(rel_path, target);
        }
        _ = ctx.file_count.fetchAdd(1, .monotonic);
        var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "  SYMLINK   {s}\n", .{rel_path});
        ctx.print_mu.lock();
        defer ctx.print_mu.unlock();
        try ctx.out.writeAll(line);
        return;
    } else |_| {}

    const file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
        var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "  SKIP      {s} ({s})\n",
            .{ rel_path, @errorName(err) });
        ctx.print_mu.lock();
        defer ctx.print_mu.unlock();
        try ctx.out.writeAll(line);
        return;
    };
    defer file.close();
    const fsize = try file.getEndPos();

    // Files past the in-memory threshold are stream-compressed straight to the
    // temp data region. They used to be silently skipped — data loss.
    if (fsize > STREAM_THRESHOLD) {
        const d = blk: {
            ctx.cb_mu.lock();
            defer ctx.cb_mu.unlock();
            break :blk try ctx.cb.addBinaryStreamingFile(rel_path, file, fsize);
        };
        _ = ctx.total_raw.fetchAdd(fsize, .monotonic);
        ctx.progress.addBytes(fsize);
        _ = ctx.file_count.fetchAdd(1, .monotonic);
        var buf: [std.fs.max_path_bytes + 96]u8 = undefined;
        const sline = try std.fmt.bufPrint(&buf, "  {s}  {s} ({d}B streamed → {d}B)\n",
            .{ if (d.guard_fired) "STORE-S " else "FALLBK-S", rel_path, fsize, d.stored_size });
        ctx.print_mu.lock();
        defer ctx.print_mu.unlock();
        try ctx.out.writeAll(sline);
        return;
    }

    const data = file.readToEndAlloc(alloc, STREAM_THRESHOLD) catch |err| {
        var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "  SKIP      {s} ({s})\n",
            .{ rel_path, @errorName(err) });
        ctx.print_mu.lock();
        defer ctx.print_mu.unlock();
        try ctx.out.writeAll(line);
        return;
    };

    const csum = container.fnv1a(data);
    const orig_size = data.len;

    // Math translation (CPU-intensive, runs outside the lock).
    const canvas = canvasForLen(data.len);
    var prog_info = translator.TranslateProgress{ .cancel_flag = ctx.cancel_flag, .max_iters = if (data.len > 16 * 1024) 0 else ctx.effort.math_iters };
    const result = try translator.translate(data, canvas.w, canvas.h, alloc, &prog_info);

    // Gzip compression also runs outside the lock — this is the hot path for
    // the vast majority of files that go through FALLBACK or STORE.
    // We build the FAT entry and pre-compressed block here, then hold the lock
    // only for the cheap tmp-file write + FAT append.
    var line_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
    var line: []const u8 = undefined;

    var fat = container.FatEntry{
        .comp_type = .math_bytecode, // overwritten in every arm below
        .data_offset = 0,            // assigned by appendBlock
        .original_size = @intCast(orig_size),
        .compressed_size = 0,
        .checksum = csum,
        .codec = ctx.effort.comp.codec,
    };
    try fat.setPath(rel_path);

    switch (result) {
        .math_bytecode => |code| {
            fat.comp_type = .math_bytecode;
            fat.compressed_size = code.len;
            {
                ctx.cb_mu.lock();
                defer ctx.cb_mu.unlock();
                try ctx.cb.appendBlock(fat, code);
            }
            line = try std.fmt.bufPrint(&line_buf,
                "  MATH      {s} ({d}B → {d}B program)\n",
                .{ rel_path, orig_size, code.len });
        },
        .approximate => |approx| {
            // Compress delta outside the lock.
            const gz_delta = try ctx.effort.comp.compress(approx.delta, alloc);
            const block_len = 1 + approx.bytecode.len + 8 + gz_delta.len;
            const block = try alloc.alloc(u8, block_len);
            block[0] = @intCast(approx.bytecode.len);
            @memcpy(block[1..][0..approx.bytecode.len], approx.bytecode);
            std.mem.writeInt(u64, block[1 + approx.bytecode.len ..][0..8], gz_delta.len, .little);
            @memcpy(block[1 + approx.bytecode.len + 8 ..], gz_delta);

            // Residual honesty guard: program+delta must beat compressing the
            // whole file, or the "math" is pure overhead dressed up as a win.
            const gz_whole = try ctx.effort.comp.compress(data, alloc);
            if (gz_whole.len <= block_len) {
                const wins = gz_whole.len < data.len;
                fat.comp_type = if (wins) .fallback_stream else .store;
                const payload = if (wins) gz_whole else data;
                fat.compressed_size = payload.len;
                {
                    ctx.cb_mu.lock();
                    defer ctx.cb_mu.unlock();
                    try ctx.cb.appendBlock(fat, payload);
                }
                line = try std.fmt.bufPrint(&line_buf,
                    "  {s}  {s} ({d}B — residual guard fired)\n",
                    .{ if (wins) "FALLBACK" else "STORE   ", rel_path, orig_size });
            } else {
                fat.comp_type = .math_residual;
                fat.compressed_size = block_len;
                {
                    ctx.cb_mu.lock();
                    defer ctx.cb_mu.unlock();
                    try ctx.cb.appendBlock(fat, block);
                }
                line = try std.fmt.bufPrint(&line_buf,
                    "  RESIDUAL  {s} ({d}B, {d}% exact)\n",
                    .{ rel_path, orig_size, approx.exact_pct });
            }
        },
        .fallback => {
            // Pick the cheapest reversible representation outside the lock:
            // STORE / plain compress / per-block math / filtered (delta, BCJ).
            const rep = try chooseFallbackRep(data, ctx.effort, alloc);
            const block = rep.payload orelse data;
            fat.comp_type = rep.comp_type;
            fat.compressed_size = block.len;
            {
                ctx.cb_mu.lock();
                defer ctx.cb_mu.unlock();
                try ctx.cb.appendBlock(fat, block);
            }
            line = try std.fmt.bufPrint(&line_buf,
                "  {s}  {s} ({d}B → {d}B, {d:.1}x)\n",
                .{ fallbackLabel(rep.comp_type), rel_path, orig_size, block.len,
                   @as(f64, @floatFromInt(orig_size)) / @as(f64, @floatFromInt(@max(1, block.len))) });
        },
    }

    _ = ctx.total_raw.fetchAdd(@intCast(orig_size), .monotonic);
    ctx.progress.addBytes(@intCast(orig_size));
    _ = ctx.file_count.fetchAdd(1, .monotonic);

    ctx.print_mu.lock();
    defer ctx.print_mu.unlock();
    try ctx.out.writeAll(line);
}

// Walk the directory tree and collect relative file paths into `jobs`.
// Iteratively collect every regular file under `base_dir` into `jobs`, as paths
// relative to `base_dir`. Two properties matter for real-world trees and must
// not regress:
//
//   * Resilience: an unreadable directory (EACCES), a vanished entry, or a
//     mid-iteration error skips just that subtree — it never aborts the whole
//     pack. Real folders routinely contain directories the caller can't descend
//     into; a single one of them used to fail the entire operation (rc -1).
//   * Bounded stack: traversal uses an explicit heap worklist instead of native
//     recursion. The C-ABI entry points run on the host's thread (a 2 MiB Rust
//     stack), and the old recursion burned ~8 KiB of path buffers per directory
//     level, so a deep tree overflowed the stack and segfaulted.
//
// `rel_prefix` seeds the walk (normally ""); `path_buf` is reused as scratch.
fn collectWalk(
    alloc: std.mem.Allocator,
    base_dir: []const u8,
    rel_prefix: []const u8,
    path_buf: *[std.fs.max_path_bytes]u8,
    jobs: *std.ArrayList([]u8),
    cancel: ?*const std.atomic.Value(u8),
) !void {
    var pending = std.ArrayList([]u8).init(alloc);
    defer {
        for (pending.items) |p| alloc.free(p);
        pending.deinit();
    }
    try pending.append(try alloc.dupe(u8, rel_prefix));

    // Index-based worklist: appends may realloc `pending`, but every `rel` is a
    // slice into a separately heap-allocated dupe, so it stays valid across them.
    var i: usize = 0;
    while (i < pending.items.len) : (i += 1) {
        // Enumeration of a huge tree can take a while; honor cancel here too,
        // not just in the per-file pack loop, so the user's Cancel is responsive.
        if (cancel) |c| {
            while (c.load(.monotonic) == 2) { std.time.sleep(100 * std.time.ns_per_ms); }
            if (c.load(.monotonic) == 1) return error.Cancelled;
        }
        const rel = pending.items[i];

        const abs = if (rel.len == 0)
            base_dir
        else
            try std.fmt.bufPrint(path_buf, "{s}/{s}", .{ base_dir, rel });

        // Skip on directories we can't open, but log the error so it isn't swallowed
        var dir = std.fs.cwd().openDir(abs, .{ .iterate = true }) catch |err| {
            std.debug.print("Skipping directory {s}: {s}\n", .{abs, @errorName(err)});
            continue;
        };
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch |err| {
            std.debug.print("Error iterating directory {s}: {s}\n", .{abs, @errorName(err)});
            break;
        }) |entry| {
            var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
            const child_rel = if (rel.len == 0)
                std.fmt.bufPrint(&rel_buf, "{s}", .{entry.name}) catch continue
            else
                std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ rel, entry.name }) catch continue;

            switch (entry.kind) {
                .directory => try pending.append(try alloc.dupe(u8, child_rel)),
                // Symlinks travel through the same job list; the pack workers
                // detect them via readLink and store the target path.
                .file, .sym_link => try jobs.append(try alloc.dupe(u8, child_rel)),
                else => {},
            }
        }
    }
}

// Drop the output archive itself from the job list. The GUI writes the
// destination .math inside the directory being packed, so without this a
// repack would swallow the previous run's archive into the new one.
fn removeOutputJob(
    jobs: *std.ArrayList([]u8),
    alloc: std.mem.Allocator,
    base_dir: []const u8,
    out_path: []const u8,
) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var i: usize = 0;
    while (i < jobs.items.len) {
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, jobs.items[i] }) catch {
            i += 1;
            continue;
        };
        if (std.mem.eql(u8, full, out_path)) {
            alloc.free(jobs.items[i]);
            _ = jobs.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

fn packDirectory(root: std.mem.Allocator, dir_path: []const u8, out_path: []const u8, out: anytype) !void {
    var cb = try container.StreamingBuilder.init(root);
    cb.comp = Effort.fromTier(1).comp; // CLI defaults to balanced
    defer cb.deinit();

    // Phase 1: collect all relative file paths (serial, fast — just readdir).
    var jobs = std.ArrayList([]u8).init(root);
    defer {
        for (jobs.items) |p| root.free(p);
        jobs.deinit();
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try collectWalk(root, dir_path, "", &path_buf, &jobs, null);
    removeOutputJob(&jobs, root, dir_path, out_path);

    // Phase 2: compress + pack files in parallel across all CPU cores.
    // Each thread owns its arena; only the tmp-file write is serialised.
    var ctx = PackCtx{
        .alloc = root,
        .base_dir = dir_path,
        .cb = &cb,
        .out = out.any(),
    };

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = root, .n_jobs = null });
    defer pool.deinit();

    var wg = std.Thread.WaitGroup{};
    for (jobs.items) |rel_path| {
        pool.spawnWg(&wg, processFileJob, .{ &ctx, rel_path });
    }
    pool.waitAndWork(&wg);

    // Phase 3: write header + FAT + stream data to the output file.
    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try cb.finish(out_file);

    const fat_overhead = HEADER_SIZE + FAT_ENTRY_SIZE * cb.entryCount();
    const container_size = fat_overhead + cb.dataBytes();
    const total_raw = ctx.total_raw.load(.monotonic);
    const file_count = ctx.file_count.load(.monotonic);

    const ratio = if (container_size > 0)
        @as(f64, @floatFromInt(total_raw)) / @as(f64, @floatFromInt(container_size))
    else
        0.0;

    try out.print("\n  Files packed   : {d}\n", .{file_count});
    try out.print("  Raw total      : {d:.1} MB\n",
        .{@as(f64, @floatFromInt(total_raw)) / (1024 * 1024)});
    try out.print("  Container size : {d:.1} MB\n",
        .{@as(f64, @floatFromInt(container_size)) / (1024 * 1024)});
    try out.print("  Ratio          : {d:.2}x\n", .{ratio});
    try out.print("Wrote {s}\n", .{out_path});
}

const HEADER_SIZE = container.HEADER_SIZE;
const FAT_ENTRY_SIZE = container.FAT_ENTRY_SIZE;

/// Serialize a BlockPlan into the MATH_BLOCKS container payload (see
/// container.extractMathBlocks for the wire layout). The literal stream is
/// compressed with the effort codec; everything else is descriptor bytes.
fn buildMathBlocksPayload(
    plan: translator.BlockPlan,
    comp: container.Compressor,
    alloc: std.mem.Allocator,
) ![]u8 {
    const gz_lit: []const u8 = if (plan.literals.len > 0)
        try comp.compress(plan.literals, alloc)
    else
        &.{};
    const len = 4 + 4 + plan.kinds.len + plan.params.len + 8 + gz_lit.len;
    const out = try alloc.alloc(u8, len);
    std.mem.writeInt(u32, out[0..4], @intCast(translator.BLOCK_SIZE), .little);
    std.mem.writeInt(u32, out[4..8], @intCast(plan.kinds.len), .little);
    @memcpy(out[8..][0..plan.kinds.len], plan.kinds);
    @memcpy(out[8 + plan.kinds.len ..][0..plan.params.len], plan.params);
    std.mem.writeInt(u64, out[8 + plan.kinds.len + plan.params.len ..][0..8], gz_lit.len, .little);
    @memcpy(out[8 + plan.kinds.len + plan.params.len + 8 ..], gz_lit);
    return out;
}

/// Cheap stride-sampled prescreen: does this look like x86 machine code?
/// Real code carries a high density of E8 (CALL) / E9 (JMP) opcodes; data
/// rarely does. Used to avoid wasting a BCJ compression trial on non-code.
fn looksLikeX86(data: []const u8) bool {
    if (data.len < 512) return false;
    const stride = @max(1, data.len / 4096);
    var seen: usize = 0;
    var hits: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += stride) {
        seen += 1;
        if (data[i] == 0xE8 or data[i] == 0xE9) hits += 1;
    }
    // ≥ ~0.8% of sampled bytes are call/jump opcodes.
    return seen > 0 and hits * 128 >= seen;
}

/// Try the reversible filters viable at this effort tier, compress each, and
/// return the smallest `[filter_id][compressed]` payload — or null if filters
/// are disabled (Fast) or the file is too small. The honesty guard at the call
/// site decides whether this actually beats the unfiltered representations.
fn bestFilteredBlock(data: []const u8, effort: Effort, alloc: std.mem.Allocator) !?[]u8 {
    if (effort.tier == 0 or data.len < 64) return null;

    var cand: [4]container.Filter = undefined;
    var n: usize = 0;
    cand[n] = .delta1;
    n += 1;
    if (effort.tier >= 2) {
        cand[n] = .delta2;
        n += 1;
        cand[n] = .delta4;
        n += 1;
    }
    if (effort.tier >= 2 or looksLikeX86(data)) {
        cand[n] = .bcj_x86;
        n += 1;
    }

    var best: ?[]u8 = null;
    var best_filter: container.Filter = .none;
    for (cand[0..n]) |f| {
        const filtered = try container.applyFilter(f, data, alloc);
        defer alloc.free(filtered);
        const gz = try effort.comp.compress(filtered, alloc);
        if (best == null or gz.len < best.?.len) {
            if (best) |b| alloc.free(b);
            best = gz;
            best_filter = f;
        } else alloc.free(gz);
    }

    const b = best orelse return null;
    defer alloc.free(b);
    const payload = try alloc.alloc(u8, 1 + b.len);
    payload[0] = @intFromEnum(best_filter);
    @memcpy(payload[1..], b);
    return payload;
}

/// True if a sample of the data is mostly printable text. The AoS->SoA
/// transpose helps binary record arrays, never prose, so this skips the trials
/// on text cheaply.
fn looksTexty(data: []const u8) bool {
    const step = @max(@as(usize, 1), data.len / 4096);
    var printable: usize = 0;
    var seen: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += step) {
        const c = data[i];
        if ((c >= 0x20 and c < 0x7F) or c == '\t' or c == '\n' or c == '\r') printable += 1;
        seen += 1;
    }
    return seen > 0 and printable * 100 >= seen * 90;
}

/// Detect a record-array stride and return the columnar (AoS->SoA) payload
/// `[u16 stride][compressed transposed]` if transposing genuinely shrinks the
/// data, else null. The win on record data (vertex/index buffers, float tables)
/// is distribution *separation* — grouping each field's bytes into compressible
/// runs — which a similarity probe can't see, so we instead RANK candidate
/// strides with a fast compression pass and commit the winner at full effort.
/// The honesty guard at the call site still discards it unless it actually wins.
fn bestColumnarBlock(data: []const u8, effort: Effort, alloc: std.mem.Allocator) !?[]u8 {
    // Gate: skip Fast tier, tiny files, oversized files (cost), and text.
    if (effort.tier == 0 or data.len < 8192 or data.len > 16 * 1024 * 1024) return null;
    if (looksTexty(data)) return null;

    const STRIDES = [_]usize{ 2, 3, 4, 6, 8, 12, 16, 20, 24, 32, 48, 64 };
    // Fast-level baseline: only bother if a transpose beats plain at this level.
    const plain_rank = (try container.zstdCompress(data, alloc, 1)).len;

    var best_stride: usize = 0;
    var best_rank: usize = plain_rank;
    for (STRIDES) |s| {
        if (data.len < s * 8) continue;
        const t = try container.columnarForward(data, s, alloc);
        defer alloc.free(t);
        const rank = (try container.zstdCompress(t, alloc, 1)).len;
        if (rank < best_rank) {
            best_rank = rank;
            best_stride = s;
        }
    }
    if (best_stride == 0) return null; // no stride beat plain even at fast level

    // Commit the winning stride at the real effort codec.
    const t = try container.columnarForward(data, best_stride, alloc);
    defer alloc.free(t);
    const comp = try effort.comp.compress(t, alloc);
    defer alloc.free(comp);
    const payload = try alloc.alloc(u8, 2 + comp.len);
    std.mem.writeInt(u16, payload[0..2], @intCast(best_stride), .little);
    @memcpy(payload[2..], comp);
    return payload;
}

const ImageInfo = struct { header_len: usize, footer_len: usize, width: u32, height: u32, channels: u8 };

/// Parse known uncompressed raster headers to get geometry for the 2D
/// predictor: TGA (uncompressed truecolor/grayscale, optional 26-byte TGA-2.0
/// footer) and binary PGM/PPM (P5/P6). Returns null for anything else (RLE,
/// odd maxval, size mismatch). header + width*height*channels + footer must
/// exactly cover the file.
fn detectImage(data: []const u8) ?ImageInfo {
    // --- TGA ---
    if (data.len >= 18 and data[1] == 0 and (data[2] == 2 or data[2] == 3)) {
        const idlen: usize = data[0];
        const w: u32 = std.mem.readInt(u16, data[12..14], .little);
        const h: u32 = std.mem.readInt(u16, data[14..16], .little);
        const ch: u8 = switch (data[16]) { 8 => 1, 24 => 3, 32 => 4, else => 0 };
        if (ch != 0 and w > 0 and h > 0) {
            const hl = 18 + idlen;
            const pix = @as(u64, w) * h * ch;
            if (hl + pix == data.len)
                return .{ .header_len = hl, .footer_len = 0, .width = w, .height = h, .channels = ch };
            // TGA 2.0 footer (26 bytes ending in "TRUEVISION-XFILE.\0").
            if (hl + pix + 26 == data.len and
                std.mem.indexOf(u8, data[data.len - 26 ..], "TRUEVISION") != null)
                return .{ .header_len = hl, .footer_len = 26, .width = w, .height = h, .channels = ch };
        }
    }
    // --- Binary PGM (P5, gray) / PPM (P6, RGB) ---
    if (data.len >= 2 and data[0] == 'P' and (data[1] == '5' or data[1] == '6')) {
        const ch: u8 = if (data[1] == '5') 1 else 3;
        var i: usize = 2;
        var vals: [3]u32 = .{ 0, 0, 0 }; // width, height, maxval
        var got: usize = 0;
        while (got < 3 and i < data.len) {
            // skip whitespace and #-comments
            while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r')) i += 1;
            if (i < data.len and data[i] == '#') {
                while (i < data.len and data[i] != '\n') i += 1;
                continue;
            }
            var v: u32 = 0;
            var any = false;
            while (i < data.len and data[i] >= '0' and data[i] <= '9') {
                v = v * 10 + (data[i] - '0');
                i += 1;
                any = true;
            }
            if (!any) break;
            vals[got] = v;
            got += 1;
        }
        // One whitespace byte separates the header from binary pixel data.
        if (got == 3 and vals[2] == 255 and i < data.len) {
            const hl = i + 1;
            const w = vals[0];
            const h = vals[1];
            if (w > 0 and h > 0 and hl + @as(u64, w) * h * ch == data.len)
                return .{ .header_len = hl, .footer_len = 0, .width = w, .height = h, .channels = ch };
        }
    }
    return null;
}

/// 2D-predict a detected raster and return the MATH_IMAGE2D payload
/// `[u32 header_len][u32 w][u32 h][u8 ch][compressed (header ++ residual)]`,
/// or null if the file isn't a recognized raw image. Honesty-guarded at the
/// call site. xz/zstd/brotli have no 2D predictor, so this is net-new ground.
fn bestImage2DBlock(data: []const u8, effort: Effort, alloc: std.mem.Allocator) !?[]u8 {
    if (effort.tier == 0 or data.len < 256) return null;
    const info = detectImage(data) orelse return null;

    const pix_end = data.len - info.footer_len;
    const residual = try container.medForward(data[info.header_len..pix_end], info.width, info.height, info.channels, alloc);
    defer alloc.free(residual);
    // transformed = header ++ residual ++ footer (verbatim ends), len == data.len
    const transformed = try alloc.alloc(u8, data.len);
    defer alloc.free(transformed);
    @memcpy(transformed[0..info.header_len], data[0..info.header_len]);
    @memcpy(transformed[info.header_len..pix_end], residual);
    @memcpy(transformed[pix_end..], data[pix_end..]);

    const comp = try effort.comp.compress(transformed, alloc);
    defer alloc.free(comp);
    const payload = try alloc.alloc(u8, 17 + comp.len);
    std.mem.writeInt(u32, payload[0..4], @intCast(info.header_len), .little);
    std.mem.writeInt(u32, payload[4..8], @intCast(info.footer_len), .little);
    std.mem.writeInt(u32, payload[8..12], info.width, .little);
    std.mem.writeInt(u32, payload[12..16], info.height, .little);
    payload[16] = info.channels;
    @memcpy(payload[17..], comp);
    return payload;
}

/// Pick the cheapest reversible representation for a file the translator routed
/// to fallback: STORE (raw), plain compression, per-block math, a filtered
/// stream, a columnar transpose, or a 2D image predictor. Returns the chosen
/// comp_type and the bytes to append (`payload` is null for STORE — append the
/// raw `data`). Every candidate reconstructs the exact original; this just keeps
/// whichever is smallest. The unified "math earns its place or it isn't used".
const FallbackRep = struct { comp_type: container.CompressionType, payload: ?[]u8 };

fn chooseFallbackRep(data: []const u8, effort: Effort, alloc: std.mem.Allocator) !FallbackRep {
    var best_type: container.CompressionType = .store;
    var best_len: usize = data.len;
    var best_payload: ?[]u8 = null;

    {
        const gz = try effort.comp.compress(data, alloc);
        if (gz.len < best_len) {
            best_type = .fallback_stream;
            best_len = gz.len;
            best_payload = gz;
        } else alloc.free(gz);
    }

    if (try translator.analyzeBlocks(data, alloc)) |plan_c| {
        var plan = plan_c;
        defer plan.deinit(alloc);
        const payload = try buildMathBlocksPayload(plan, effort.comp, alloc);
        if (payload.len < best_len) {
            if (best_payload) |b| alloc.free(b);
            best_type = .math_blocks;
            best_len = payload.len;
            best_payload = payload;
        } else alloc.free(payload);
    }

    if (try bestFilteredBlock(data, effort, alloc)) |payload| {
        if (payload.len < best_len) {
            if (best_payload) |b| alloc.free(b);
            best_type = .math_filtered;
            best_len = payload.len;
            best_payload = payload;
        } else alloc.free(payload);
    }

    if (try bestColumnarBlock(data, effort, alloc)) |payload| {
        if (payload.len < best_len) {
            if (best_payload) |b| alloc.free(b);
            best_type = .math_columnar;
            best_len = payload.len;
            best_payload = payload;
        } else alloc.free(payload);
    }

    if (try bestImage2DBlock(data, effort, alloc)) |payload| {
        if (payload.len < best_len) {
            if (best_payload) |b| alloc.free(b);
            best_type = .math_image2d;
            best_len = payload.len;
            best_payload = payload;
        } else alloc.free(payload);
    }

    return .{ .comp_type = best_type, .payload = best_payload };
}

/// Human-readable route word for a fallback representation (pack logging).
fn fallbackLabel(ct: container.CompressionType) []const u8 {
    return switch (ct) {
        .fallback_stream => "FALLBACK",
        .math_blocks => "BLOCKS  ",
        .math_filtered => "FILTERED",
        .math_columnar => "COLUMNAR",
        .math_image2d => "IMAGE2D ",
        else => "STORE   ",
    };
}

/// Smallest covering canvas for an arbitrary byte length: side = ceil(√len),
/// height = ceil(len / side). canvas ≥ len always; the tail is padding the
/// extractor truncates. (The old floor(√len) only ever fit perfect squares,
/// which is why math routes never fired on real files.)
fn canvasForLen(len: usize) struct { w: u32, h: u32 } {
    if (len == 0) return .{ .w = 0, .h = 0 };
    var side: usize = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(len)))));
    if (side == 0) side = 1;
    const h = (len + side - 1) / side;
    return .{ .w = @intCast(side), .h = @intCast(h) };
}

test "canvasForLen always covers and stays near-square" {
    const cases = [_]usize{ 1, 2, 999, 1000, 1024, 2500, 65535, 65536, 1 << 20 };
    for (cases) |n| {
        const c = canvasForLen(n);
        try std.testing.expect(@as(usize, c.w) * @as(usize, c.h) >= n);
        try std.testing.expect(@as(usize, c.w) * @as(usize, c.h) < n + c.w);
    }
}

/// CLI wrapper for tar-flavoured full mode: `mathpressor packfull <dir> <out> [tier]`.
fn packFullCli(root: std.mem.Allocator, dir_path: []const u8, out_path: []const u8, tier: u8, out: anytype) !void {
    const trimmed = std.mem.trimRight(u8, dir_path, "/");
    const base = std.fs.path.dirname(trimmed) orelse ".";
    const name = std.fs.path.basename(trimmed);
    if (name.len == 0) return error.NoOutput;

    var cancel = std.atomic.Value(u8).init(0);
    var prog = std.atomic.Value(f32).init(0);
    var ticker: [512]u8 = undefined;
    try out.print("Mode: Full (solid TAR → zstd .math), effort tier {d}\n", .{tier});
    try packTarFullAbi(root, base, name, out_path, tier, &cancel, &prog, &ticker);

    const st = try std.fs.cwd().statFile(out_path);
    try out.print("Wrote {s} ({d:.1} MB)\n", .{ out_path, @as(f64, @floatFromInt(st.size)) / (1024.0 * 1024.0) });
}

/// True if `rel` is safe to join under a destination directory: relative,
/// no `..` component, no absolute/root or Windows drive prefix. Guards unpack
/// against path-traversal entries in a malicious .math archive.
fn isSafeRelPath(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (rel[0] == '/' or rel[0] == '\\') return false; // absolute
    if (rel.len >= 2 and rel[1] == ':') return false; // C:\ drive letter
    var it = std.mem.splitAny(u8, rel, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

test "isSafeRelPath rejects traversal and absolute paths" {
    try std.testing.expect(isSafeRelPath("a/b/c.txt"));
    try std.testing.expect(isSafeRelPath("deep/nested/ok.bin"));
    try std.testing.expect(!isSafeRelPath("../escape"));
    try std.testing.expect(!isSafeRelPath("a/../../escape"));
    try std.testing.expect(!isSafeRelPath("/etc/passwd"));
    try std.testing.expect(!isSafeRelPath("..\\windows"));
    try std.testing.expect(!isSafeRelPath("C:\\x"));
    try std.testing.expect(!isSafeRelPath(""));
}

/// Expand a tar-flavoured full-mode archive. The archive holds zero or more
/// MATH entries (files the pre-pass expressed as bit-perfect programs) plus
/// one wrapped solid .tar carrying everything else — all expanded natively,
/// no external tools involved.
fn unpackFullTar(root: std.mem.Allocator, rdr: *container.Reader, out_dir: []const u8, out: anytype) !void {
    if (rdr.entryCount() == 0) return error.TruncatedContainer;

    var dir = try std.fs.cwd().openDir(out_dir, .{});
    defer dir.close();

    var math_count: usize = 0;
    var warnings: usize = 0;
    var i: usize = 0;
    while (i < rdr.entryCount()) : (i += 1) {
        const entry = rdr.entryAt(i);
        const path = entry.getPath();

        // Lifted entries (whole-file program or BCJ-filtered executable) are
        // individual files; anything else is the one wrapped solid tar.
        if (entry.comp_type != .math_bytecode and entry.comp_type != .math_filtered) {
            const tar_bytes = try rdr.extract(path, root);
            defer root.free(tar_bytes);
            var fbs = std.io.fixedBufferStream(tar_bytes);
            try std.tar.pipeToFileSystem(dir, fbs.reader(), .{});
            continue;
        }

        // Lifted entry — reconstruct the file from its program/filter.
        if (!isSafeRelPath(path)) {
            warnings += 1;
            try out.print("  UNSAFE  {s}  (refused — path escapes destination)\n", .{path});
            continue;
        }
        const bytes = rdr.extract(path, root) catch |err| {
            warnings += 1;
            try out.print("  ERROR  {s}  ({s})\n", .{ path, @errorName(err) });
            continue;
        };
        defer root.free(bytes);
        if (container.fnv1a(bytes) != entry.checksum) warnings += 1;

        var fp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&fp_buf, "{s}/{s}", .{ out_dir, path });
        if (std.fs.path.dirname(full_path)) |parent| try std.fs.cwd().makePath(parent);
        const f = try std.fs.cwd().createFile(full_path, .{});
        defer f.close();
        try f.writeAll(bytes);
        math_count += 1;
    }

    try out.print("  Expanded inner .tar + {d} math entr{s} → {s}\n",
        .{ math_count, if (math_count == 1) "y" else "ies", out_dir });
    if (warnings > 0) {
        try out.print("WARNING: {d} entr{s} had checksum/extract warnings\n",
            .{ warnings, if (warnings == 1) "y" else "ies" });
    }
}

/// Expand a full-mode archive: extract the single wrapped .zip entry to a temp
/// file, then run `unzip` to restore the original files into out_dir.
fn unpackFullZip(root: std.mem.Allocator, rdr: *container.Reader, out_dir: []const u8, out: anytype) !void {
    if (rdr.entryCount() == 0) return error.TruncatedContainer;
    const entry = rdr.entryAt(0);
    const zip_bytes = try rdr.extract(entry.getPath(), root);
    defer root.free(zip_bytes);

    var tmp_buf: [128]u8 = undefined;
    const tmp_zip = try std.fmt.bufPrint(&tmp_buf, "/tmp/mathpressor_unzip_{d}.zip", .{std.time.milliTimestamp()});
    defer std.fs.cwd().deleteFile(tmp_zip) catch {};
    {
        const zf = try std.fs.cwd().createFile(tmp_zip, .{});
        defer zf.close();
        try zf.writeAll(zip_bytes);
    }

    var child = std.process.Child.init(&.{ "unzip", "-o", "-q", tmp_zip, "-d", out_dir }, root);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        std.debug.print("full mode unpack: could not launch `unzip` ({s})\n", .{@errorName(err)});
        return error.UnzipUnavailable;
    };
    const term = try child.wait();
    switch (term) {
        // unzip exit 0 = ok, 1 = warnings (e.g. extra bytes) but extraction done.
        .Exited => |code| if (code != 0 and code != 1) return error.UnzipFailed,
        else => return error.UnzipFailed,
    }
    try out.print("  Expanded real .zip → {s}\n", .{out_dir});
}

fn unpackContainer(root: std.mem.Allocator, in_path: []const u8, out_dir: []const u8, out: anytype) !void {
    // mmap the archive instead of reading it into memory: archives holding
    // streamed game data routinely exceed any fixed read cap (the old 512 MB
    // limit made large archives fail to unpack at all).
    const in_file = try std.fs.cwd().openFile(in_path, .{});
    defer in_file.close();
    const in_size = try in_file.getEndPos();
    if (in_size == 0) return error.TruncatedContainer;
    const data = try std.posix.mmap(
        null, @intCast(in_size),
        std.posix.PROT.READ, .{ .TYPE = .PRIVATE },
        in_file.handle, 0,
    );
    defer std.posix.munmap(data);

    var rdr = try container.Reader.parse(data, root);
    defer rdr.deinit();

    try std.fs.cwd().makePath(out_dir);

    // Full mode: the archive wraps a single solid .tar (or, for older archives,
    // a real .zip). Recover it and expand it back into the original files.
    if (rdr.flags & container.FLAG_FULL_TAR != 0) {
        try unpackFullTar(root, &rdr, out_dir, out);
        return;
    }
    if (rdr.flags & container.FLAG_FULL_ZIP != 0) {
        try unpackFullZip(root, &rdr, out_dir, out);
        return;
    }

    var failures: usize = 0;

    // Single-block cache for solid entries: files of one solid block sit
    // consecutively in the FAT, so caching the last decompressed block turns
    // unpack from quadratic (full block re-decompressed per file) into linear,
    // while never holding more than one block (≤ ~48 MB raw) in memory.
    var cached_offset: u64 = std.math.maxInt(u64);
    var cached_block: []u8 = &.{};
    defer if (cached_block.len > 0) root.free(cached_block);

    var i: usize = 0;
    while (i < rdr.entryCount()) : (i += 1) {
        const entry = rdr.entryAt(i);

        // Path-traversal guard: never let an archive write outside out_dir.
        // A crafted .math could carry "../../etc/cron.d/x" or "/etc/passwd";
        // refuse absolute paths and any ".." component.
        if (!isSafeRelPath(entry.getPath())) {
            failures += 1;
            try out.print("  UNSAFE  {s}  (refused — path escapes destination)\n", .{entry.getPath()});
            continue;
        }

        // One bad entry must not abort the rest of the archive.
        const reconstructed: []u8 = if (entry.comp_type == .solid_block) solid: {
            if (entry.data_offset != cached_offset) {
                if (cached_block.len > 0) root.free(cached_block);
                cached_block = &.{};
                const gz = rdr.data_region[entry.data_offset..][0..entry.compressed_size];
                cached_block = container.decompressSolidBlock(gz, entry.codec, root) catch |err| {
                    failures += 1;
                    try out.print("  ERROR  {s}  ({s})\n", .{ entry.getPath(), @errorName(err) });
                    continue;
                };
                cached_offset = entry.data_offset;
            }
            break :solid container.sliceSolidFile(
                cached_block, entry.solid_index, entry.original_size, root,
            ) catch |err| {
                failures += 1;
                try out.print("  ERROR  {s}  ({s})\n", .{ entry.getPath(), @errorName(err) });
                continue;
            };
        } else rdr.extract(entry.getPath(), root) catch |err| {
            failures += 1;
            try out.print("  ERROR  {s}  ({s})\n", .{ entry.getPath(), @errorName(err) });
            continue;
        };
        defer root.free(reconstructed);

        const actual_csum = container.fnv1a(reconstructed);
        const csum_ok = actual_csum == entry.checksum;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ out_dir, entry.getPath() });
        if (std.fs.path.dirname(full_path)) |parent| {
            try std.fs.cwd().makePath(parent);
        }

        if (entry.comp_type == .symlink) {
            // `reconstructed` holds the raw target path.
            std.fs.cwd().deleteFile(full_path) catch {};
            std.fs.cwd().symLink(reconstructed, full_path, .{}) catch |err| {
                failures += 1;
                try out.print("  ERROR  {s}  (symlink: {s})\n", .{ entry.getPath(), @errorName(err) });
                continue;
            };
            try out.print("  {s}  → {s}  (symlink)\n", .{ entry.getPath(), reconstructed });
            if (!csum_ok) failures += 1;
            continue;
        }

        const f = try std.fs.cwd().createFile(full_path, .{});
        defer f.close();
        try f.writeAll(reconstructed);

        try out.print("  {s}  {d}B  checksum_ok={}\n", .{ entry.getPath(), reconstructed.len, csum_ok });
        if (!csum_ok) failures += 1;
    }

    // Report per-entry warnings but do NOT fail the whole unpack: the files
    // that extracted are on disk and usable. A non-zero exit here made the GUI
    // wrongly report "unpack failed" when a single advisory checksum warning
    // fired. Only genuine open/parse/mmap errors (above) propagate as failure.
    if (failures > 0) {
        try out.print("WARNING: {d} entr{s} had checksum/extract warnings (other files extracted fine)\n",
            .{ failures, if (failures == 1) "y" else "ies" });
    }
}

/// Verify every entry's FNV-1a against its stored checksum, in-engine.
/// Writes total and failed counts through the out pointers. Uses the same
/// single-solid-block cache as unpack so a big solid archive verifies in one
/// linear pass instead of re-decompressing each block per file (the GUI's old
/// per-entry path reloaded the .so and re-decompressed for every file).
pub fn verifyArchiveAbi(
    root: std.mem.Allocator,
    in_path: []const u8,
    out_total: *u32,
    out_failed: *u32,
) !void {
    const in_file = try std.fs.cwd().openFile(in_path, .{});
    defer in_file.close();
    const in_size = try in_file.getEndPos();
    if (in_size == 0) return error.TruncatedContainer;
    const data = try std.posix.mmap(
        null, @intCast(in_size),
        std.posix.PROT.READ, .{ .TYPE = .PRIVATE },
        in_file.handle, 0,
    );
    defer std.posix.munmap(data);

    var rdr = try container.Reader.parse(data, root);
    defer rdr.deinit();

    var cached_offset: u64 = std.math.maxInt(u64);
    var cached_block: []u8 = &.{};
    defer if (cached_block.len > 0) root.free(cached_block);

    var total: u32 = 0;
    var failed: u32 = 0;
    var i: usize = 0;
    while (i < rdr.entryCount()) : (i += 1) {
        const entry = rdr.entryAt(i);
        total += 1;

        const bytes: []u8 = if (entry.comp_type == .solid_block) solid: {
            if (entry.data_offset != cached_offset) {
                if (cached_block.len > 0) root.free(cached_block);
                cached_block = &.{};
                const gz = rdr.data_region[entry.data_offset..][0..entry.compressed_size];
                cached_block = container.decompressSolidBlock(gz, entry.codec, root) catch {
                    failed += 1;
                    continue;
                };
                cached_offset = entry.data_offset;
            }
            break :solid container.sliceSolidFile(
                cached_block, entry.solid_index, entry.original_size, root,
            ) catch {
                failed += 1;
                continue;
            };
        } else rdr.extract(entry.getPath(), root) catch {
            failed += 1;
            continue;
        };
        defer root.free(bytes);

        if (container.fnv1a(bytes) != entry.checksum) failed += 1;
    }

    out_total.* = total;
    out_failed.* = failed;
}

// ---------------------------------------------------------------------------
// File-to-PGM mode
// ---------------------------------------------------------------------------

fn runFile(root: std.mem.Allocator, in_path: []const u8, out_path: []const u8, out: anytype) !void {
    const code = try std.fs.cwd().readFileAlloc(root, in_path, 1 << 20);
    defer root.free(code);
    var arena = std.heap.ArenaAllocator.init(root);
    defer arena.deinit();
    var m = vm.Vm.init(arena.allocator());
    const px = try m.execute(code);
    try writePgm(out_path, px, m.width, m.height);
    try out.print("wrote {s} — {d}x{d}, checksum 0x{x:0>8}\n",
        .{ out_path, m.width, m.height, container.fnv1a(px) });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const Stats = struct { min: u8, max: u8, mean: u32 };
fn pixelStats(px: []const u8) Stats {
    var mn: u8 = 255; var mx: u8 = 0; var sum: u64 = 0;
    for (px) |p| {
        if (p < mn) mn = p;
        if (p > mx) mx = p;
        sum += p;
    }
    return .{ .min = mn, .max = mx, .mean = if (px.len == 0) 0 else @intCast(sum / px.len) };
}

fn printAscii(out: anytype, px: []const u8, w: u32, h: u32) !void {
    const ramp = " .:-=+*#%@";
    const cols: u32 = @min(w, 64);
    const rows: u32 = @min(h, 32);
    var ry: u32 = 0;
    while (ry < rows) : (ry += 1) {
        var rx: u32 = 0;
        while (rx < cols) : (rx += 1) {
            const v = px[@as(usize, ry * h / rows) * @as(usize, w) + @as(usize, rx * w / cols)];
            try out.print("{c}", .{ramp[@as(usize, v) * (ramp.len - 1) / 255]});
        }
        try out.print("\n", .{});
    }
}

fn writePgm(path: []const u8, px: []const u8, w: u32, h: u32) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    var bw = std.io.bufferedWriter(f.writer());
    try bw.writer().print("P5\n{d} {d}\n255\n", .{ w, h });
    try bw.writer().writeAll(px);
    try bw.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    std.testing.refAllDeclsRecursive(@This());
    _ = @import("vm.zig");
    _ = @import("math_gen.zig");
    _ = @import("abi.zig");
    _ = @import("container.zig");
    _ = @import("translator.zig");
}

test "demo helpers" {
    const data = [_]u8{ 0, 128, 255, 64 };
    try std.testing.expectEqual(@as(u8, 0), pixelStats(&data).min);
    try std.testing.expectEqual(@as(u8, 255), pixelStats(&data).max);
}

test "gzip helper round-trips" {
    const a = std.testing.allocator;
    const src = "hello mathpressor" ** 50;
    const gz = try container.gzipCompress(src, a, .fast);
    defer a.free(gz);
    try std.testing.expect(gz.len < src.len);
}

test "pack_demo: all five benchmark programs synthesise deterministically" {
    const a = std.testing.allocator;
    const builders = [_]*const fn (std.mem.Allocator) anyerror![]const u8{
        buildDiffuse, buildCave, buildMarble, buildDetail, buildMossy,
    };
    for (builders) |buildFn| {
        const code = try buildFn(a);
        defer a.free(code);
        var ar1 = std.heap.ArenaAllocator.init(a);
        defer ar1.deinit();
        var ar2 = std.heap.ArenaAllocator.init(a);
        defer ar2.deinit();
        var m1 = vm.Vm.init(ar1.allocator());
        var m2 = vm.Vm.init(ar2.allocator());
        const r1 = try m1.execute(code);
        const r2 = try m2.execute(code);
        try std.testing.expectEqualSlices(u8, r1, r2);
    }
}

// Regression: a single unreadable subdirectory used to abort the entire walk
// (rc -1 from the C-ABI pack functions), making the tool unusable on any real
// folder tree. collectWalk must skip the unreadable subtree and still collect
// every readable file. (Linux-only: relies on POSIX permission semantics.)
test "collectWalk: unreadable subdir is skipped, not fatal" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "aaa" });
    try tmp.dir.makePath("sub/deep");
    try tmp.dir.writeFile(.{ .sub_path = "sub/b.txt", .data = "bbb" });
    try tmp.dir.writeFile(.{ .sub_path = "sub/deep/c.txt", .data = "ccc" });
    try tmp.dir.makeDir("locked");
    try tmp.dir.writeFile(.{ .sub_path = "locked/secret.txt", .data = "xxx" });

    // Make `locked` undescendable. Restore perms before cleanup (declared after
    // the cleanup defer, so it runs first) so the temp tree can be removed.
    try std.posix.fchmodat(tmp.dir.fd, "locked", 0o000, 0);
    defer std.posix.fchmodat(tmp.dir.fd, "locked", 0o755, 0) catch {};

    const base = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(base);

    var jobs = std.ArrayList([]u8).init(a);
    defer {
        for (jobs.items) |p| a.free(p);
        jobs.deinit();
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Must complete without error despite the EACCES subtree.
    try collectWalk(a, base, "", &path_buf, &jobs, null);

    var found_a = false;
    var found_b = false;
    var found_c = false;
    for (jobs.items) |p| {
        if (std.mem.eql(u8, p, "a.txt")) found_a = true;
        if (std.mem.eql(u8, p, "sub/b.txt")) found_b = true;
        if (std.mem.eql(u8, p, "sub/deep/c.txt")) found_c = true;
    }
    try std.testing.expect(found_a and found_b and found_c);
}

// Regression: symlinks used to be silently dropped during pack, so unpacked
// trees came out smaller than the source. They must round-trip as links.
test "pack/unpack round-trips symlinks" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("srcdir");
    try tmp.dir.writeFile(.{ .sub_path = "srcdir/real.txt", .data = "hello symlink world" });
    try tmp.dir.symLink("real.txt", "srcdir/link.txt", .{});

    const base = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(base);
    const src = try std.fmt.allocPrint(a, "{s}/srcdir", .{base});
    defer a.free(src);
    const arc = try std.fmt.allocPrint(a, "{s}/out.math", .{base});
    defer a.free(arc);
    const dst = try std.fmt.allocPrint(a, "{s}/restored", .{base});
    defer a.free(dst);

    try packDirectory(a, src, arc, std.io.null_writer);
    try unpackContainer(a, arc, dst, std.io.null_writer);

    // The regular file round-trips.
    var rp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rp = try std.fmt.bufPrint(&rp_buf, "{s}/real.txt", .{dst});
    const restored = try std.fs.cwd().readFileAlloc(a, rp, 1024);
    defer a.free(restored);
    try std.testing.expectEqualStrings("hello symlink world", restored);

    // The symlink is recreated as a link pointing at the same target.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var lp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lp = try std.fmt.bufPrint(&lp_buf, "{s}/link.txt", .{dst});
    const target = try std.fs.cwd().readLink(lp, &link_buf);
    try std.testing.expectEqualStrings("real.txt", target);
}

// Full mode (real zip → math → unzip) must round-trip losslessly. Skips if the
// system `zip`/`unzip` tools aren't installed.
test "full mode: real-zip pack/unpack round-trips" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("srcdir/nested");
    try tmp.dir.writeFile(.{ .sub_path = "srcdir/a.txt", .data = "alpha contents" });
    try tmp.dir.writeFile(.{ .sub_path = "srcdir/nested/b.txt", .data = "beta contents" });

    const base = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(base);
    const arc = try std.fmt.allocPrint(a, "{s}/out.zip.math", .{base});
    defer a.free(arc);
    const dst = try std.fmt.allocPrint(a, "{s}/restored", .{base});
    defer a.free(dst);

    var cancel = std.atomic.Value(u8).init(0);
    var prog = std.atomic.Value(f32).init(0);
    var ticker: [512]u8 = undefined;
    packZipFullAbi(a, base, "srcdir", arc, 6, 1, &cancel, &prog, &ticker) catch |err| {
        if (err == error.ZipUnavailable) return error.SkipZigTest;
        return err;
    };
    unpackContainer(a, arc, dst, std.io.null_writer) catch |err| {
        if (err == error.UnzipUnavailable) return error.SkipZigTest;
        return err;
    };

    var ra: [std.fs.max_path_bytes]u8 = undefined;
    const pa = try std.fmt.bufPrint(&ra, "{s}/srcdir/a.txt", .{dst});
    const got_a = try std.fs.cwd().readFileAlloc(a, pa, 1024);
    defer a.free(got_a);
    try std.testing.expectEqualStrings("alpha contents", got_a);

    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const pb = try std.fmt.bufPrint(&rb, "{s}/srcdir/nested/b.txt", .{dst});
    const got_b = try std.fs.cwd().readFileAlloc(a, pb, 1024);
    defer a.free(got_b);
    try std.testing.expectEqualStrings("beta contents", got_b);
}

// Full mode, tar flavour (pure Zig: std.tar + streaming zstd) must round-trip
// losslessly, including symlinks and executable bits.
test "full mode: tar pack/unpack round-trips" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("srcdir/nested");
    try tmp.dir.writeFile(.{ .sub_path = "srcdir/a.txt", .data = "alpha contents" });
    try tmp.dir.writeFile(.{ .sub_path = "srcdir/nested/b.txt", .data = "beta contents" ** 200 });
    try tmp.dir.symLink("a.txt", "srcdir/link.txt", .{});
    try std.posix.fchmodat(tmp.dir.fd, "srcdir/a.txt", 0o755, 0);
    // Math-expressible files of non-square length: the pre-pass must lift
    // these out of the tar into MATH entries.
    const zeros = [_]u8{0} ** 5000;
    try tmp.dir.writeFile(.{ .sub_path = "srcdir/sparse.bin", .data = &zeros });
    var rampbuf: [3000]u8 = undefined;
    for (&rampbuf, 0..) |*p, i| p.* = 7 +% (3 *% @as(u8, @truncate(i)));
    try tmp.dir.writeFile(.{ .sub_path = "srcdir/table.bin", .data = &rampbuf });

    const base = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(base);
    const arc = try std.fmt.allocPrint(a, "{s}/out.tar.math", .{base});
    defer a.free(arc);
    const dst = try std.fmt.allocPrint(a, "{s}/restored", .{base});
    defer a.free(dst);

    var cancel = std.atomic.Value(u8).init(0);
    var prog = std.atomic.Value(f32).init(0);
    var ticker: [512]u8 = undefined;
    try packTarFullAbi(a, base, "srcdir", arc, 1, &cancel, &prog, &ticker);
    try unpackContainer(a, arc, dst, std.io.null_writer);

    var ra: [std.fs.max_path_bytes]u8 = undefined;
    const pa = try std.fmt.bufPrint(&ra, "{s}/srcdir/a.txt", .{dst});
    const got_a = try std.fs.cwd().readFileAlloc(a, pa, 1024);
    defer a.free(got_a);
    try std.testing.expectEqualStrings("alpha contents", got_a);

    // Executable bit survives (std.tar restores the owner exec bit).
    const st = try std.fs.cwd().statFile(pa);
    try std.testing.expect(st.mode & 0o100 != 0);

    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const pb = try std.fmt.bufPrint(&rb, "{s}/srcdir/nested/b.txt", .{dst});
    const got_b = try std.fs.cwd().readFileAlloc(a, pb, 1 << 20);
    defer a.free(got_b);
    try std.testing.expectEqualStrings("beta contents" ** 200, got_b);

    // The symlink is recreated as a link pointing at the same target.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var lp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lp = try std.fmt.bufPrint(&lp_buf, "{s}/srcdir/link.txt", .{dst});
    const target = try std.fs.cwd().readLink(lp, &link_buf);
    try std.testing.expectEqualStrings("a.txt", target);

    // Math-expressible files round-trip bit-perfectly via MATH entries.
    var rz: [std.fs.max_path_bytes]u8 = undefined;
    const pz = try std.fmt.bufPrint(&rz, "{s}/srcdir/sparse.bin", .{dst});
    const got_z = try std.fs.cwd().readFileAlloc(a, pz, 1 << 20);
    defer a.free(got_z);
    const zeros2 = [_]u8{0} ** 5000;
    try std.testing.expectEqualSlices(u8, &zeros2, got_z);

    var rr: [std.fs.max_path_bytes]u8 = undefined;
    const pr = try std.fmt.bufPrint(&rr, "{s}/srcdir/table.bin", .{dst});
    const got_r = try std.fs.cwd().readFileAlloc(a, pr, 1 << 20);
    defer a.free(got_r);
    var ramp2: [3000]u8 = undefined;
    for (&ramp2, 0..) |*p, i| p.* = 7 +% (3 *% @as(u8, @truncate(i)));
    try std.testing.expectEqualSlices(u8, &ramp2, got_r);

    // The FAT must contain MATH entries — proof the pre-pass lifted them.
    const arc_bytes = try std.fs.cwd().readFileAlloc(a, arc, 1 << 24);
    defer a.free(arc_bytes);
    var rdr = try container.Reader.parse(arc_bytes, a);
    defer rdr.deinit();
    var math_entries: usize = 0;
    var k: usize = 0;
    while (k < rdr.entryCount()) : (k += 1) {
        if (rdr.entryAt(k).comp_type == .math_bytecode) math_entries += 1;
    }
    try std.testing.expect(math_entries >= 2);
}

// MATH_BLOCKS: a file whose pages are part-equation, part-data decomposes into
// per-block descriptors + one compressed literal stream, and reconstructs
// bit-perfectly through the container.
test "math_blocks: mixed analytic/literal file round-trips through the container" {
    const a = std.testing.allocator;
    const math_gen = @import("math_gen.zig");
    const BS = translator.BLOCK_SIZE;

    // 4 zero blocks + 1 random block + 1 ramp block + short repeat tail.
    const total = BS * 6 + 100;
    const data = try a.alloc(u8, total);
    defer a.free(data);
    @memset(data[0 .. BS * 4], 0);
    var rng = math_gen.XorShift32.init(0xFEED);
    for (data[BS * 4 .. BS * 5]) |*p| p.* = rng.nextByte();
    for (data[BS * 5 .. BS * 6], 0..) |*p, i| p.* = 11 +% (7 *% @as(u8, @truncate(i)));
    for (data[BS * 6 ..], 0..) |*p, i| p.* = if (i % 2 == 0) @as(u8, 0xAA) else 0x55;

    var plan = (try translator.analyzeBlocks(data, a)).?;
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 7), plan.kinds.len);
    try std.testing.expect(plan.analytic_bytes >= BS * 5);

    const comp = container.Compressor.fromTier(1);
    const payload = try buildMathBlocksPayload(plan, comp, a);
    defer a.free(payload);
    // The decomposition must be far smaller than the raw data (5 of 7 blocks
    // are pure equations; only the random block survives as literals).
    try std.testing.expect(payload.len < total / 2);

    // Through the real container: append -> finish -> parse -> extract.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cb = try container.StreamingBuilder.init(a);
    defer cb.deinit();
    var fat = container.FatEntry{
        .comp_type = .math_blocks,
        .data_offset = 0,
        .original_size = total,
        .compressed_size = payload.len,
        .checksum = container.fnv1a(data),
        .codec = comp.codec,
    };
    try fat.setPath("blocky.bin");
    try cb.appendBlock(fat, payload);

    const arc_file = try tmp.dir.createFile("t.math", .{ .read = true });
    defer arc_file.close();
    try cb.finish(arc_file);
    try arc_file.seekTo(0);
    const arc = try arc_file.readToEndAlloc(a, 1 << 24);
    defer a.free(arc);

    var rdr = try container.Reader.parse(arc, a);
    defer rdr.deinit();
    const back = try rdr.extract("blocky.bin", a);
    defer a.free(back);
    try std.testing.expectEqualSlices(u8, data, back);
}

// MATH_COLUMNAR: a record-array file (here, fake 16-byte vertices) is detected,
// transposed AoS->SoA, compressed, and reconstructs bit-perfectly through the
// container — and the columnar form must be smaller than plain compression.
test "math_columnar: record-array file routes columnar and round-trips" {
    const a = std.testing.allocator;
    const math_gen = @import("math_gen.zig");
    const stride = 16;
    const recs = 6000;
    const data = try a.alloc(u8, recs * stride);
    defer a.free(data);
    // Each record: a few slowly-varying fields + one noisy field — the shape
    // where AoS->SoA wins (fields correlate across records, neighbors don't).
    var rng = math_gen.XorShift32.init(0xBEEF);
    for (0..recs) |r| {
        const base = r * stride;
        std.mem.writeInt(u32, data[base..][0..4], @intCast(r), .little);       // counter
        std.mem.writeInt(u32, data[base + 4 ..][0..4], @intCast(r * 3), .little); // counter
        std.mem.writeInt(u32, data[base + 8 ..][0..4], @intCast(1000 + r / 2), .little);
        std.mem.writeInt(u32, data[base + 12 ..][0..4], rng.next(), .little);   // noise
    }

    const effort = Effort.fromTier(1);
    const colp = (try bestColumnarBlock(data, effort, a)) orelse return error.TestUnexpectedResult;
    defer a.free(colp);
    const plain = try effort.comp.compress(data, a);
    defer a.free(plain);
    try std.testing.expect(colp.len < plain.len); // transpose genuinely helps

    // Round-trip through the container.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cb = try container.StreamingBuilder.init(a);
    defer cb.deinit();
    var fat = container.FatEntry{
        .comp_type = .math_columnar,
        .data_offset = 0,
        .original_size = data.len,
        .compressed_size = colp.len,
        .checksum = container.fnv1a(data),
        .codec = effort.comp.codec,
    };
    try fat.setPath("verts.bin");
    try cb.appendBlock(fat, colp);
    const arc_file = try tmp.dir.createFile("c.math", .{ .read = true });
    defer arc_file.close();
    try cb.finish(arc_file);
    try arc_file.seekTo(0);
    const arc = try arc_file.readToEndAlloc(a, 1 << 24);
    defer a.free(arc);
    var rdr = try container.Reader.parse(arc, a);
    defer rdr.deinit();
    const back = try rdr.extract("verts.bin", a);
    defer a.free(back);
    try std.testing.expectEqualSlices(u8, data, back);
}

// ---------------------------------------------------------------------------
// Auto-Sensing Hybrid Pack (Parallel + Solid grouping)
// ---------------------------------------------------------------------------

fn isSolidCandidate(rel_path: []const u8) bool {
    const ext = std.fs.path.extension(rel_path);
    if (ext.len == 0) return false;
    var ext_lower: [16]u8 = undefined;
    if (ext.len > 15) return false;
    for (ext, 0..) |c, i| ext_lower[i] = std.ascii.toLower(c);
    const e = ext_lower[0..ext.len];
    if (std.mem.eql(u8, e, ".lua") or
        std.mem.eql(u8, e, ".json") or
        std.mem.eql(u8, e, ".txt") or
        std.mem.eql(u8, e, ".xml") or
        std.mem.eql(u8, e, ".csv") or
        std.mem.eql(u8, e, ".ini") or
        std.mem.eql(u8, e, ".yaml") or
        std.mem.eql(u8, e, ".md"))
    {
        return true;
    }
    return false;
}

const PackCtxAuto = struct {
    alloc: std.mem.Allocator,
    base_dir: []const u8,
    scb: *container.SolidContainerBuilder,
    scb_mu: std.Thread.Mutex = .{},
    total_raw: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    file_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    print_mu: std.Thread.Mutex = .{},
    out: std.io.AnyWriter,
    cancel_flag: ?*const std.atomic.Value(u8) = null,
    progress: PackProgress = .{},
    effort: Effort = Effort.fromTier(1),
};

fn processFileAutoJob(ctx: *PackCtxAuto, rel_path: []u8) void {
    defer ctx.progress.bump();
    if (jobShouldStop(ctx.cancel_flag)) return;
    ctx.progress.setTicker(rel_path);
    packFileAutoParallel(ctx, rel_path) catch |err| {
        var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  ERROR     {s} ({s})\n",
            .{ rel_path, @errorName(err) }) catch return;
        ctx.print_mu.lock();
        defer ctx.print_mu.unlock();
        ctx.out.writeAll(line) catch {};
    };
}

/// Solid-mode job wrapper (all fallbacks bucketed into solid blocks).
fn processFileSolidJob(ctx: *PackCtxAuto, rel_path: []u8) void {
    defer ctx.progress.bump();
    if (jobShouldStop(ctx.cancel_flag)) return;
    ctx.progress.setTicker(rel_path);
    packFileSolidParallel(ctx, rel_path) catch |err| {
        std.debug.print("Failed to pack {s}: {s}\n", .{ rel_path, @errorName(err) });
    };
}

/// Run a pre-collected job list across a thread pool, driving host progress.
/// Shared by every C-ABI directory/selection pack entry point. `jobFn` selects
/// the per-file worker (auto vs solid bucketing).
fn runAutoJobsParallel(
    root: std.mem.Allocator,
    ctx: *PackCtxAuto,
    jobs: []const []u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
    comptime jobFn: fn (*PackCtxAuto, []u8) void,
) !void {
    ctx.progress = .{
        .progress_ptr = progress_ptr,
        .ticker_ptr = ticker_ptr,
        .total = @intCast(jobs.len),
        .total_bytes = sumJobBytes(ctx.base_dir, jobs),
    };

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = root, .n_jobs = null });
    defer pool.deinit();

    var wg = std.Thread.WaitGroup{};
    for (jobs) |rel_path| pool.spawnWg(&wg, jobFn, .{ ctx, rel_path });
    pool.waitAndWork(&wg);

    if (cancel_flag.load(.monotonic) == 1) return error.Cancelled;
    // Solid blocks compress during flush(), so hold at the finalize phase.
    ctx.progress.setTicker("Finalizing archive…");
}

fn packFileAutoParallel(ctx: *PackCtxAuto, rel_path: []u8) !void {
    if (rel_path.len >= container.MAX_PATH_LEN) {
        var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf,
            "  SKIP      {s} (path too long: {d} chars)\n", .{ rel_path, rel_path.len });
        ctx.print_mu.lock();
        defer ctx.print_mu.unlock();
        try ctx.out.writeAll(line);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ ctx.base_dir, rel_path });

    // Symlinks: store the target path, never follow the link.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.cwd().readLink(full_path, &link_buf)) |target| {
        {
            ctx.scb_mu.lock();
            defer ctx.scb_mu.unlock();
            try ctx.scb.inner.addSymlink(rel_path, target);
        }
        _ = ctx.file_count.fetchAdd(1, .monotonic);
        var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "  SYMLINK   {s}\n", .{rel_path});
        ctx.print_mu.lock();
        defer ctx.print_mu.unlock();
        try ctx.out.writeAll(line);
        return;
    } else |_| {}

    const file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
        var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "  SKIP      {s} ({s})\n",
            .{ rel_path, @errorName(err) });
        ctx.print_mu.lock();
        defer ctx.print_mu.unlock();
        try ctx.out.writeAll(line);
        return;
    };
    defer file.close();
    const fsize = try file.getEndPos();

    // Huge files: stream-compress directly (previously silently skipped).
    if (fsize > STREAM_THRESHOLD) {
        const d = blk: {
            ctx.scb_mu.lock();
            defer ctx.scb_mu.unlock();
            break :blk try ctx.scb.inner.addBinaryStreamingFile(rel_path, file, fsize);
        };
        _ = ctx.total_raw.fetchAdd(fsize, .monotonic);
        ctx.progress.addBytes(fsize);
        _ = ctx.file_count.fetchAdd(1, .monotonic);
        var buf: [std.fs.max_path_bytes + 96]u8 = undefined;
        const sline = try std.fmt.bufPrint(&buf, "  {s}  {s} ({d}B streamed → {d}B)\n",
            .{ if (d.guard_fired) "STORE-S " else "FALLBK-S", rel_path, fsize, d.stored_size });
        ctx.print_mu.lock();
        defer ctx.print_mu.unlock();
        try ctx.out.writeAll(sline);
        return;
    }

    const data = file.readToEndAlloc(alloc, STREAM_THRESHOLD) catch |err| {
        var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "  SKIP      {s} ({s})\n",
            .{ rel_path, @errorName(err) });
        ctx.print_mu.lock();
        defer ctx.print_mu.unlock();
        try ctx.out.writeAll(line);
        return;
    };

    const csum = container.fnv1a(data);
    const orig_size = data.len;

    const canvas = canvasForLen(data.len);
    var prog_info = translator.TranslateProgress{ .cancel_flag = ctx.cancel_flag, .max_iters = if (data.len > 16 * 1024) 0 else ctx.effort.math_iters };
    const result = translator.translate(data, canvas.w, canvas.h, alloc, &prog_info) catch translator.TranslateResult{ .fallback = .{ .reason = .high_entropy, .entropy = 100.0 } };

    var line_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
    var line: []const u8 = undefined;

    var fat = container.FatEntry{
        .comp_type = .math_bytecode,
        .data_offset = 0,
        .original_size = @intCast(orig_size),
        .compressed_size = 0,
        .checksum = csum,
        .codec = ctx.effort.comp.codec,
    };
    try fat.setPath(rel_path);

    switch (result) {
        .math_bytecode => |code| {
            fat.comp_type = .math_bytecode;
            fat.compressed_size = code.len;
            {
                ctx.scb_mu.lock();
                defer ctx.scb_mu.unlock();
                try ctx.scb.inner.appendBlock(fat, code);
            }
            line = try std.fmt.bufPrint(&line_buf,
                "  MATH      {s} ({d}B → {d}B program)\n",
                .{ rel_path, orig_size, code.len });
        },
        .approximate => |approx| {
            const gz_delta = try ctx.effort.comp.compress(approx.delta, alloc);
            const block_len = 1 + approx.bytecode.len + 8 + gz_delta.len;
            const block = try alloc.alloc(u8, block_len);
            block[0] = @intCast(approx.bytecode.len);
            @memcpy(block[1..][0..approx.bytecode.len], approx.bytecode);
            std.mem.writeInt(u64, block[1 + approx.bytecode.len ..][0..8], gz_delta.len, .little);
            @memcpy(block[1 + approx.bytecode.len + 8 ..], gz_delta);

            // Residual honesty guard: program+delta must beat compressing the
            // whole file, or the "math" is pure overhead dressed up as a win.
            const gz_whole = try ctx.effort.comp.compress(data, alloc);
            if (gz_whole.len <= block_len) {
                const wins = gz_whole.len < data.len;
                fat.comp_type = if (wins) .fallback_stream else .store;
                const payload = if (wins) gz_whole else data;
                fat.compressed_size = payload.len;
                {
                    ctx.scb_mu.lock();
                    defer ctx.scb_mu.unlock();
                    try ctx.scb.inner.appendBlock(fat, payload);
                }
                line = try std.fmt.bufPrint(&line_buf,
                    "  {s}  {s} ({d}B — residual guard fired)\n",
                    .{ if (wins) "FALLBACK" else "STORE   ", rel_path, orig_size });
            } else {
                fat.comp_type = .math_residual;
                fat.compressed_size = block_len;
                {
                    ctx.scb_mu.lock();
                    defer ctx.scb_mu.unlock();
                    try ctx.scb.inner.appendBlock(fat, block);
                }
                line = try std.fmt.bufPrint(&line_buf,
                    "  RESIDUAL  {s} ({d}B, {d}% exact)\n",
                    .{ rel_path, orig_size, approx.exact_pct });
            }
        },
        .fallback => {
            if (isSolidCandidate(rel_path)) {
                ctx.scb_mu.lock();
                defer ctx.scb_mu.unlock();
                try ctx.scb.queueBinary(rel_path, data);
                line = try std.fmt.bufPrint(&line_buf,
                    "  SOLID-Q   {s} ({d}B, deferred)\n",
                    .{ rel_path, orig_size });
            } else {
                // Cheapest reversible representation (see chooseFallbackRep):
                // STORE / plain compress / per-block math / filtered.
                const rep = try chooseFallbackRep(data, ctx.effort, alloc);
                const block = rep.payload orelse data;
                fat.comp_type = rep.comp_type;
                fat.compressed_size = block.len;
                {
                    ctx.scb_mu.lock();
                    defer ctx.scb_mu.unlock();
                    try ctx.scb.inner.appendBlock(fat, block);
                }
                line = try std.fmt.bufPrint(&line_buf,
                    "  {s}  {s} ({d}B → {d}B, {d:.1}x)\n",
                    .{ fallbackLabel(rep.comp_type), rel_path, orig_size, block.len,
                       @as(f64, @floatFromInt(orig_size)) / @as(f64, @floatFromInt(@max(1, block.len))) });
            }
        },
    }

    _ = ctx.total_raw.fetchAdd(@intCast(orig_size), .monotonic);
    ctx.progress.addBytes(@intCast(orig_size));
    _ = ctx.file_count.fetchAdd(1, .monotonic);

    ctx.print_mu.lock();
    defer ctx.print_mu.unlock();
    try ctx.out.writeAll(line);
}

fn packDirectoryAuto(
    root: std.mem.Allocator,
    dir_path: []const u8,
    out_path: []const u8,
    out: anytype,
) !void {
    try out.print("Mode: Auto-Sensing Hybrid (parallel streaming + solid groupings)\n", .{});

    var jobs = std.ArrayList([]u8).init(root);
    defer {
        for (jobs.items) |p| root.free(p);
        jobs.deinit();
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try collectWalk(root, dir_path, "", &path_buf, &jobs, null);

    var scb = try container.SolidContainerBuilder.init(root);
    scb.setCompressor(Effort.fromTier(1).comp); // CLI defaults to balanced
    defer scb.deinit();

    var ctx = PackCtxAuto{
        .alloc = root,
        .base_dir = dir_path,
        .scb = &scb,
        .out = out.any(),
    };

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = root, .n_jobs = null });
    defer pool.deinit();

    var wg = std.Thread.WaitGroup{};
    for (jobs.items) |rel_path| {
        pool.spawnWg(&wg, processFileAutoJob, .{ &ctx, rel_path });
    }
    pool.waitAndWork(&wg);

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try scb.flush(out_file);

    const fat_overhead = container.HEADER_SIZE + container.FAT_ENTRY_SIZE * scb.entryCount();
    const container_size = fat_overhead + scb.dataBytes();
    const total_raw = ctx.total_raw.load(.monotonic);
    const file_count = ctx.file_count.load(.monotonic);

    const ratio = if (container_size > 0)
        @as(f64, @floatFromInt(total_raw)) / @as(f64, @floatFromInt(container_size))
    else
        0.0;

    try out.print("\n  Files packed   : {d}\n", .{file_count});
    try out.print("  Raw total      : {d:.1} MB\n",
        .{@as(f64, @floatFromInt(total_raw)) / (1024.0 * 1024.0)});
    try out.print("  Container size : {d:.1} MB\n",
        .{@as(f64, @floatFromInt(container_size)) / (1024.0 * 1024.0)});
    try out.print("  Ratio          : {d:.2}x\n", .{ratio});
    try out.print("Wrote {s}\n", .{out_path});
}

// ---------------------------------------------------------------------------
// VFS-mode C-ABI pack: individual per-file routing, no solid grouping.
// ---------------------------------------------------------------------------

pub fn packDirectoryVfsAbi(
    root: std.mem.Allocator,
    dir_path: []const u8,
    out_path: []const u8,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) !void {
    const effort = Effort.fromTier(effort_tier);
    var cb = try container.StreamingBuilder.init(root);
    cb.comp = effort.comp;
    defer cb.deinit();

    var jobs = std.ArrayList([]u8).init(root);
    defer {
        for (jobs.items) |p| root.free(p);
        jobs.deinit();
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try collectWalk(root, dir_path, "", &path_buf, &jobs, cancel_flag);
    removeOutputJob(&jobs, root, dir_path, out_path);

    var ctx = PackCtx{
        .alloc    = root,
        .base_dir = dir_path,
        .cb       = &cb,
        .out      = std.io.getStdOut().writer().any(),
        .cancel_flag = cancel_flag,
        .effort   = effort,
    };

    // Parallel across all cores (libc is linked, so pthread-backed thread
    // spawning works inside the dlopened .so). Per-file workers serialise only
    // the cheap tmp-file append; compression runs lock-free.
    try runStreamJobsParallel(root, &ctx, jobs.items, cancel_flag, progress_ptr, ticker_ptr);

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try cb.finish(out_file);
}

// ---------------------------------------------------------------------------
// Solid-mode C-ABI pack: all files bucketed into solid gzip blocks.
// ---------------------------------------------------------------------------

pub fn packDirectorySolidAbi(
    root: std.mem.Allocator,
    dir_path: []const u8,
    out_path: []const u8,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) !void {
    const effort = Effort.fromTier(effort_tier);
    var scb = try container.SolidContainerBuilder.init(root);
    scb.setCompressor(effort.comp);
    defer scb.deinit();

    var jobs = std.ArrayList([]u8).init(root);
    defer {
        for (jobs.items) |p| root.free(p);
        jobs.deinit();
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try collectWalk(root, dir_path, "", &path_buf, &jobs, cancel_flag);
    removeOutputJob(&jobs, root, dir_path, out_path);

    var ctx = PackCtxAuto{
        .alloc    = root,
        .base_dir = dir_path,
        .scb      = &scb,
        .out      = std.io.getStdOut().writer().any(),
        .cancel_flag = cancel_flag,
        .effort   = effort,
    };

    try runAutoJobsParallel(root, &ctx, jobs.items, cancel_flag, progress_ptr, ticker_ptr, processFileSolidJob);

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try scb.flush(out_file);
}

fn packFileSolidParallel(ctx: *PackCtxAuto, rel_path: []u8) !void {
    if (rel_path.len >= container.MAX_PATH_LEN) return;

    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ ctx.base_dir, rel_path });

    // Symlinks: store the target path, never follow the link.
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.cwd().readLink(full_path, &link_buf)) |target| {
        ctx.scb_mu.lock();
        defer ctx.scb_mu.unlock();
        try ctx.scb.inner.addSymlink(rel_path, target);
        return;
    } else |_| {}

    const file = std.fs.cwd().openFile(full_path, .{}) catch return;
    defer file.close();
    const fsize = try file.getEndPos();

    // Huge files: stream-compress directly (previously silently skipped).
    if (fsize > STREAM_THRESHOLD) {
        ctx.scb_mu.lock();
        defer ctx.scb_mu.unlock();
        _ = try ctx.scb.inner.addBinaryStreamingFile(rel_path, file, fsize);
        _ = ctx.total_raw.fetchAdd(fsize, .monotonic);
        ctx.progress.addBytes(fsize);
        return;
    }

    const data = file.readToEndAlloc(alloc, STREAM_THRESHOLD) catch return;

    const orig_size = data.len;

    // Math translation runs outside the lock.
    const canvas = canvasForLen(data.len);
    var prog_info = translator.TranslateProgress{ .cancel_flag = ctx.cancel_flag, .max_iters = if (data.len > 16 * 1024) 0 else ctx.effort.math_iters };
    const result = translator.translate(data, canvas.w, canvas.h, alloc, &prog_info) catch
        translator.TranslateResult{ .fallback = .{ .reason = .high_entropy, .entropy = 100.0 } };

    var fat = container.FatEntry{
        .comp_type      = .math_bytecode,
        .data_offset    = 0,
        .original_size  = @intCast(orig_size),
        .compressed_size = 0,
        .checksum       = container.fnv1a(data),
        .codec          = ctx.effort.comp.codec,
    };
    try fat.setPath(rel_path);

    switch (result) {
        .math_bytecode => |code| {
            fat.comp_type        = .math_bytecode;
            fat.compressed_size  = code.len;
            ctx.scb_mu.lock();
            defer ctx.scb_mu.unlock();
            try ctx.scb.inner.appendBlock(fat, code);
        },
        .approximate => |approx| {
            const gz_delta  = try ctx.effort.comp.compress(approx.delta, alloc);
            const block_len = 1 + approx.bytecode.len + 8 + gz_delta.len;
            const block     = try alloc.alloc(u8, block_len);
            block[0] = @intCast(approx.bytecode.len);
            @memcpy(block[1..][0..approx.bytecode.len], approx.bytecode);
            std.mem.writeInt(u64, block[1 + approx.bytecode.len ..][0..8], gz_delta.len, .little);
            @memcpy(block[1 + approx.bytecode.len + 8 ..], gz_delta);
            // Residual honesty guard: program+delta must beat compressing the
            // whole file, or the "math" is pure overhead dressed up as a win.
            const gz_whole = try ctx.effort.comp.compress(data, alloc);
            if (gz_whole.len <= block_len) {
                const wins = gz_whole.len < data.len;
                fat.comp_type = if (wins) .fallback_stream else .store;
                const payload = if (wins) gz_whole else data;
                fat.compressed_size = payload.len;
                ctx.scb_mu.lock();
                defer ctx.scb_mu.unlock();
                try ctx.scb.inner.appendBlock(fat, payload);
            } else {
                fat.comp_type        = .math_residual;
                fat.compressed_size  = block_len;
                ctx.scb_mu.lock();
                defer ctx.scb_mu.unlock();
                try ctx.scb.inner.appendBlock(fat, block);
            }
        },
        .fallback => {
            // Solid mode: always queue into a solid block by extension.
            ctx.scb_mu.lock();
            defer ctx.scb_mu.unlock();
            try ctx.scb.queueBinary(rel_path, data);
        },
    }
    _ = ctx.total_raw.fetchAdd(@intCast(orig_size), .monotonic);
    ctx.progress.addBytes(@intCast(orig_size));
}

pub fn packDirectoryAutoAbi(
    root: std.mem.Allocator,
    dir_path: []const u8,
    out_path: []const u8,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) !void {
    const effort = Effort.fromTier(effort_tier);
    var cb = try container.SolidContainerBuilder.init(root);
    cb.setCompressor(effort.comp);
    defer cb.deinit();

    var jobs = std.ArrayList([]u8).init(root);
    defer {
        for (jobs.items) |p| root.free(p);
        jobs.deinit();
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try collectWalk(root, dir_path, "", &path_buf, &jobs, cancel_flag);
    removeOutputJob(&jobs, root, dir_path, out_path);

    var ctx = PackCtxAuto{
        .alloc = root,
        .base_dir = dir_path,
        .scb = &cb,
        .out = std.io.getStdOut().writer().any(),
        .cancel_flag = cancel_flag,
        .effort = effort,
    };

    try runAutoJobsParallel(root, &ctx, jobs.items, cancel_flag, progress_ptr, ticker_ptr, processFileAutoJob);

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try cb.flush(out_file);
}

// Pack an explicit selection (files and/or directories) into one archive.
// `selection` is a newline-separated list of paths relative to `base_dir`:
// directories are walked recursively, files are added directly. Backs the GUI's
// "Pack Selected" and also packing a single right-clicked file (the directory
// pack functions can't pack a lone file).
pub fn packSelectionAbi(
    root: std.mem.Allocator,
    base_dir: []const u8,
    selection: []const u8,
    out_path: []const u8,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) !void {
    const effort = Effort.fromTier(effort_tier);
    var cb = try container.SolidContainerBuilder.init(root);
    cb.setCompressor(effort.comp);
    defer cb.deinit();

    var jobs = std.ArrayList([]u8).init(root);
    defer {
        for (jobs.items) |p| root.free(p);
        jobs.deinit();
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, selection, '\n');
    while (it.next()) |raw| {
        while (cancel_flag.load(.monotonic) == 2) { std.time.sleep(100 * std.time.ns_per_ms); }
        if (cancel_flag.load(.monotonic) == 1) return error.Cancelled;
        const sel = std.mem.trim(u8, raw, " \r\t");
        if (sel.len == 0) continue;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, sel }) catch continue;
        const st = std.fs.cwd().statFile(full) catch continue;
        switch (st.kind) {
            .directory => try collectWalk(root, base_dir, sel, &path_buf, &jobs, cancel_flag),
            .file => try jobs.append(try root.dupe(u8, sel)),
            else => {},
        }
    }
    removeOutputJob(&jobs, root, base_dir, out_path);

    var ctx = PackCtxAuto{
        .alloc = root,
        .base_dir = base_dir,
        .scb = &cb,
        .out = std.io.getStdOut().writer().any(),
        .cancel_flag = cancel_flag,
        .effort = effort,
    };

    try runAutoJobsParallel(root, &ctx, jobs.items, cancel_flag, progress_ptr, ticker_ptr, processFileAutoJob);

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try cb.flush(out_file);
}

// Solid variant of packSelectionAbi: every fallback/store file is bucketed into
// shared solid gzip blocks by extension instead of being compressed per-file.
// Backs the GUI's "Solid archive" checkbox so it produces a real .math archive
// (the old GUI path shelled out to `zip` and round-tripped to a .zip entry).
pub fn packSelectionSolidAbi(
    root: std.mem.Allocator,
    base_dir: []const u8,
    selection: []const u8,
    out_path: []const u8,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) !void {
    const effort = Effort.fromTier(effort_tier);
    var cb = try container.SolidContainerBuilder.init(root);
    cb.setCompressor(effort.comp);
    defer cb.deinit();

    var jobs = std.ArrayList([]u8).init(root);
    defer {
        for (jobs.items) |p| root.free(p);
        jobs.deinit();
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, selection, '\n');
    while (it.next()) |raw| {
        while (cancel_flag.load(.monotonic) == 2) { std.time.sleep(100 * std.time.ns_per_ms); }
        if (cancel_flag.load(.monotonic) == 1) return error.Cancelled;
        const sel = std.mem.trim(u8, raw, " \r\t");
        if (sel.len == 0) continue;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, sel }) catch continue;
        const st = std.fs.cwd().statFile(full) catch continue;
        switch (st.kind) {
            .directory => try collectWalk(root, base_dir, sel, &path_buf, &jobs, cancel_flag),
            .file => try jobs.append(try root.dupe(u8, sel)),
            else => {},
        }
    }
    removeOutputJob(&jobs, root, base_dir, out_path);

    var ctx = PackCtxAuto{
        .alloc = root,
        .base_dir = base_dir,
        .scb = &cb,
        .out = std.io.getStdOut().writer().any(),
        .cancel_flag = cancel_flag,
        .effort = effort,
    };

    try runAutoJobsParallel(root, &ctx, jobs.items, cancel_flag, progress_ptr, ticker_ptr, processFileSolidJob);

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try cb.flush(out_file);
}

fn setTickerRaw(ticker_ptr: [*]u8, msg: []const u8) void {
    @memset(ticker_ptr[0..512], 0);
    const n = @min(511, msg.len);
    @memcpy(ticker_ptr[0..n], msg[0..n]);
}

/// Full mode: real ZIP first, then mathpressor wraps the zip.
///   1. Shell out to system `zip` to build a real .zip of the selection at the
///      requested level (1..9).
///   2. Wrap that zip in a .math container (the STORE guard keeps the already-
///      compressed zip verbatim) and stamp FLAG_FULL_ZIP in the header.
/// Unpack (see unpackContainer) detects the flag and expands the inner zip
/// back into the original files via `unzip`, so the round-trip is lossless.
pub fn packZipFullAbi(
    root: std.mem.Allocator,
    base_dir: []const u8,
    selection: []const u8,
    out_path: []const u8,
    zip_level: u8,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) !void {
    if (cancel_flag.load(.monotonic) == 1) return error.Cancelled;

    // Temp zip path (cleaned up no matter how we exit).
    var tmp_buf: [128]u8 = undefined;
    const tmp_zip = try std.fmt.bufPrint(&tmp_buf, "/tmp/mathpressor_full_{d}.zip", .{std.time.milliTimestamp()});
    defer std.fs.cwd().deleteFile(tmp_zip) catch {};

    // Build argv: zip -r -q -<level> <tmp_zip> name1 name2 ...
    var argv = std.ArrayList([]const u8).init(root);
    defer argv.deinit();
    var level_buf: [4]u8 = undefined;
    const level = std.math.clamp(zip_level, 1, 9);
    const level_arg = try std.fmt.bufPrint(&level_buf, "-{d}", .{level});
    // -y preserves symlinks as links (default zip follows them, which would
    // turn a symlink into a copy of its target and break the round-trip).
    try argv.appendSlice(&.{ "zip", "-r", "-y", "-q", level_arg, tmp_zip });
    var names: usize = 0;
    var it = std.mem.tokenizeScalar(u8, selection, '\n');
    while (it.next()) |raw| {
        const sel = std.mem.trim(u8, raw, " \r\t");
        if (sel.len == 0) continue;
        try argv.append(sel);
        names += 1;
    }
    if (names == 0) return error.NoOutput;

    setTickerRaw(ticker_ptr, "Creating real .zip…");
    progress_ptr.store(0.05, .monotonic);

    var child = std.process.Child.init(argv.items, root);
    child.cwd = base_dir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        std.debug.print("full mode: could not launch `zip` ({s}) — is it installed?\n", .{@errorName(err)});
        return error.ZipUnavailable;
    };
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("full mode: `zip` exited with code {d}\n", .{code});
            return error.ZipFailed;
        },
        else => return error.ZipFailed,
    }

    if (cancel_flag.load(.monotonic) == 1) return error.Cancelled;
    progress_ptr.store(0.6, .monotonic);
    setTickerRaw(ticker_ptr, "Mathpressing the zip…");

    // Wrap the zip into a .math container, flagged as full mode. The outer
    // mathpressor pass (gzip-over-the-zip) uses the mathpressor effort tier.
    var cb = try container.StreamingBuilder.init(root);
    cb.flags = container.FLAG_FULL_ZIP;
    cb.comp = Effort.fromTier(effort_tier).comp;
    defer cb.deinit();

    const zf = try std.fs.cwd().openFile(tmp_zip, .{});
    defer zf.close();
    const zsize = try zf.getEndPos();
    _ = try cb.addBinaryStreamingFile("archive.zip", zf, zsize);

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try cb.finish(out_file);

    progress_ptr.store(1.0, .monotonic);
}

/// Full mode, tar flavour: solid tar first, then mathpressor compresses the tar.
///   1. Build an uncompressed .tar of the selection with std.tar.writer —
///      one solid stream, so the compressor shares its dictionary across every
///      file boundary (the reason tar+zstd beats per-file archivers on trees
///      of many similar files).
///   2. Stream the tar through the container's zstd codec at the effort tier
///      and stamp FLAG_FULL_TAR.
/// Unlike the zip flavour this is pure Zig end to end: no system `zip` at pack
/// time, no `unzip` at unpack time (std.tar.pipeToFileSystem expands it).
pub fn packTarFullAbi(
    root: std.mem.Allocator,
    base_dir: []const u8,
    selection: []const u8,
    out_path: []const u8,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) !void {
    if (cancel_flag.load(.monotonic) == 1) return error.Cancelled;

    // Collect the file list (dirs walked recursively, lone files added as-is).
    var jobs = std.ArrayList([]u8).init(root);
    defer {
        for (jobs.items) |p| root.free(p);
        jobs.deinit();
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, selection, '\n');
    while (it.next()) |raw| {
        if (jobShouldStop(cancel_flag)) return error.Cancelled;
        const sel = std.mem.trim(u8, raw, " \r\t");
        if (sel.len == 0) continue;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, sel }) catch continue;
        const st = std.fs.cwd().statFile(full) catch continue;
        switch (st.kind) {
            .directory => try collectWalk(root, base_dir, sel, &path_buf, &jobs, cancel_flag),
            .file => try jobs.append(try root.dupe(u8, sel)),
            else => {},
        }
    }
    if (jobs.items.len == 0) return error.NoOutput;
    removeOutputJob(&jobs, root, base_dir, out_path);

    // Order the tar by (extension, path) so similar files sit adjacent in the
    // solid stream — the compressor's window then sees runs of like content
    // (all .so together, all .json together), which is worth real percent on
    // mixed trees. Same trick 7-Zip uses for its solid archives.
    std.mem.sort([]u8, jobs.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return switch (std.mem.order(u8, std.fs.path.extension(a), std.fs.path.extension(b))) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, a, b) == .lt,
            };
        }
    }.lt);

    const total_bytes = sumJobBytes(base_dir, jobs.items);

    // -----------------------------------------------------------------------
    // Phase 0 — parallel math pre-pass. Two kinds of file leave the tar and
    // ride as their own container entries; the solid zstd stream carries the
    // rest. This is what makes full mode "mathpressor + traditional
    // compression" rather than tar+zstd in a coat:
    //
    //   (a) MATH_BYTECODE — a file the translator expresses as a bit-perfect
    //       program (zeroed/sparse, ramps, tiles): kilobytes → a few bytes.
    //   (b) MATH_FILTERED — an executable whose x86 call/jump targets the BCJ
    //       filter rewrites so the LZ stage matches them. A 46 MB .so drops
    //       ~5% vs plain zstd; pulling it out costs only the negligible
    //       cross-file dictionary sharing a unique binary never had anyway.
    //
    // Everything else stays in the solid tar, where cross-file context helps.
    // -----------------------------------------------------------------------
    const effort = Effort.fromTier(effort_tier);
    // Full mode runs the LZMA/xz backend (stronger model than zstd). Lifted
    // executables ride this too — the files where the extra effort is most
    // worth it.
    const lift_comp = container.Compressor.lzmaFromTier(effort_tier);

    const Lifted = struct {
        comp_type: container.CompressionType,
        payload: []u8, // bytecode (math) or [filter_id][compressed] (filtered)
        size: u64,
        csum: u32,
    };
    const hits = try root.alloc(?Lifted, jobs.items.len);
    defer {
        for (hits) |h| if (h) |hh| root.free(hh.payload);
        root.free(hits);
    }
    @memset(hits, null);

    setTickerRaw(ticker_ptr, "Math pre-pass (programs + executable filters)…");
    {
        const Worker = struct {
            fn run(
                alloc: std.mem.Allocator,
                base: []const u8,
                rel: []const u8,
                slot: *?Lifted,
                eff: Effort,
                cancel: ?*const std.atomic.Value(u8),
            ) void {
                if (jobShouldStop(cancel)) return;
                var pbuf: [std.fs.max_path_bytes]u8 = undefined;
                const full = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ base, rel }) catch return;
                // Symlinks stay in the tar (it preserves them as links).
                var lbuf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fs.cwd().readLink(full, &lbuf)) |_| {
                    return;
                } else |_| {}
                const f = std.fs.cwd().openFile(full, .{}) catch return;
                defer f.close();
                const size = f.getEndPos() catch return;
                if (size == 0) return;

                var arena = std.heap.ArenaAllocator.init(alloc);
                defer arena.deinit();
                const aa = arena.allocator();
                const data = f.readToEndAlloc(aa, @intCast(size)) catch return;
                const csum = container.fnv1a(data);

                // (a) Whole-file math program (only for canvas-sized inputs).
                if (size <= @as(u64, vm.MAX_DIM) * vm.MAX_DIM and size >= 64) {
                    const canvas = canvasForLen(data.len);
                    // Noise search can only match small procedural textures; cap
                    // budget to 0 above 256KB so it never grinds large files.
                    const iters: u32 = if (data.len > 16 * 1024) 0 else eff.math_iters;
                    var pi = translator.TranslateProgress{ .cancel_flag = cancel, .max_iters = iters };
                    if (translator.translate(data, canvas.w, canvas.h, aa, &pi)) |res| {
                        switch (res) {
                            .math_bytecode => |code| {
                                if (code.len < size) {
                                    const owned = alloc.dupe(u8, code) catch return;
                                    slot.* = .{ .comp_type = .math_bytecode, .payload = owned, .size = size, .csum = csum };
                                    return;
                                }
                            },
                            else => {},
                        }
                    } else |_| {}
                }
                // Executables are NOT lifted here: the whole tar is compressed
                // through liblzma's x86 BCJ filter chain (xz-grade, with solid
                // cross-file sharing), which beats per-file hand-rolled BCJ.
            }
        };
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{ .allocator = root, .n_jobs = null });
        defer pool.deinit();
        var wg = std.Thread.WaitGroup{};
        for (jobs.items, 0..) |rel, i| {
            pool.spawnWg(&wg, Worker.run, .{
                root, base_dir, rel, &hits[i], effort,
                @as(?*const std.atomic.Value(u8), cancel_flag),
            });
        }
        pool.waitAndWork(&wg);
    }
    if (cancel_flag.load(.monotonic) == 1) return error.Cancelled;

    // Phase 1 — write the solid tar to a temp file (cleaned up on every exit).
    var tmp_buf: [128]u8 = undefined;
    const tmp_tar = try std.fmt.bufPrint(&tmp_buf, "/tmp/mathpressor_full_{d}.tar", .{std.time.milliTimestamp()});
    defer std.fs.cwd().deleteFile(tmp_tar) catch {};
    {
        const tar_file = try std.fs.cwd().createFile(tmp_tar, .{});
        defer tar_file.close();
        var bw = std.io.bufferedWriter(tar_file.writer());
        var tw = std.tar.writer(bw.writer());

        var done_bytes: u64 = 0;
        for (jobs.items, 0..) |rel_path, ji| {
            if (jobShouldStop(cancel_flag)) return error.Cancelled;
            // Files the math pre-pass captured ride as MATH entries instead.
            if (hits[ji] != null) continue;
            setTickerRaw(ticker_ptr, rel_path);

            const full = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, rel_path });

            // Symlinks: store the target path, never follow the link.
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fs.cwd().readLink(full, &link_buf)) |target| {
                try tw.writeLink(rel_path, target, .{});
                continue;
            } else |_| {}

            const file = std.fs.cwd().openFile(full, .{}) catch continue;
            defer file.close();
            const st = try file.stat();
            var br = std.io.bufferedReader(file.reader());
            // Preserve mode (executable bits survive the round-trip) and mtime.
            try tw.writeFileStream(rel_path, @intCast(st.size), br.reader(), .{
                .mode = @intCast(st.mode & 0o7777),
                .mtime = @intCast(@max(0, @divFloor(st.mtime, std.time.ns_per_s))),
            });

            done_bytes += st.size;
            if (total_bytes > 0) {
                const f: f32 = @as(f32, @floatFromInt(done_bytes)) / @as(f32, @floatFromInt(total_bytes));
                progress_ptr.store(0.5 * @min(f, 1.0), .monotonic);
            }
        }
        try tw.finish();
        try bw.flush();
    }

    if (cancel_flag.load(.monotonic) == 1) return error.Cancelled;
    progress_ptr.store(0.55, .monotonic);
    setTickerRaw(ticker_ptr, "Mathpressing the tar (solid LZMA/xz)…");

    // Phase 2 — compress the tar through the LZMA/xz backend.
    var cb = try container.StreamingBuilder.init(root);
    cb.flags = container.FLAG_FULL_TAR;
    cb.comp = container.Compressor.lzmaFromTier(effort_tier);
    defer cb.deinit();

    // Lifted entries first (tiny programs + filtered executables), then the
    // wrapped solid tar.
    for (jobs.items, 0..) |rel, ji| {
        const hit = hits[ji] orelse continue;
        switch (hit.comp_type) {
            .math_bytecode => try cb.addMath(rel, hit.payload, hit.size, hit.csum),
            .math_filtered => {
                var fat = container.FatEntry{
                    .comp_type = .math_filtered,
                    .data_offset = 0,
                    .original_size = hit.size,
                    .compressed_size = hit.payload.len,
                    .checksum = hit.csum,
                    .codec = lift_comp.codec,
                };
                try fat.setPath(rel);
                try cb.appendBlock(fat, hit.payload);
            },
            else => unreachable,
        }
    }

    const tf = try std.fs.cwd().openFile(tmp_tar, .{});
    defer tf.close();
    const tsize = try tf.getEndPos();

    // LZMA is one-shot (whole tar in RAM). Full-mode unpack already loads the
    // whole tar in memory, so this matches the existing profile — but cap it so
    // an enormous selection can't blow up RAM; above the cap, fall back to the
    // streaming zstd path (its FAT codec byte records zstd, so decode is correct).
    const LZMA_TAR_CAP: u64 = 3 * 1024 * 1024 * 1024;
    if (tsize <= LZMA_TAR_CAP) {
        const tar_data = try tf.readToEndAlloc(root, @intCast(tsize));
        defer root.free(tar_data);
        const csum = container.fnv1a(tar_data);
        const preset = container.lzmaPreset(effort_tier);

        // The x86 BCJ chain (xz --x86 grade) wins on code-heavy data but can
        // LOSE to plain LZMA on data-heavy content (false E8/E9 conversions).
        // At Max, compress both ways in parallel and keep the smaller — this
        // guarantees full mode never loses to either `xz -9e` or `-9e --x86`.
        // Both are codec=lzma and the .xz header self-describes the filter, so
        // decode is identical either way.
        const Job = struct {
            data: []const u8,
            preset: u32,
            alloc: std.mem.Allocator,
            out: ?[]u8 = null,
            fn runPlain(self: *@This()) void {
                self.out = container.lzmaCompress(self.data, self.alloc, self.preset) catch null;
            }
        };
        var plain_job = Job{ .data = tar_data, .preset = preset, .alloc = root };
        const plain_thread: ?std.Thread = if (effort_tier == 2)
            (std.Thread.spawn(.{}, Job.runPlain, .{&plain_job}) catch null)
        else
            null;

        var comp = try container.lzmaCompressX86(tar_data, root, preset);
        if (plain_thread) |th| {
            th.join();
            if (plain_job.out) |plain| {
                if (plain.len < comp.len) {
                    root.free(comp);
                    comp = plain;
                } else root.free(plain);
            }
        }
        defer root.free(comp);
        // STORE guard: never let the wrapper inflate the tar.
        if (comp.len < tar_data.len) {
            var fat = container.FatEntry{
                .comp_type = .fallback_stream,
                .data_offset = 0,
                .original_size = tsize,
                .compressed_size = comp.len,
                .checksum = csum,
                .codec = .lzma,
            };
            try fat.setPath("archive.tar");
            try cb.appendBlock(fat, comp);
        } else {
            var fat = container.FatEntry{
                .comp_type = .store,
                .data_offset = 0,
                .original_size = tsize,
                .compressed_size = tsize,
                .checksum = csum,
                .codec = .lzma,
            };
            try fat.setPath("archive.tar");
            try cb.appendBlock(fat, tar_data);
        }
    } else {
        _ = try cb.addZstdStreamingFile("archive.tar", tf, tsize);
    }

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try cb.finish(out_file);

    progress_ptr.store(1.0, .monotonic);
}

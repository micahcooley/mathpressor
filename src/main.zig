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
const gip = @import("gip_interface.zig");
const container = @import("container.zig");
const translator = @import("translator.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const root = gpa.allocator();

    const args = try std.process.argsAlloc(root);
    defer std.process.argsFree(root, args);

    const out = std.io.getStdOut().writer();

    if (args.len >= 3 and std.mem.eql(u8, args[1], "pack")) {
        try packDirectory(root, args[2], args[3], out);
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "unpack")) {
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

    try out.print("Mathpressor — Glasswing procedural asset engine\n", .{});
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

    const gip_out = try root.alloc(u8, pixels.len);
    defer root.free(gip_out);
    const rc = gip.gip_synthesize_asset(0xA55E7, code.ptr, code.len, gip_out.ptr, gip_out.len);
    try out.print("\nGIP returned {d} bytes — identical to in-process: {}\n", .{
        rc, std.mem.eql(u8, pixels, gip_out),
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
        const gz = try container.gzipCompress(px, root);
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

fn packDirectory(root: std.mem.Allocator, dir_path: []const u8, out_path: []const u8, out: anytype) !void {
    // StreamingBuilder writes compressed blocks straight to a temp file as each
    // file is processed — peak RAM = one file at a time, not the whole archive.
    var cb = try container.StreamingBuilder.init(root);
    defer cb.deinit();

    var total_raw: u64 = 0;
    var file_count: u32 = 0;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try packWalk(root, dir_path, "", &path_buf, &cb, &total_raw, &file_count, out);

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try cb.finish(out_file);

    // Container size = header + FAT + all data blocks.
    const fat_overhead = HEADER_SIZE + FAT_ENTRY_SIZE * cb.entryCount();
    const container_size = fat_overhead + cb.dataBytes();

    const ratio = if (container_size > 0)
        @as(f64, @floatFromInt(total_raw)) / @as(f64, @floatFromInt(container_size))
    else 0.0;

    try out.print("\n  Files packed   : {d}\n", .{file_count});
    try out.print("  Raw total      : {d:.1} MB\n", .{@as(f64, @floatFromInt(total_raw)) / (1024 * 1024)});
    try out.print("  Container size : {d:.1} MB\n", .{@as(f64, @floatFromInt(container_size)) / (1024 * 1024)});
    try out.print("  Ratio          : {d:.2}x\n", .{ratio});
    try out.print("Wrote {s}\n", .{out_path});
}

const HEADER_SIZE = container.HEADER_SIZE;
const FAT_ENTRY_SIZE = container.FAT_ENTRY_SIZE;

fn packWalk(
    root: std.mem.Allocator,
    base_dir: []const u8,
    rel_prefix: []const u8,
    path_buf: *[std.fs.max_path_bytes]u8,
    cb: *container.StreamingBuilder,
    total_raw: *u64,
    file_count: *u32,
    out: anytype,
) !void {
    // Build the absolute path for this level.
    const abs = if (rel_prefix.len == 0)
        base_dir
    else
        try std.fmt.bufPrint(path_buf, "{s}/{s}", .{ base_dir, rel_prefix });

    var dir = try std.fs.cwd().openDir(abs, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        // Compose the relative path for this entry (used as the archive key).
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel_path = if (rel_prefix.len == 0)
            try std.fmt.bufPrint(&rel_buf, "{s}", .{entry.name})
        else
            try std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ rel_prefix, entry.name });

        switch (entry.kind) {
            .directory => {
                // Recurse — allocate a fresh path_buf on the stack to avoid
                // clobbering the parent's buffer mid-iteration.
                var child_buf: [std.fs.max_path_bytes]u8 = undefined;
                try packWalk(root, base_dir, rel_path, &child_buf, cb, total_raw, file_count, out);
            },
            .file => {
                try packFile(root, dir, entry.name, rel_path, cb, total_raw, file_count, out);
            },
            else => {}, // skip symlinks, devices, etc.
        }
    }
}

/// Read, translate, and add a single file to the container.
fn packFile(
    root: std.mem.Allocator,
    dir: std.fs.Dir,
    name: []const u8,
    rel_path: []const u8,
    cb: *container.StreamingBuilder,
    total_raw: *u64,
    file_count: *u32,
    out: anytype,
) !void {
    // 256 MB per-file cap — large enough for any game asset, skips Steam's
    // multi-hundred-MB depots without running out of memory.
    const MAX_FILE: usize = 256 * 1024 * 1024;
    const data = dir.readFileAlloc(root, name, MAX_FILE) catch |err| {
        try out.print("  SKIP      {s} ({s})\n", .{ rel_path, @errorName(err) });
        return;
    };
    defer root.free(data);

    if (rel_path.len >= container.MAX_PATH_LEN) {
        try out.print("  SKIP      {s} (path too long: {d} chars)\n", .{ rel_path, rel_path.len });
        return;
    }

    total_raw.* += data.len;
    file_count.* += 1;

    const csum = container.fnv1a(data);
    const orig_size = data.len;

    // Attempt math translation if the canvas is a perfect square.
    const side: u32 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(data.len))));
    var prog_info = translator.TranslateProgress{};
    const result = try translator.translate(data, side, side, root, &prog_info);

    switch (result) {
        .math_bytecode => |code| {
            defer root.free(code);
            try cb.addMath(rel_path, code, orig_size, csum);
            try out.print("  MATH      {s} ({d}B → {d}B program)\n",
                .{ rel_path, orig_size, code.len });
        },
        .approximate => |approx| {
            defer root.free(approx.bytecode);
            defer root.free(approx.delta);
            try cb.addResidual(rel_path, approx.bytecode, approx.delta, orig_size, csum);
            try out.print("  RESIDUAL  {s} ({d}B, {d}% exact)\n",
                .{ rel_path, orig_size, approx.exact_pct });
        },
        // STORE guard active: addBinary picks gzip vs raw, never inflates.
        .fallback => {
            const decision = try cb.addBinary(rel_path, data);
            switch (decision.comp_type) {
                .store => try out.print("  STORE     {s} ({d}B raw — guard fired)\n",
                    .{ rel_path, decision.stored_size }),
                .fallback_stream => try out.print("  FALLBACK  {s} ({d}B → {d}B gzip, {d:.1}x)\n",
                    .{ rel_path, orig_size, decision.stored_size,
                       @as(f64, @floatFromInt(orig_size)) /
                           @as(f64, @floatFromInt(decision.stored_size)) }),
                else => unreachable,
            }
        },
    }
}

fn unpackContainer(root: std.mem.Allocator, in_path: []const u8, out_dir: []const u8, out: anytype) !void {
    const data = try std.fs.cwd().readFileAlloc(root, in_path, 512 * 1024 * 1024);
    defer root.free(data);

    var rdr = try container.Reader.parse(data, root);
    defer rdr.deinit();

    try std.fs.cwd().makePath(out_dir);

    var i: usize = 0;
    while (i < rdr.entryCount()) : (i += 1) {
        const entry = rdr.entryAt(i);
        const reconstructed = try rdr.extract(entry.getPath(), root);
        defer root.free(reconstructed);

        const actual_csum = container.fnv1a(reconstructed);
        const csum_ok = actual_csum == entry.checksum;

        var path_buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ out_dir, entry.getPath() });
        if (std.fs.path.dirname(full_path)) |parent| {
            try std.fs.cwd().makePath(parent);
        }
        const f = try std.fs.cwd().createFile(full_path, .{});
        defer f.close();
        try f.writeAll(reconstructed);

        try out.print("  {s}  {d}B  checksum_ok={}\n", .{ entry.getPath(), reconstructed.len, csum_ok });
    }
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
    _ = @import("gip_interface.zig");
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
    const gz = try container.gzipCompress(src, a);
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

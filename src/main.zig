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
    } else if (args.len >= 4 and std.mem.eql(u8, args[1], "packvfs")) {
        // Live (regular) per-entry mode the GUI drives — dedup + trained-dict
        // pre-passes included. Default tier balanced; arg 5 overrides (0/1/2).
        const tier: u8 = if (args.len >= 5) std.fmt.parseInt(u8, args[4], 10) catch 1 else 1;
        var cancel = std.atomic.Value(u8).init(0);
        var prog = std.atomic.Value(f32).init(0);
        var ticker: [512]u8 = undefined;
        try packDirectoryVfsAbi(root, args[2], args[3], tier, &cancel, &prog, &ticker);
        try out.print("Wrote {s}\n", .{args[3]});
    } else if (args.len >= 4 and std.mem.eql(u8, args[1], "packauto")) {
        // Auto/hybrid path (current GUI regular mode): per-file + solid buckets.
        const tier: u8 = if (args.len >= 5) std.fmt.parseInt(u8, args[4], 10) catch 1 else 1;
        var cancel = std.atomic.Value(u8).init(0);
        var prog = std.atomic.Value(f32).init(0);
        var ticker: [512]u8 = undefined;
        try packDirectoryAutoAbi(root, args[2], args[3], tier, &cancel, &prog, &ticker);
        try out.print("Wrote {s}\n", .{args[3]});
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "bcj2bench")) {
        try bcj2Bench(root, args[2], out);
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "cmbench")) {
        try cmBench(root, args[2], out);
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "x64bench")) {
        try x64Bench(root, args[2], out);
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "lzmaenc")) {
        const pen: u32 = if (args.len >= 4) (std.fmt.parseInt(u32, args[3], 10) catch 0) else 0;
        try lzmaEncBench(root, args[2], pen, out);
    } else if (args.len >= 5 and std.mem.eql(u8, args[1], "lzmatokens")) {
        // lzmatokens <file.lzma> <known_size> <out.txt> : dump pos/kind/len/dist per token
        const lzma_enc = @import("lzma_enc.zig");
        const f = try std.fs.cwd().openFile(args[2], .{});
        defer f.close();
        const data = try f.readToEndAlloc(root, 1 << 30);
        defer root.free(data);
        const known = std.fmt.parseInt(usize, args[3], 10) catch null;
        var buf = std.ArrayList(u8).init(root);
        defer buf.deinit();
        _ = try lzma_enc.dumpStats(data, root, known, &buf);
        const of = try std.fs.cwd().createFile(args[4], .{});
        defer of.close();
        try of.writeAll(buf.items);
        try out.print("wrote {d} token lines to {s}\n", .{ std.mem.count(u8, buf.items, "\n"), args[4] });
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "transcode")) {
        const lzma_enc = @import("lzma_enc.zig");
        const f = try std.fs.cwd().openFile(args[2], .{});
        defer f.close();
        const data = try f.readToEndAlloc(root, 1 << 30);
        defer root.free(data);
        const known: ?usize = if (args.len >= 4) (std.fmt.parseInt(usize, args[3], 10) catch null) else null;
        const re = try lzma_enc.transcodeLen(data, known, root);
        try out.print("input .lzma {d} B -> re-emitted through OUR model: {d} B (delta {d})\n", .{ data.len, re, @as(i64, @intCast(re)) - @as(i64, @intCast(data.len)) });
    } else if (args.len >= 4 and std.mem.eql(u8, args[1], "mfprobe")) {
        const lzma_enc = @import("lzma_enc.zig");
        const f = try std.fs.cwd().openFile(args[2], .{});
        defer f.close();
        const data = try f.readToEndAlloc(root, 1 << 30);
        defer root.free(data);
        const pos = try std.fmt.parseInt(usize, args[3], 10);
        var buf: [300]lzma_enc.Match = undefined;
        const dict: u32 = 1 << 26;
        const n = try lzma_enc.probeMatchesAt(data, pos, .{ .dict_size = dict, .max_depth = 1024 }, root, &buf);
        try out.print("matches at pos {d} ({d} found):\n", .{ pos, n });
        for (buf[0..n]) |m| try out.print("  len {d:>3}  dist {d}\n", .{ m.len, m.dist });
    } else if (args.len >= 3 and std.mem.eql(u8, args[1], "lzmadump")) {
        const lzma_enc = @import("lzma_enc.zig");
        const f = try std.fs.cwd().openFile(args[2], .{});
        defer f.close();
        const data = try f.readToEndAlloc(root, 1 << 30);
        defer root.free(data);
        const known: ?usize = if (args.len >= 4) (std.fmt.parseInt(usize, args[3], 10) catch null) else null;
        const s = try lzma_enc.dumpStats(data, root, known, null);
        const ol: f64 = @floatFromInt(s.out_len);
        try out.print("tokens for {s} (decoded {d} bytes):\n", .{ args[2], s.out_len });
        try out.print("  literals     : {d:>10}  ({d:.1}% of output bytes)\n", .{ s.n_lit, @as(f64, @floatFromInt(s.n_lit)) / ol * 100 });
        try out.print("  new matches  : {d:>10}  ({d:.1}% of bytes, avg len {d:.1}, avg dist {d})\n", .{ s.n_newmatch, @as(f64, @floatFromInt(s.newmatch_bytes)) / ol * 100, if (s.n_newmatch > 0) @as(f64, @floatFromInt(s.newmatch_bytes)) / @as(f64, @floatFromInt(s.n_newmatch)) else 0, if (s.n_newmatch > 0) s.sum_newmatch_dist / s.n_newmatch else 0 });
        try out.print("  rep matches  : {d:>10}  ({d:.1}% of bytes, avg len {d:.1})  [rep0 {d}, rep1-3 {d}]\n", .{ s.n_rep, @as(f64, @floatFromInt(s.rep_bytes)) / ol * 100, if (s.n_rep > 0) @as(f64, @floatFromInt(s.rep_bytes)) / @as(f64, @floatFromInt(s.n_rep)) else 0, s.rep0_used, s.rep_far_used });
        try out.print("  short reps   : {d:>10}\n", .{s.n_shortrep});
        try out.print("  total tokens : {d}\n", .{s.n_lit + s.n_newmatch + s.n_rep + s.n_shortrep});
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

/// Diagnostic: run our pure-Zig LZMA encoder on a file, write the .lzma so it
/// can be decode-verified with `xz -d --format=lzma`, and compare its size to
/// liblzma 9e. This is the foundation for closing the parser gap to 7-Zip.
fn lzmaEncBench(root: std.mem.Allocator, path: []const u8, penalty: u32, out: anytype) !void {
    const lzma_enc = @import("lzma_enc.zig");
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const data = try f.readToEndAlloc(root, 1 << 30);
    defer root.free(data);

    var dict: u32 = 1 << 20;
    while (dict < data.len and dict < (1 << 27)) dict <<= 1;

    const cfg = lzma_enc.Options{ .dict_size = dict, .nice_len = 273, .max_depth = 1024, .window = 1024, .kbest = if (penalty > 0) penalty else 4 };

    var t = try std.time.Timer.start();
    const greedy = try lzma_enc.compress(data, root, cfg);
    defer root.free(greedy);
    const greedy_ms = t.read() / std.time.ns_per_ms;

    t.reset();
    const ours = try lzma_enc.compressOpt(data, root, cfg);
    defer root.free(ours);
    const opt_ms = t.read() / std.time.ns_per_ms;

    t.reset();
    const oursK = try lzma_enc.compressOptK(data, root, cfg);
    defer root.free(oursK);
    const optk_ms = t.read() / std.time.ns_per_ms;

    // write the K-best .lzma for external decode verification
    const lf = try std.fs.cwd().createFile("/tmp/ours.lzma", .{});
    defer lf.close();
    try lf.writeAll(oursK);
    try out.print("  multi-state K: {d}  ({d} ms)\n", .{ oursK.len, optk_ms });
    { // also dump greedy for forensic distance comparison
        const gf = try std.fs.cwd().createFile("/tmp/greedy.lzma", .{});
        defer gf.close();
        try gf.writeAll(greedy);
    }

    const lz = try container.lzmaCompress(data, root, container.lzmaPreset(2));
    defer root.free(lz);

    const o: f64 = @floatFromInt(ours.len);
    const l: f64 = @floatFromInt(lz.len);
    try out.print("lzmaenc on {s} ({d} B)\n", .{ path, data.len });
    try out.print("  greedy+lazy   : {d}  ({d} ms)\n", .{ greedy.len, greedy_ms });
    try out.print("  optimal parse : {d}  ({d} ms)  -> /tmp/ours.lzma\n", .{ ours.len, opt_ms });
    try out.print("  liblzma 9e    : {d}\n", .{lz.len});
    try out.print("  optimal vs 9e : {d:.2}% ({s})\n", .{ (o / l - 1.0) * 100.0, if (ours.len < lz.len) " OURS SMALLER" else "liblzma smaller" });
    try out.print("  verify: xz -d --format=lzma < /tmp/ours.lzma | cmp - {s}\n", .{path});
}

/// Diagnostic: measure the x86-64 RIP-relative filter's effect on LZMA size.
fn x64Bench(root: std.mem.Allocator, path: []const u8, out: anytype) !void {
    const x64 = @import("x64.zig");
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const data = try f.readToEndAlloc(root, 1 << 30);
    defer root.free(data);
    const preset = container.lzmaPreset(2);

    const raw_lz = try container.lzmaCompress(data, root, preset);
    defer root.free(raw_lz);
    const bcj_raw = try container.lzmaCompressX86(data, root, preset);
    defer root.free(bcj_raw);
    // BCJ2 on raw, and BCJ2 on RIP-filtered (both fast-decode, full mode CM off here)
    const bcj2_raw = container.buildBcj2Block(data, preset, false, root) catch null;
    defer if (bcj2_raw) |b| root.free(b);

    const filt = try x64.filter(data, root);
    defer if (filt) |fb| root.free(fb);

    var filt_lz_len: usize = raw_lz.len;
    var filt_bcj2_len: usize = if (bcj2_raw) |b| b.len else raw_lz.len;
    var rt: []const u8 = "n/a";
    if (filt) |fb| {
        const flz = try container.lzmaCompress(fb, root, preset);
        defer root.free(flz);
        filt_lz_len = flz.len;
        if (container.buildBcj2Block(fb, preset, false, root) catch null) |fb2| {
            defer root.free(fb2);
            filt_bcj2_len = fb2.len;
        }
        const back = try root.dupe(u8, fb);
        defer root.free(back);
        x64.unfilter(back);
        rt = if (std.mem.eql(u8, back, data)) "OK" else "FAIL";
    }
    const cnt_buf = try root.dupe(u8, data);
    defer root.free(cnt_buf);
    const ripn = x64.apply(cnt_buf, true);
    try out.print("x64 bench on {s} ({d} B), rip-filter rt {s}, rip-refs-found {d}\n", .{ path, data.len, rt, ripn });
    try out.print("  plain LZMA            : {d}\n", .{raw_lz.len});
    try out.print("  x86 BCJ LZMA          : {d}\n", .{bcj_raw.len});
    try out.print("  BCJ2 (raw)            : {d}\n", .{if (bcj2_raw) |b| b.len else 0});
    try out.print("  RIP + LZMA            : {d}\n", .{filt_lz_len});
    try out.print("  RIP + BCJ2            : {d}\n", .{filt_bcj2_len});
}

/// Diagnostic: measure the CM backend vs LZMA 9e on a file, with round-trip + timing.
fn cmBench(root: std.mem.Allocator, path: []const u8, out: anytype) !void {
    const cm = @import("cm.zig");
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const data = try f.readToEndAlloc(root, 1 << 30);
    defer root.free(data);

    var t = try std.time.Timer.start();
    const comp = try cm.compress(data, root);
    defer root.free(comp);
    const enc_ms = t.read() / std.time.ns_per_ms;
    t.reset();
    const back = try cm.decompress(comp, data.len, root);
    defer root.free(back);
    const dec_ms = t.read() / std.time.ns_per_ms;
    const ok = std.mem.eql(u8, data, back);

    const lz = try container.lzmaCompress(data, root, container.lzmaPreset(2));
    defer root.free(lz);

    try out.print("CM bench on {s} ({d} B), round-trip {s}\n", .{ path, data.len, if (ok) "OK" else "FAIL" });
    try out.print("  CM          : {d}  ({d} ms enc, {d} ms dec)\n", .{ comp.len, enc_ms, dec_ms });
    try out.print("  LZMA 9e     : {d}\n", .{lz.len});
    const c: f64 = @floatFromInt(comp.len);
    const l: f64 = @floatFromInt(lz.len);
    try out.print("  CM vs LZMA  : {d:.2}% ({s})\n", .{ (c / l - 1.0) * 100.0, if (comp.len < lz.len) "CM wins" else "LZMA wins" });
}

/// Diagnostic: measure BCJ2 (4-stream, range-coded control) vs in-place x86 BCJ
/// and plain LZMA on a real binary, and verify the round-trip. Prints byte sizes
/// so we can decide whether BCJ2 earns its place in full mode.
fn bcj2Bench(root: std.mem.Allocator, path: []const u8, out: anytype) !void {
    const bcj2 = @import("bcj2.zig");
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const data = try f.readToEndAlloc(root, 1 << 30);
    defer root.free(data);

    const preset = container.lzmaPreset(2);

    // BCJ2: split, LZMA each of main/call/jump, store rc raw (already range-coded).
    var s = try bcj2.encode(data, root);
    defer s.deinit(root);
    const lm = try container.lzmaCompress(s.main, root, preset);
    defer root.free(lm);
    const lc = try container.lzmaCompress(s.call, root, preset);
    defer root.free(lc);
    const lj = try container.lzmaCompress(s.jump, root, preset);
    defer root.free(lj);
    const bcj2_total = lm.len + lc.len + lj.len + s.rc.len;

    // Param sweep: find the smallest LZMA (lc,lp,pb) for each stream. The address
    // streams are 4-byte big-endian records, so position/literal-position bits
    // matched to 4 (pb/lp=2) usually beat the default lc3/lp0/pb2.
    const Combo = struct { lc: u32, lp: u32, pb: u32 };
    const combos = [_]Combo{
        .{ .lc = 3, .lp = 0, .pb = 2 }, // default
        .{ .lc = 0, .lp = 2, .pb = 2 },
        .{ .lc = 1, .lp = 2, .pb = 2 },
        .{ .lc = 0, .lp = 0, .pb = 0 },
        .{ .lc = 4, .lp = 0, .pb = 0 },
        .{ .lc = 2, .lp = 2, .pb = 2 },
    };
    const Best = struct {
        fn of(stream: []const u8, a: std.mem.Allocator, pr: u32, cs: []const Combo) struct { len: usize, c: Combo } {
            var best_len: usize = std.math.maxInt(usize);
            var best_c = cs[0];
            for (cs) |c| {
                const z = container.lzmaCompressTuned(stream, a, pr, c.lc, c.lp, c.pb) catch continue;
                defer a.free(z);
                if (z.len < best_len) {
                    best_len = z.len;
                    best_c = c;
                }
            }
            return .{ .len = best_len, .c = best_c };
        }
    };
    const bm = Best.of(s.main, root, preset, &combos);
    const bc = Best.of(s.call, root, preset, &combos);
    const bj = Best.of(s.jump, root, preset, &combos);
    const tuned_total = bm.len + bc.len + bj.len + s.rc.len;

    // BCJ2 + CM: context-mix the main stream (LZMA the small address streams).
    const cm = @import("cm.zig");
    const cm_main = cm.compress(s.main, root) catch &[_]u8{};
    defer if (cm_main.len > 0) root.free(cm_main);
    const cm_total = cm_main.len + bc.len + bj.len + s.rc.len;

    // Round-trip check.
    const back = try bcj2.decode(s.main, s.call, s.jump, s.rc, data.len, root);
    defer root.free(back);
    const ok = std.mem.eql(u8, data, back);

    // References.
    const plain = try container.lzmaCompress(data, root, preset);
    defer root.free(plain);
    const inplace = try container.lzmaCompressX86(data, root, preset);
    defer root.free(inplace);

    try out.print("BCJ2 bench on {s} ({d} B), round-trip {s}\n", .{ path, data.len, if (ok) "OK" else "FAIL" });
    try out.print("  streams: main={d} call={d} jump={d} rc={d}\n", .{ s.main.len, s.call.len, s.jump.len, s.rc.len });
    try out.print("  LZMA(main)={d} LZMA(call)={d} LZMA(jump)={d} +rc={d}\n", .{ lm.len, lc.len, lj.len, s.rc.len });
    try out.print("  plain LZMA        : {d}\n", .{plain.len});
    try out.print("  in-place x86 BCJ  : {d}\n", .{inplace.len});
    try out.print("  BCJ2 (4-stream)   : {d}\n", .{bcj2_total});
    try out.print("  BCJ2 tuned        : {d}  (main lc{d}lp{d}pb{d}={d}, call lc{d}lp{d}pb{d}={d}, jump lc{d}lp{d}pb{d}={d})\n", .{
        tuned_total,
        bm.c.lc, bm.c.lp, bm.c.pb, bm.len,
        bc.c.lc, bc.c.lp, bc.c.pb, bc.len,
        bj.c.lc, bj.c.lp, bj.c.pb, bj.len,
    });
    try out.print("  BCJ2 + CM(main)   : {d}  (cm_main={d})\n", .{ cm_total, cm_main.len });
    const prod = container.buildBcj2Block(data, preset, true, root) catch &[_]u8{};
    defer if (prod.len > 0) root.free(prod);
    try out.print("  BCJ2 production   : {d}  (what full mode stores)\n", .{prod.len});
    const base: f64 = @floatFromInt(inplace.len);
    const b2: f64 = @floatFromInt(tuned_total);
    try out.print("  BCJ2-tuned vs in-place : {d:.2}% ({s})\n",
        .{ (b2 / base - 1.0) * 100.0, if (tuned_total < inplace.len) "BCJ2 wins" else "in-place wins" });
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

    /// Effort for the live per-entry (regular) modes. Identical to fromTier
    /// except Max swaps the per-entry codec to LZMA: at Max the user is after
    /// best ratio (ship/cold), and per-entry LZMA keeps random access (each
    /// asset independently decodable) while closing most of the backend gap to
    /// xz. Fast/Balanced stay on zstd so the live-hot path keeps fast decode.
    fn fromTierRegular(tier: u8) Effort {
        var e = fromTier(tier);
        // Max-regular must stay LIVE. zstd decode is fast and ~level-independent, so push the
        // per-entry codec to max zstd level (best ratio at flat decode latency) instead of LZMA,
        // which decodes ~2.5x slower and breaks the live promise. LZMA/CM ratio is full mode's job.
        if (tier == 2) e.comp.zstd_level = 22;
        return e;
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

// Whole-file dedup: SHA-256 of raw content -> the shared blob's location/meta,
// so exact-duplicate files cost one blob. SHA-256 (not the FNV-1a u32 checksum)
// because a dedup collision would corrupt data; 256-bit makes that impossible
// in practice. Shared across the parallel pack under a mutex.
const DedupVal = struct {
    offset: u64,
    csize: u64,
    ctype: container.CompressionType,
    codec: container.Codec,
    solid_index: u32,
};
const DedupMap = std.AutoHashMap([32]u8, DedupVal);

fn sha256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
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
    try pool.init(.{ .allocator = root, .n_jobs = @as(u32, @intCast(container.recommendedThreads())) });
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
            break :blk try ctx.cb.addChunkedStreamingFile(rel_path, file, fsize);
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
    try pool.init(.{ .allocator = root, .n_jobs = @as(u32, @intCast(container.recommendedThreads())) });
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

    // Rank filters with a FAST codec (zstd-1), then run the expensive final
    // codec once on the winner. Without this, large files paid one full LZMA-9e
    // pass PER filter (up to 4×) — pathological on big binaries.
    var best_filter: container.Filter = .delta1;
    var best_rank: usize = std.math.maxInt(usize);
    for (cand[0..n]) |f| {
        const filtered = try container.applyFilter(f, data, alloc);
        defer alloc.free(filtered);
        const rank = (try container.zstdCompress(filtered, alloc, 1)).len;
        if (rank < best_rank) {
            best_rank = rank;
            best_filter = f;
        }
    }

    const filtered = try container.applyFilter(best_filter, data, alloc);
    defer alloc.free(filtered);
    const b = try effort.comp.compress(filtered, alloc);
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
fn bestColumnarBlock(data: []const u8, effort: Effort, final_comp: container.Compressor, alloc: std.mem.Allocator) !?[]u8 {
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

    // Commit the winning stride at the chosen final codec, trying plain transpose
    // and transpose + per-column delta (huge on smooth record arrays); keep the
    // smaller. Delta is reversible + fast, so it stays live-safe. The stride's
    // high bit flags delta for the decoder.
    const t = try container.columnarForward(data, best_stride, alloc);
    defer alloc.free(t);
    const td = try alloc.dupe(u8, t);
    defer alloc.free(td);
    container.columnarColDelta(td, best_stride, data.len, true);

    const comp = try final_comp.compress(t, alloc);
    defer alloc.free(comp);
    const compd = try final_comp.compress(td, alloc);
    defer alloc.free(compd);

    const use_delta = compd.len < comp.len;
    const chosen = if (use_delta) compd else comp;
    const sflag: u16 = @as(u16, @intCast(best_stride)) | (if (use_delta) @as(u16, 0x8000) else 0);
    const payload = try alloc.alloc(u8, 2 + chosen.len);
    std.mem.writeInt(u16, payload[0..2], sflag, .little);
    @memcpy(payload[2..], chosen);
    return payload;
}

/// MATH_FLOAT: the float/numeric predictor. Maps each value to a monotonic int,
/// predicts it (1D delta OR 2D Lorenzo over an auto-detected row width), and
/// byte-planes the residual. Net-new ground vs zstd/xz on binary float/int arrays
/// (sensor/telemetry/scientific/time-series), which have no repeated substrings
/// but lots of value-domain redundancy; the 2D Lorenzo stencil is what the
/// scientific compressors (ZFP/SZ) use on smooth grids. Tries element widths 4/8,
/// mapped/raw, 1D + 2D at power-of-two row widths (+ the square side), ranks them
/// on a bounded prefix sample, and commits the best — but only if it beats plain.
/// Block: `[u8 width][u8 mode(bit0=map,bit1=2D)][u32 row_width][compressed
/// residual]`. Honesty-guarded at the call site; the transform is exact + bijective.
fn bestFloatBlock(data: []const u8, effort: Effort, final_comp: container.Compressor, alloc: std.mem.Allocator) !?[]u8 {
    if (effort.tier == 0 or data.len < 4096 or data.len > 64 * 1024 * 1024) return null;
    if (looksTexty(data)) return null; // numbers-as-text hide the structure; LZMA/CM owns text

    const Cand = struct { ew: u8, map: bool, pred2d: bool, rw: u32 };
    var cands = std.ArrayList(Cand).init(alloc);
    defer cands.deinit();
    inline for ([_]u8{ 4, 8 }) |ew| {
        if (data.len % ew == 0) {
            const n = data.len / ew;
            try cands.append(.{ .ew = ew, .map = true, .pred2d = false, .rw = 0 }); // 1D
            try cands.append(.{ .ew = ew, .map = false, .pred2d = false, .rw = 0 });
            var w: usize = 16; // 2D Lorenzo at power-of-two row widths that tile n
            while (w <= n / 4) : (w *= 2) {
                if (n % w == 0) try cands.append(.{ .ew = ew, .map = true, .pred2d = true, .rw = @intCast(w) });
            }
            var s: usize = @intFromFloat(@sqrt(@as(f64, @floatFromInt(n)))); // square side
            while (s > 1 and s * s > n) s -= 1;
            while ((s + 1) * (s + 1) <= n) s += 1;
            if (s >= 2 and s * s == n and (s & (s - 1)) != 0)
                try cands.append(.{ .ew = ew, .map = true, .pred2d = true, .rw = @intCast(s) });
        }
    }
    if (cands.items.len == 0) return null;

    // Rank on a bounded prefix sample (whole rows for 2D) in compressed-bytes-per-
    // input-byte; only commit if the best beats plain on the same sample.
    const SAMPLE: usize = 4 * 1024 * 1024;
    const plain_sl: usize = @min(data.len, SAMPLE);
    const plain_rk = try container.zstdCompress(data[0..plain_sl], alloc, 1);
    var best_bpb: f64 = @as(f64, @floatFromInt(plain_rk.len)) / @as(f64, @floatFromInt(plain_sl));
    alloc.free(plain_rk);

    var best: ?Cand = null;
    for (cands.items) |c| {
        const unit: usize = if (c.pred2d) @as(usize, c.ew) * @as(usize, c.rw) else c.ew;
        var sl: usize = @min(data.len, SAMPLE);
        sl -= sl % unit;
        if (sl == 0 or (c.pred2d and sl < 2 * unit)) continue;
        const t = try container.numericForward(data[0..sl], c.ew, c.map, c.pred2d, c.rw, alloc);
        defer alloc.free(t);
        const rk = try container.zstdCompress(t, alloc, 1);
        defer alloc.free(rk);
        const bpb = @as(f64, @floatFromInt(rk.len)) / @as(f64, @floatFromInt(sl));
        if (bpb < best_bpb) {
            best_bpb = bpb;
            best = c;
        }
    }
    const c = best orelse return null;

    // Commit the winning variant on the FULL data at the final codec.
    const t = try container.numericForward(data, c.ew, c.map, c.pred2d, c.rw, alloc);
    defer alloc.free(t);
    const comp = try final_comp.compress(t, alloc);
    defer alloc.free(comp);
    const payload = try alloc.alloc(u8, 6 + comp.len);
    payload[0] = c.ew;
    payload[1] = (if (c.map) @as(u8, 1) else 0) | (if (c.pred2d) @as(u8, 2) else 0);
    std.mem.writeInt(u32, payload[2..6], c.rw, .little);
    @memcpy(payload[6..], comp);
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
fn bestImage2DBlock(data: []const u8, effort: Effort, final_comp: container.Compressor, alloc: std.mem.Allocator) !?[]u8 {
    if (effort.tier == 0 or data.len < 256) return null;
    const info = detectImage(data) orelse return null;
    const pix_end = data.len - info.footer_len;

    // Keep-smaller over {interleaved, planar} × {plain, subtract-green}. Planar
    // (per-plane MED) groups same-channel residuals; subtract-green decorrelates
    // colour. Both are reversible; the choices are recorded in the channels byte
    // (bit6 planar, bit7 subtract-green) so decode reverses them.
    const ch: usize = info.channels;
    const n: usize = @as(usize, info.width) * info.height;
    var best: ?[]u8 = null;
    for ([_]bool{ false, true }) |planar| {
        for ([_]bool{ false, true }) |sg| {
            if (sg and ch < 3) continue; // colour transform needs RGB(A)
            if (planar and ch < 2) continue; // planar pointless for 1 channel
            const px = try alloc.dupe(u8, data[info.header_len..pix_end]);
            defer alloc.free(px);
            if (sg) container.subtractGreen(px, ch);
            // residual = MED (interleaved, or per-plane after deinterleave)
            var residual: []u8 = undefined;
            if (planar) {
                const pl = try container.deinterleavePlanes(px, ch, alloc);
                defer alloc.free(pl);
                residual = try alloc.alloc(u8, px.len);
                var c: usize = 0;
                while (c < ch) : (c += 1) {
                    const r = try container.medForward(pl[c * n .. c * n + n], info.width, info.height, 1, alloc);
                    defer alloc.free(r);
                    @memcpy(residual[c * n .. c * n + n], r);
                }
            } else {
                residual = try container.medForward(px, info.width, info.height, info.channels, alloc);
            }
            defer alloc.free(residual);
            const transformed = try alloc.alloc(u8, data.len);
            defer alloc.free(transformed);
            @memcpy(transformed[0..info.header_len], data[0..info.header_len]);
            @memcpy(transformed[info.header_len..pix_end], residual);
            @memcpy(transformed[pix_end..], data[pix_end..]);
            const comp = try final_comp.compress(transformed, alloc);
            defer alloc.free(comp);
            const payload = try alloc.alloc(u8, 17 + comp.len);
            std.mem.writeInt(u32, payload[0..4], @intCast(info.header_len), .little);
            std.mem.writeInt(u32, payload[4..8], @intCast(info.footer_len), .little);
            std.mem.writeInt(u32, payload[8..12], info.width, .little);
            std.mem.writeInt(u32, payload[12..16], info.height, .little);
            payload[16] = info.channels | (if (sg) @as(u8, 0x80) else 0) | (if (planar) @as(u8, 0x40) else 0);
            @memcpy(payload[17..], comp);
            if (best == null or payload.len < best.?.len) {
                if (best) |b| alloc.free(b);
                best = payload;
            } else alloc.free(payload);
        }
    }
    return best;
}

const AudioInfo = struct { header_len: usize, data_len: usize, channels: u8 };

/// Parse a WAV header for 16-bit PCM geometry: walk RIFF chunks, read `fmt `
/// (format, channels, bits) and locate `data`. Returns null for non-PCM,
/// non-16-bit, or anything that isn't a clean WAVE container. Header + sample
/// region + trailer cover the file; only the sample region is predicted.
fn detectAudio(data: []const u8) ?AudioInfo {
    if (data.len < 44) return null;
    if (!std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) return null;
    var i: usize = 12;
    var channels: u8 = 0;
    var bits: u16 = 0;
    var fmt_ok = false;
    var data_off: usize = 0;
    var data_sz: usize = 0;
    while (i + 8 <= data.len) {
        const id = data[i .. i + 4];
        const sz: usize = std.mem.readInt(u32, data[i + 4 .. i + 8][0..4], .little);
        const payload = i + 8;
        if (std.mem.eql(u8, id, "fmt ")) {
            if (payload + 16 > data.len) return null;
            const audio_format = std.mem.readInt(u16, data[payload .. payload + 2][0..2], .little);
            const chv = std.mem.readInt(u16, data[payload + 2 .. payload + 4][0..2], .little);
            bits = std.mem.readInt(u16, data[payload + 14 .. payload + 16][0..2], .little);
            if (audio_format != 1) return null; // PCM only
            if (chv == 0 or chv > 8) return null;
            channels = @intCast(chv);
            fmt_ok = true;
        } else if (std.mem.eql(u8, id, "data")) {
            data_off = payload;
            data_sz = sz;
            break;
        }
        // Chunks are word-aligned: advance past the payload + its pad byte.
        i = payload + sz + (sz & 1);
    }
    if (!fmt_ok or bits != 16 or data_off == 0) return null;
    if (data_off + data_sz > data.len) data_sz = data.len - data_off; // clamp ragged data chunk
    if (data_sz < 4) return null;
    return .{ .header_len = data_off, .data_len = data_sz, .channels = channels };
}

/// LPC-predict a detected WAV and return the MATH_AUDIO payload, or null if the
/// file isn't 16-bit PCM WAV. Tries fixed-predictor orders 0..3 and keeps the
/// one with the smallest residual magnitude. Honesty-guarded at the call site;
/// general compressors have no per-channel sample predictor, so this is net-new.
fn bestAudioBlock(data: []const u8, effort: Effort, final_comp: container.Compressor, alloc: std.mem.Allocator) !?[]u8 {
    if (effort.tier == 0 or data.len < 256) return null;
    const info = detectAudio(data) orelse return null;
    const dend = info.header_len + info.data_len;

    // Keep-smaller over {plain, mid/side} (stereo decorrelation, reversible +
    // fast → live-safe), each with the best fixed-predictor order. Recorded in
    // the channels byte's high bit so decode reverses mid/side.
    var best: ?[]u8 = null;
    for ([_]bool{ false, true }) |ms| {
        if (ms and info.channels != 2) continue;
        const region = try alloc.dupe(u8, data[info.header_len..dend]);
        defer alloc.free(region);
        if (ms) container.midSideForward(region);

        var best_order: u8 = 0;
        var best_cost: u64 = std.math.maxInt(u64);
        var ord: u8 = 0;
        while (ord <= 3) : (ord += 1) {
            const res = try container.lpcForward(region, info.channels, ord, alloc);
            defer alloc.free(res);
            var cost: u64 = 0;
            var j: usize = 0;
            while (j + 1 < res.len) : (j += 2) {
                const v: i32 = @as(i16, @bitCast(std.mem.readInt(u16, res[j..][0..2], .little)));
                cost += @abs(v);
            }
            if (cost < best_cost) {
                best_cost = cost;
                best_order = ord;
            }
        }

        const residual = try container.lpcForward(region, info.channels, best_order, alloc);
        defer alloc.free(residual);
        const transformed = try alloc.alloc(u8, data.len);
        defer alloc.free(transformed);
        @memcpy(transformed[0..info.header_len], data[0..info.header_len]);
        @memcpy(transformed[info.header_len..dend], residual);
        @memcpy(transformed[dend..], data[dend..]);

        const comp = try final_comp.compress(transformed, alloc);
        defer alloc.free(comp);
        const payload = try alloc.alloc(u8, 10 + comp.len);
        std.mem.writeInt(u32, payload[0..4], @intCast(info.header_len), .little);
        std.mem.writeInt(u32, payload[4..8], @intCast(info.data_len), .little);
        payload[8] = info.channels | (if (ms) @as(u8, 0x80) else 0);
        payload[9] = best_order;
        @memcpy(payload[10..], comp);
        if (best == null or payload.len < best.?.len) {
            if (best) |b| alloc.free(b);
            best = payload;
        } else alloc.free(payload);
    }
    return best;
}

/// Per-file BCJ2 for regular mode: an x86 binary gets the same 4-stream
/// range-coded filter full mode uses, but as a single per-entry block (still
/// random-access / live-decodable). Max-tier only (the streams are LZMA'd), and
/// only on files that look like x86 code with enough body to amortize the
/// per-stream overhead. Honesty-guarded at the call site. This is what lets
/// regular mode keep pace with 7-Zip on binaries instead of losing to BCJ2.
fn bestBcj2Block(data: []const u8, effort: Effort, alloc: std.mem.Allocator) !?[]u8 {
    if (effort.tier != 2) return null;
    // Upper cap: buildBcj2Block runs LZMA on the main stream twice (plain + RIP
    // keep-smaller), so on a giant binary that's several full-file LZMA passes.
    // Above the cap, fall back to the single-pass plain/filtered route — bounds
    // worst-case pack time without hurting the common case (binaries are small).
    const BCJ2_FILE_CAP: usize = 48 * 1024 * 1024;
    if (data.len < 8192 or data.len > BCJ2_FILE_CAP or !looksLikeX86(data)) return null;
    // allow_cm = false: regular mode is LIVE, so the main stream stays LZMA
    // (fast decode). CM-main is full/cold mode's edge only.
    return try container.buildBcj2Block(data, container.lzmaPreset(effort.tier), false, alloc);
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

    if (try bestColumnarBlock(data, effort, effort.comp, alloc)) |payload| {
        if (payload.len < best_len) {
            if (best_payload) |b| alloc.free(b);
            best_type = .math_columnar;
            best_len = payload.len;
            best_payload = payload;
        } else alloc.free(payload);
    }

    if (try bestFloatBlock(data, effort, effort.comp, alloc)) |payload| {
        if (payload.len < best_len) {
            if (best_payload) |b| alloc.free(b);
            best_type = .math_float;
            best_len = payload.len;
            best_payload = payload;
        } else alloc.free(payload);
    }

    if (try bestImage2DBlock(data, effort, effort.comp, alloc)) |payload| {
        if (payload.len < best_len) {
            if (best_payload) |b| alloc.free(b);
            best_type = .math_image2d;
            best_len = payload.len;
            best_payload = payload;
        } else alloc.free(payload);
    }

    if (try bestAudioBlock(data, effort, effort.comp, alloc)) |payload| {
        if (payload.len < best_len) {
            if (best_payload) |b| alloc.free(b);
            best_type = .math_audio;
            best_len = payload.len;
            best_payload = payload;
        } else alloc.free(payload);
    }

    if (try bestBcj2Block(data, effort, alloc)) |payload| {
        if (payload.len < best_len) {
            if (best_payload) |b| alloc.free(b);
            best_type = .math_bcj2;
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
        .math_audio => "AUDIO   ",
        .math_float => "FLOAT   ",
        .math_bcj2 => "BCJ2    ",
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

        // Lifted entries (whole-file program, filtered, columnar, 2D-image, or
        // audio-LPC) are individual files; anything else is the one wrapped tar.
        const is_lifted = switch (entry.comp_type) {
            .math_bytecode, .math_filtered, .math_columnar, .math_image2d, .math_audio, .math_float => true,
            else => false,
        };
        if (!is_lifted) {
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
    const colp = (try bestColumnarBlock(data, effort, effort.comp, a)) orelse return error.TestUnexpectedResult;
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
    try pool.init(.{ .allocator = root, .n_jobs = @as(u32, @intCast(container.recommendedThreads())) });
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
            break :blk try ctx.scb.inner.addChunkedStreamingFile(rel_path, file, fsize);
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
    try pool.init(.{ .allocator = root, .n_jobs = @as(u32, @intCast(container.recommendedThreads())) });
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
// Trained-dictionary pre-pass (live cross-file sharing)
// ---------------------------------------------------------------------------
//
// Many small similar files (per-language strings, JSON manifests, shader
// variants, config) compress far better when the codec can reference shared
// patterns across files. A solid block does that but destroys random access,
// so it's banned from live mode. A trained zstd *dictionary* gets the same
// cross-file sharing while keeping every entry independently decodable: the
// dict is shipped ONCE per archive and each entry is its own dict-primed frame.
//
// This pass groups the unique representatives by file extension, trains one
// dict per large-enough group, and claims a file as a .math_dict entry ONLY
// when the dict-primed frame beats that file's real backend size (the honesty
// guard — at Max the baseline is per-entry LZMA, so we never trade a smaller
// LZMA block for a larger dict one). The dict's shipped bytes must be repaid by
// the group's total saving (the amortization gate) or the whole group is left
// to normal routing. Claimed files are removed from `reps` so the parallel pass
// skips them; dedup of duplicates still works because the post-pass copies the
// rep's comp_type/solid_index, which carries the dict index.

const DICT_MIN_FILES: usize = 16; // ZDICT needs a real corpus; small groups can't amortize a dict
const DICT_MAX_FILE: usize = 64 * 1024; // the win is on many SMALL similar files
const DICT_MAX_GROUP_FILES: usize = 4096; // bound per-group memory/compute
const DICT_MAX_GROUP_BYTES: usize = 64 * 1024 * 1024; // bound per-group memory

/// Last extension of `rel` (including the dot), or "" if none. Case-sensitive
/// (mixed-case same-type files are rare in asset trees; the gate just fails for
/// any odd group, so this never produces a wrong archive — only a missed win).
fn fileExt(rel: []const u8) []const u8 {
    var i = rel.len;
    var dot: ?usize = null;
    while (i > 0) {
        i -= 1;
        if (rel[i] == '/') break;
        if (rel[i] == '.' and dot == null) dot = i;
    }
    if (dot) |d| return rel[d..];
    return "";
}

/// Train+test a shared dict per extension group and claim winning files as
/// .math_dict entries appended to `cb` (the per-file StreamingBuilder; for the
/// auto/solid path pass `&scb.inner`). Records claimed indices into `items` in
/// `claimed` — the caller removes them from its own list, handling ownership.
/// Serial — runs before the parallel pass, so no cb locking. Works for both the
/// pure VFS path and the auto path because both ultimately funnel per-file
/// blocks + dicts through a StreamingBuilder.
fn dictPrePass(
    root: std.mem.Allocator,
    dir_path: []const u8,
    effort: Effort,
    cb: *container.StreamingBuilder,
    items: []const []u8,
    claimed: *std.AutoHashMap(usize, void),
) !void {
    // Escape hatch / A-B switch: MATHPRESSOR_NODICT disables the dict route.
    if (std.process.hasEnvVarConstant("MATHPRESSOR_NODICT")) return;

    const dict_level: c_int = switch (effort.tier) {
        0 => 12,
        2 => 19,
        else => 16,
    };

    // Group representative indices by extension.
    var groups = std.StringHashMap(std.ArrayList(usize)).init(root);
    defer {
        var it = groups.valueIterator();
        while (it.next()) |v| v.deinit();
        groups.deinit();
    }
    for (items, 0..) |rel, i| {
        const ext = fileExt(rel);
        if (ext.len == 0) continue; // skip extensionless: heterogeneous, no shared model
        const gop = try groups.getOrPut(ext);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(usize).init(root);
        try gop.value_ptr.append(i);
    }

    var dicts_made: u32 = 0;
    var files_claimed: u32 = 0;
    var bytes_saved: i64 = 0;

    var git = groups.iterator();
    while (git.next()) |g| {
        const idxs = g.value_ptr.items;
        if (idxs.len < DICT_MIN_FILES) continue;

        var arena = std.heap.ArenaAllocator.init(root);
        defer arena.deinit();
        const a = arena.allocator();

        // Read eligible (small, regular) files into the arena.
        var contents = std.ArrayList([]u8).init(a);
        var content_idx = std.ArrayList(usize).init(a); // parallel: rep index per content
        var total_bytes: usize = 0;
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        for (idxs) |ri| {
            if (contents.items.len >= DICT_MAX_GROUP_FILES or total_bytes >= DICT_MAX_GROUP_BYTES) break;
            const rel = items[ri];
            const full = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir_path, rel }) catch continue;
            var lb: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fs.cwd().readLink(full, &lb)) |_| continue else |_| {}
            const st = std.fs.cwd().statFile(full) catch continue;
            if (st.kind != .file or st.size == 0 or st.size > DICT_MAX_FILE) continue;
            const f = std.fs.cwd().openFile(full, .{}) catch continue;
            defer f.close();
            const data = f.readToEndAlloc(a, DICT_MAX_FILE) catch continue;
            contents.append(data) catch continue;
            content_idx.append(ri) catch continue;
            total_bytes += data.len;
        }
        if (contents.items.len < DICT_MIN_FILES) continue;

        // Baseline (the real backend size each file would otherwise get) and the
        // file's checksum — independent of the dict, so computed once.
        const Cand = struct { ri: usize, block: []u8, orig: usize, csum: u32 };
        const base_len = try a.alloc(usize, contents.items.len);
        for (contents.items, 0..) |c, k| {
            const base = effort.comp.compress(c, a) catch {
                base_len[k] = std.math.maxInt(usize);
                continue;
            };
            base_len[k] = base.len;
        }

        // Train at several capacities and keep whichever dict yields the smallest
        // net (shipped dict + dict-compressed winners). Highly-similar files want
        // a bigger dict than ZDICT's default ~1/100 heuristic; the amortization
        // gate makes overshoot self-correcting, so trying a few is safe.
        var sizes = std.ArrayList(usize).init(a);
        var concat = std.ArrayList(u8).init(a);
        for (contents.items) |c| {
            sizes.append(c.len) catch continue;
            concat.appendSlice(c) catch continue;
        }
        const caps = [_]usize{
            std.math.clamp(total_bytes / 100, 4096, 112 * 1024),
            std.math.clamp(total_bytes / 16, 4096, 112 * 1024),
            std.math.clamp(total_bytes / 4, 8192, 112 * 1024),
        };

        var best_cands = std.ArrayList(Cand).init(a);
        var best_dict: []u8 = &[_]u8{};
        var best_net: usize = std.math.maxInt(usize);
        var best_sum_base: usize = 0;
        var last_cap: usize = 0;
        for (caps) |cap| {
            if (cap == last_cap) continue; // clamp can collapse caps to the same value
            last_cap = cap;
            const dict = (container.trainDict(concat.items, sizes.items, cap, a) catch null) orelse continue;
            if (dict.len == 0) continue;

            var cands = std.ArrayList(Cand).init(a);
            var sum_dict: usize = 0;
            var sum_base: usize = 0;
            for (contents.items, 0..) |c, k| {
                const dc = container.zstdCompressUsingDict(c, dict, dict_level, a) catch continue;
                if (dc.len < base_len[k]) {
                    cands.append(.{ .ri = content_idx.items[k], .block = dc, .orig = c.len, .csum = container.fnv1a(c) }) catch continue;
                    sum_dict += dc.len;
                    sum_base += base_len[k];
                }
            }
            if (cands.items.len < DICT_MIN_FILES) continue;
            const net = sum_dict + dict.len;
            if (net < sum_base and net < best_net) {
                best_net = net;
                best_cands = cands;
                best_dict = dict;
                best_sum_base = sum_base;
            }
        }
        if (best_cands.items.len < DICT_MIN_FILES) continue;

        // Commit: register the winning dict, emit each winner as a .math_dict entry.
        const dict_index = cb.registerDict(best_dict) catch continue;
        for (best_cands.items) |cand| {
            var fat = container.FatEntry{
                .comp_type = .math_dict,
                .solid_index = dict_index,
                .data_offset = 0,
                .original_size = cand.orig,
                .compressed_size = cand.block.len,
                .checksum = cand.csum,
                .codec = .zstd,
            };
            fat.setPath(items[cand.ri]) catch continue;
            cb.appendBlock(fat, cand.block) catch continue;
            claimed.put(cand.ri, {}) catch {};
            files_claimed += 1;
        }
        dicts_made += 1;
        bytes_saved += @as(i64, @intCast(best_sum_base)) - @as(i64, @intCast(best_net));
    }

    if (files_claimed == 0) return;

    var mbuf: [128]u8 = undefined;
    const ml = std.fmt.bufPrint(&mbuf,
        "  DICT      {d} file(s) share {d} trained dict(s), saved {d} B (incl. dict cost)\n",
        .{ files_claimed, dicts_made, bytes_saved }) catch "";
    std.io.getStdOut().writeAll(ml) catch {};
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
    var jobs = std.ArrayList([]u8).init(root);
    defer {
        for (jobs.items) |p| root.free(p);
        jobs.deinit();
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try collectWalk(root, dir_path, "", &path_buf, &jobs, cancel_flag);
    removeOutputJob(&jobs, root, dir_path, out_path);

    try packJobsVfs(root, dir_path, jobs.items, out_path, effort_tier,
        cancel_flag, progress_ptr, ticker_ptr);
}

/// Core of the live (regular) per-entry pack, shared by directory and selection
/// entry points. `jobs` are relative paths under `base_dir` (borrowed — the
/// caller owns and frees them). Runs the dedup + trained-dict pre-passes, the
/// parallel per-file routing, the dedup post-pass, then writes the archive.
/// Every entry stays independently decodable (random access) — this is the
/// live mode, so no solid grouping.
fn packJobsVfs(
    root: std.mem.Allocator,
    dir_path: []const u8,
    jobs_items: []const []u8,
    out_path: []const u8,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) !void {
    const effort = Effort.fromTierRegular(effort_tier);
    var cb = try container.StreamingBuilder.init(root);
    cb.comp = effort.comp;
    defer cb.deinit();

    // Whole-file dedup pre-pass (serial): SHA-256 each file, split into unique
    // representatives and exact duplicates. Done before the parallel pass to
    // avoid the TOCTOU where concurrent copies all miss an empty map. Symlinks,
    // huge (streamed), and over-long-path files are never deduped.
    const DupRef = struct { rel: []const u8, sha: [32]u8, csum: u32, orig: u64 };
    var reps = std.ArrayList([]u8).init(root);
    defer reps.deinit();
    var dups = std.ArrayList(DupRef).init(root);
    defer dups.deinit();
    var rep_path_to_sha = std.StringHashMap([32]u8).init(root);
    defer rep_path_to_sha.deinit();
    {
        var seen = std.AutoHashMap([32]u8, void).init(root);
        defer seen.deinit();
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        for (jobs_items) |rel| {
            const full = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir_path, rel }) catch {
                reps.append(rel) catch {};
                continue;
            };
            var lb: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fs.cwd().readLink(full, &lb)) |_| {
                reps.append(rel) catch {};
                continue;
            } else |_| {}
            const st = std.fs.cwd().statFile(full) catch {
                reps.append(rel) catch {};
                continue;
            };
            if (st.kind != .file or st.size == 0 or st.size > STREAM_THRESHOLD or rel.len >= container.MAX_PATH_LEN) {
                reps.append(rel) catch {};
                continue;
            }
            const f = std.fs.cwd().openFile(full, .{}) catch {
                reps.append(rel) catch {};
                continue;
            };
            defer f.close();
            const fdata = f.readToEndAlloc(root, STREAM_THRESHOLD) catch {
                reps.append(rel) catch {};
                continue;
            };
            defer root.free(fdata);
            const sh = sha256(fdata);
            if (seen.contains(sh)) {
                try dups.append(.{ .rel = rel, .sha = sh, .csum = container.fnv1a(fdata), .orig = fdata.len });
            } else {
                try seen.put(sh, {});
                try rep_path_to_sha.put(rel, sh);
                try reps.append(rel);
            }
        }
    }

    // Trained-dictionary pre-pass (serial): claim groups of similar small files
    // into shared-dict entries (cross-file sharing, still per-entry decodable).
    // `reps` slices are borrowed (owned by `jobs`), so dropping claimed ones is
    // just a filtered rebuild — no frees.
    {
        var claimed = std.AutoHashMap(usize, void).init(root);
        defer claimed.deinit();
        dictPrePass(root, dir_path, effort, &cb, reps.items, &claimed) catch {};
        if (claimed.count() > 0) {
            var survivors = std.ArrayList([]u8).init(root);
            for (reps.items, 0..) |rel, i| {
                if (!claimed.contains(i)) survivors.append(rel) catch {};
            }
            reps.deinit();
            reps = survivors;
        }
    }

    var ctx = PackCtx{
        .alloc = root,
        .base_dir = dir_path,
        .cb = &cb,
        .out = std.io.getStdOut().writer().any(),
        .cancel_flag = cancel_flag,
        .effort = effort,
    };

    // Parallel pass over representatives only.
    try runStreamJobsParallel(root, &ctx, reps.items, cancel_flag, progress_ptr, ticker_ptr);

    // Dedup post-pass: map each rep's content hash to the blob it was packed
    // into (by value, so appending below can't dangle it), then append a FAT
    // row per duplicate pointing at that shared blob — zero extra data bytes.
    if (dups.items.len > 0) {
        var meta = DedupMap.init(root);
        defer meta.deinit();
        for (cb.fat.items) |e| {
            if (rep_path_to_sha.get(e.getPath())) |sh| {
                meta.put(sh, .{ .offset = e.data_offset, .csize = e.compressed_size, .ctype = e.comp_type, .codec = e.codec, .solid_index = e.solid_index }) catch {};
            }
        }
        var deduped: u32 = 0;
        for (dups.items) |d| {
            if (meta.get(d.sha)) |v| {
                var fat = container.FatEntry{
                    .comp_type = v.ctype,
                    .solid_index = v.solid_index,
                    .data_offset = v.offset,
                    .original_size = d.orig,
                    .compressed_size = v.csize,
                    .checksum = d.csum,
                    .codec = v.codec,
                };
                fat.setPath(d.rel) catch continue;
                cb.appendDedup(fat) catch continue;
                deduped += 1;
            } else {
                // Rep wasn't packed (worker skip): pack the duplicate normally.
                var pb2: [std.fs.max_path_bytes]u8 = undefined;
                const full = std.fmt.bufPrint(&pb2, "{s}/{s}", .{ dir_path, d.rel }) catch continue;
                const f = std.fs.cwd().openFile(full, .{}) catch continue;
                defer f.close();
                const fdata = f.readToEndAlloc(root, STREAM_THRESHOLD) catch continue;
                defer root.free(fdata);
                _ = cb.addBinary(d.rel, fdata) catch continue;
            }
        }
        if (deduped > 0) {
            var mbuf: [64]u8 = undefined;
            const ml = std.fmt.bufPrint(&mbuf, "  DEDUP     {d} duplicate file(s) share blobs\n", .{deduped}) catch "";
            std.io.getStdOut().writeAll(ml) catch {};
        }
    }

    const out_file = try std.fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try cb.finish(out_file);
}

/// Pack an explicit selection (files and/or directories) into one archive using
/// the live (regular) per-entry path — the selection counterpart to
/// packDirectoryVfsAbi. Same dedup + dict pre-passes and per-entry random
/// access; no solid grouping.
pub fn packSelectionVfsAbi(
    root: std.mem.Allocator,
    base_dir: []const u8,
    selection: []const u8,
    out_path: []const u8,
    effort_tier: u8,
    cancel_flag: *const std.atomic.Value(u8),
    progress_ptr: *std.atomic.Value(f32),
    ticker_ptr: [*]u8,
) !void {
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

    try packJobsVfs(root, base_dir, jobs.items, out_path, effort_tier,
        cancel_flag, progress_ptr, ticker_ptr);
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
        _ = try ctx.scb.inner.addChunkedStreamingFile(rel_path, file, fsize);
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
    const effort = Effort.fromTierRegular(effort_tier);
    var cb = try container.SolidContainerBuilder.init(root);
    // Solid blocks stay on zstd even at Max: decompressSolidBlock only decodes
    // gzip/zstd, and solid blocks are the anti-live part anyway (whole-block
    // decode). The LZMA win goes to the live per-file entries via ctx.effort.
    cb.setCompressor(container.Compressor.fromTier(effort_tier));
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
    const effort = Effort.fromTierRegular(effort_tier);
    var cb = try container.SolidContainerBuilder.init(root);
    // Solid blocks stay zstd (decodable + anti-live); per-file entries get LZMA.
    cb.setCompressor(container.Compressor.fromTier(effort_tier));
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
    // transform entries pick zstd-or-lzma per file (keep-smaller), recorded in
    // each entry's codec byte.

    const Lifted = struct {
        comp_type: container.CompressionType,
        payload: []u8, // bytecode (math) or [params][compressed] (transform)
        size: u64,
        csum: u32,
        codec: container.Codec = .lzma, // codec of the compressed portion
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

                // (b) Structured-data transforms (2D image, columnar), fed the
                // LZMA backend and lifted out of the tar. The whole-tar LZMA
                // can't transpose or 2D-predict, so these win 40%+ on raster /
                // record data — and feeding the transform LZMA instead of zstd
                // recovers the ~9% the regular-mode zstd backend leaves behind.
                // Compress the transform with BOTH zstd and lzma and keep the
                // smaller (zstd occasionally beats lzma on residual streams), so
                // a lifted entry is never worse than regular mode's zstd. Lift
                // only when it beats plain compression of the file (so a flat
                // sprite the transform doesn't help stays in the tar).
                if (eff.tier >= 1) {
                    // At Max, also race the context-mixing codec on the residual
                    // (full/cold only — CM beats LZMA ~5-15% on decorrelated
                    // residuals). zstd/lzma kept for the live-tier and as floors.
                    const codecs: []const container.Compressor = if (eff.tier >= 2)
                        &.{ eff.comp, container.Compressor.lzmaFromTier(eff.tier), .{ .codec = .cm } }
                    else
                        &.{ eff.comp, container.Compressor.lzmaFromTier(eff.tier) };
                    var best: ?[]u8 = null;
                    var best_ct: container.CompressionType = .math_columnar;
                    var best_codec: container.Codec = .zstd;
                    // Try BOTH transforms with BOTH codecs and keep the overall
                    // smallest (image2D and columnar can each win on raster, and
                    // zstd sometimes beats lzma on residuals) — same candidate
                    // set regular mode considers, so full mode never loses to it.
                    for (codecs) |cmp| {
                        if (bestImage2DBlock(data, eff, cmp, aa) catch null) |p| {
                            if (best == null or p.len < best.?.len) {
                                best = p;
                                best_ct = .math_image2d;
                                best_codec = cmp.codec;
                            }
                        }
                        if (bestColumnarBlock(data, eff, cmp, aa) catch null) |p| {
                            if (best == null or p.len < best.?.len) {
                                best = p;
                                best_ct = .math_columnar;
                                best_codec = cmp.codec;
                            }
                        }
                        if (bestAudioBlock(data, eff, cmp, aa) catch null) |p| {
                            if (best == null or p.len < best.?.len) {
                                best = p;
                                best_ct = .math_audio;
                                best_codec = cmp.codec;
                            }
                        }
                    }
                    if (best) |payload| {
                        // Honesty: beat the best plain compression of the file.
                        const pl_z = (eff.comp.compress(data, aa) catch &[_]u8{}).len;
                        const pl_l = (container.lzmaCompress(data, aa, container.lzmaPreset(eff.tier)) catch &[_]u8{}).len;
                        const plain_min = @min(if (pl_z == 0) std.math.maxInt(usize) else pl_z, if (pl_l == 0) std.math.maxInt(usize) else pl_l);
                        if (payload.len < plain_min) {
                            const owned = alloc.dupe(u8, payload) catch return;
                            slot.* = .{ .comp_type = best_ct, .payload = owned, .size = size, .csum = csum, .codec = best_codec };
                            return;
                        }
                    }
                }
                // Executables are NOT lifted here: the whole tar is compressed
                // through liblzma's x86 BCJ filter chain (xz-grade, with solid
                // cross-file sharing), which beats per-file hand-rolled BCJ.
            }
        };
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{ .allocator = root, .n_jobs = @as(u32, @intCast(container.recommendedThreads())) });
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
    var tar_files: usize = 0; // non-lifted files that actually go in the tar
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
                tar_files += 1;
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
            tar_files += 1;

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
            .math_filtered, .math_columnar, .math_image2d, .math_audio, .math_float => {
                var fat = container.FatEntry{
                    .comp_type = hit.comp_type,
                    .data_offset = 0,
                    .original_size = hit.size,
                    .compressed_size = hit.payload.len,
                    .checksum = hit.csum,
                    .codec = hit.codec,
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

    // If every file was lifted (the tar holds no real files, just end markers),
    // skip the tar entry entirely — its overhead would make a pure-structured
    // archive larger than regular mode for no benefit. Unpack handles archives
    // with only lifted entries (no tar) transparently.
    const LZMA_TAR_CAP: u64 = 3 * 1024 * 1024 * 1024;
    if (tar_files == 0) {
        // nothing to add — all content rode as lifted entries
    } else if (tsize <= LZMA_TAR_CAP) {
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

        // COLD big-dictionary pass for large tars. preset-9 caps the LZMA window
        // at 64 MiB, but a multi-hundred-MB solid tar (e.g. a 961 MB game pak)
        // has matching content scattered far beyond that — a dictionary spanning
        // the whole input reaches it (measured −0.14% on FPS Chess's pak). Runs
        // AFTER the 64 MiB candidates above have freed their encoders, so peak
        // RAM stays bounded; dict capped at 512 MiB (~6 GB BT4 encoder). The .xz
        // block header self-describes the dict, so decode is unchanged. x86 BCJ
        // is applied only when the tar looks like code (it hurts opaque data).
        if (effort_tier == 2 and tsize > 128 * 1024 * 1024) {
            // 256 MiB dict (~2.7 GB BT4 encoder) — captures the long-range win
            // while staying safe on 8 GB-class machines; 512 MiB gained only a
            // further ~0.04% but needs ~5.5 GB (OOM-risky next to the 64 MiB
            // candidates + the in-memory tar).
            const BIGDICT_CAP: u32 = 256 * 1024 * 1024;
            const use_x86 = looksLikeX86(tar_data);
            if (container.lzmaCompressBigDict(tar_data, root, preset, BIGDICT_CAP, use_x86) catch null) |bd| {
                if (bd.len < comp.len) {
                    root.free(comp);
                    comp = bd;
                } else root.free(bd);
            }
        }

        // Backend race (Max only, mutually exclusive by content), keep smallest:
        //  - x86 code -> BCJ2 with CM main stream (allow_cm=true): the 4-stream
        //    filter + context-mixing the de-addressed code beats 7-Zip.
        //  - everything else -> whole-tar CM (beats LZMA on text by ~15%).
        // CM is ~0.2-0.4 MB/s, so it's full/cold only — speed is irrelevant for
        // cold storage, so the only real ceiling is RAM. The keep-smaller guard
        // means it can never lose to plain LZMA, so the only cost of trying it is
        // time + memory.
        //
        // The cap is a MEMORY bound, not a speed one. cm.compress holds the whole
        // input in one buffer (~1× input) plus ~190 MB of fixed model tables, and
        // the solid tar is already resident (~1× input), so peak ≈ 2× input +
        // 190 MB. A 1.5 GiB cap ⇒ ~3.2 GB peak for CM, safe alongside the BT4
        // optlzma encoder (run sequentially, so peak is max() not sum). This lifts
        // the old 96 MiB cap that silently denied CM to any large tar — e.g. a
        // ~961 MB game pak or a 100 MB+ text corpus got no CM at all. Inputs past
        // this need a blocked/streaming CM rewrite (tracked as future work) to keep
        // the whole-input buffer from dominating RAM.
        const cm = @import("cm.zig");
        const CM_CAP: u64 = 1536 * 1024 * 1024;
        const is_code = looksLikeX86(tar_data);
        const bcj2_block: ?[]u8 = if (effort_tier == 2 and is_code and tsize <= CM_CAP)
            (container.buildBcj2Block(tar_data, preset, true, root) catch null)
        else
            null;
        defer if (bcj2_block) |b| root.free(b);

        const cm_block: ?[]u8 = if (effort_tier == 2 and tsize <= CM_CAP and !is_code)
            (cm.compress(tar_data, root) catch null)
        else
            null;
        defer if (cm_block) |b| root.free(b);

        // Our pure-Zig multi-state LZMA — beats 7-Zip on opaque data. The cyclic
        // BT4 match finder keeps the son array at 2×dict (≈1 GB at a 128 MB dict)
        // regardless of tar size, so single-pass scales to ~1 GB tars without the
        // old 8×data blowup. Dedup-K=8 beats 7z ~3% at ~0.4 MB/s. COLD/Max only;
        // decodes via our own RangeDecoder (math_optlzma), no liblzma needed.
        // Single-pass preserves cross-chunk references (the win on referential
        // paks); chunking only kicks in past the single-pass cap, where memory
        // or time would otherwise be prohibitive.
        const OPTLZMA_SINGLE_CAP: u64 = 1024 * 1024 * 1024;
        const OPTLZMA_CHUNK_CAP: u64 = 8 * 1024 * 1024 * 1024;
        var optlzma_block: ?[]u8 = null;
        var optlzma_ct: container.CompressionType = .math_optlzma;
        if (effort_tier == 2) {
            const lzma_enc = @import("lzma_enc.zig");
            if (tsize <= OPTLZMA_SINGLE_CAP) {
                var kdict: u32 = 1 << 20;
                while (kdict < tar_data.len and kdict < (1 << 27)) kdict <<= 1;
                optlzma_block = lzma_enc.compressOptK(tar_data, root, .{ .dict_size = kdict, .nice_len = 273, .max_depth = 1024, .window = 1024, .kbest = 8 }) catch null;
                optlzma_ct = .math_optlzma;
            } else if (tsize <= OPTLZMA_CHUNK_CAP) {
                // Past the single-pass cap: parallel chunked multi-state. 128 MB
                // chunks match the dict window (cross-128 MB redundancy is rare),
                // so the multi-state win survives; bounds encode time to ~total/cores.
                optlzma_block = lzma_enc.compressOptKChunked(tar_data, root, 128 * 1024 * 1024, 8) catch null;
                optlzma_ct = .math_optlzma_chunked;
            }
        }
        defer if (optlzma_block) |b| root.free(b);

        // Pick the smallest representation across LZMA / BCJ2 / CM / multi-state.
        var best_block: []const u8 = comp;
        var best_ct: container.CompressionType = .fallback_stream;
        if (bcj2_block) |b| if (b.len < best_block.len) {
            best_block = b;
            best_ct = .math_bcj2;
        };
        if (cm_block) |b| if (b.len < best_block.len) {
            best_block = b;
            best_ct = .math_cm;
        };
        if (optlzma_block) |b| if (b.len < best_block.len) {
            best_block = b;
            best_ct = optlzma_ct;
        };

        // STORE guard: never let the wrapper inflate the tar.
        if (best_block.len < tar_data.len) {
            var fat = container.FatEntry{
                .comp_type = best_ct,
                .data_offset = 0,
                .original_size = tsize,
                .compressed_size = best_block.len,
                .checksum = csum,
                .codec = .lzma,
            };
            try fat.setPath("archive.tar");
            try cb.appendBlock(fat, best_block);
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

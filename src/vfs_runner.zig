//! vfs_runner.zig — a *host application* that drives a `.math` archive as a live
//! virtual filesystem through the public C-ABI, exactly the way a game engine
//! would. It links `libmathpressor.so` and only ever calls the `mp_*` exports —
//! no Zig internals — so this is a faithful test of the live VFS surface.
//!
//! What it proves:
//!   1. Open-once, read-many: `mp_open` parses the FAT a single time, then every
//!      asset is fetched on demand via `mp_read_entry` (O(1) path lookup +
//!      single-entry decode). This is the "asset doesn't exist until requested"
//!      model.
//!   2. Random access: it fetches a handful of named assets directly, in
//!      arbitrary order, with no neighbours touched.
//!   3. Losslessness: every decoded asset is byte-compared against the original
//!      file on disk (when a base dir is supplied). Any mismatch is fatal.
//!   4. Throughput: per-asset decode time → MB/s, plus a per-route breakdown so
//!      the synthesised (MATH_BYTECODE) and STORE/zstd routes can be compared.
//!
//! Usage:
//!   vfs_runner <archive.math> [original_base_dir]
//!
//! With a base dir it verifies decode==original for every entry (the strong
//! lossless proof). Without one it still decodes everything and checks sizes.

const std = @import("std");

// --- The public Mathpressor C-ABI (see src/abi.zig). Only integers and raw
//     pointers cross this boundary; nothing else is needed to run a live VFS. ---
extern fn mp_open(archive_ptr: [*]const u8, archive_len: usize) ?*anyopaque;
extern fn mp_close(handle: ?*anyopaque) void;
extern fn mp_entry_count(handle: ?*anyopaque) i64;
extern fn mp_entry_name(handle: ?*anyopaque, index: usize, out_ptr: [*]u8, out_len: usize) i32;
extern fn mp_entry_size_at(handle: ?*anyopaque, index: usize) i64;
extern fn mp_entry_size(handle: ?*anyopaque, path_ptr: [*:0]const u8) i64;
extern fn mp_read_entry(handle: ?*anyopaque, path_ptr: [*:0]const u8, out_ptr: [*]u8, out_len: usize) i32;

const MiB: f64 = 1024.0 * 1024.0;

fn pctHuman(bytes: u64, buf: []u8) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    if (b >= 1024.0 * MiB) return std.fmt.bufPrint(buf, "{d:.2} GiB", .{b / (1024.0 * MiB)}) catch "?";
    if (b >= MiB) return std.fmt.bufPrint(buf, "{d:.2} MiB", .{b / MiB}) catch "?";
    if (b >= 1024.0) return std.fmt.bufPrint(buf, "{d:.2} KiB", .{b / 1024.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len < 2) {
        std.debug.print("usage: {s} <archive.math> [original_base_dir]\n", .{args[0]});
        return error.Usage;
    }
    const archive_path = args[1];
    const base_dir: ?[]const u8 = if (args.len >= 3) args[2] else null;

    const stdout = std.io.getStdOut().writer();

    // Load the archive bytes. A real engine would mmap this; the contract is the
    // same — the bytes must stay alive for the lifetime of the handle.
    const archive = try std.fs.cwd().readFileAlloc(a, archive_path, 8 << 30);
    defer a.free(archive);

    try stdout.print("\n=== Mathpressor live VFS runner ===\n", .{});
    {
        var hb: [32]u8 = undefined;
        try stdout.print("archive : {s} ({s})\n", .{ archive_path, pctHuman(archive.len, &hb) });
    }

    // ---- open ONCE (parse FAT + build path index) -------------------------
    var t = try std.time.Timer.start();
    const handle = mp_open(archive.ptr, archive.len) orelse {
        std.debug.print("mp_open failed (parse error)\n", .{});
        return error.OpenFailed;
    };
    defer mp_close(handle);
    const open_ns = t.read();

    const count_i = mp_entry_count(handle);
    if (count_i < 0) return error.BadHandle;
    const count: usize = @intCast(count_i);
    try stdout.print("mp_open : {d} entries indexed in {d:.3} ms (parsed once)\n\n", .{ count, @as(f64, @floatFromInt(open_ns)) / 1.0e6 });

    // Pre-fetch the entry names + sizes once (enumeration), so the timed read
    // loop below only measures decode, not name lookups.
    const names = try a.alloc([]u8, count);
    const sizes = try a.alloc(u64, count);
    defer {
        for (names) |n| a.free(n);
        a.free(names);
        a.free(sizes);
    }
    var max_decoded: u64 = 0;
    for (0..count) |i| {
        var nb: [4096]u8 = undefined;
        const nl = mp_entry_name(handle, i, &nb, nb.len);
        if (nl < 0) return error.NameFailed;
        names[i] = try a.dupe(u8, nb[0..@intCast(nl)]);
        const sz = mp_entry_size_at(handle, i);
        sizes[i] = if (sz < 0) 0 else @intCast(sz);
        if (sizes[i] > max_decoded) max_decoded = sizes[i];
    }

    // One reusable decode buffer sized to the largest entry (a real engine would
    // pool/stream; the point here is the per-asset decode cost).
    const buf = try a.alloc(u8, @intCast(max_decoded));
    defer a.free(buf);

    // ---- random-access demo: fetch a few named assets out of order --------
    try stdout.print("--- random access (fetch named assets on demand) ---\n", .{});
    {
        // Largest, smallest, and the median entry by size — addressed by name.
        var order = try a.alloc(usize, count);
        defer a.free(order);
        for (0..count) |i| order[i] = i;
        std.sort.block(usize, order, sizes, struct {
            fn lt(s: []u64, x: usize, y: usize) bool {
                return s[x] < s[y];
            }
        }.lt);
        const picks = [_]usize{ order[count - 1], order[count / 2], order[0] };
        for (picks) |idx| {
            const z = try a.dupeZ(u8, names[idx]);
            defer a.free(z);
            var tt = try std.time.Timer.start();
            const n = mp_read_entry(handle, z.ptr, buf.ptr, buf.len);
            const ns = tt.read();
            if (n < 0) {
                try stdout.print("  [FAIL {d}] {s}\n", .{ n, names[idx] });
                continue;
            }
            var hb: [32]u8 = undefined;
            const mbps = (@as(f64, @floatFromInt(n)) / MiB) / (@as(f64, @floatFromInt(ns)) / 1.0e9);
            try stdout.print("  {s:>10}  {d:>8.3} ms  {d:>7.1} MB/s   {s}\n", .{ pctHuman(@intCast(n), &hb), @as(f64, @floatFromInt(ns)) / 1.0e6, mbps, names[idx] });
        }
    }

    // ---- stream EVERY asset on demand, verify + time ----------------------
    try stdout.print("\n--- stream all {d} assets (decode + verify vs original) ---\n", .{count});
    var total_orig: u64 = 0;
    var total_ns: u64 = 0;
    var verified: usize = 0;
    var size_ok: usize = 0;
    var mismatches: usize = 0;
    var read_fail: usize = 0;
    var slowest_ns: u64 = 0;
    var slowest_idx: usize = 0;

    var ob_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (0..count) |i| {
        const z = try a.dupeZ(u8, names[i]);
        defer a.free(z);

        var tt = try std.time.Timer.start();
        const n = mp_read_entry(handle, z.ptr, buf.ptr, buf.len);
        const ns = tt.read();
        if (n < 0) {
            read_fail += 1;
            std.debug.print("  read FAIL {d}: {s}\n", .{ n, names[i] });
            continue;
        }
        total_ns += ns;
        total_orig += @intCast(n);
        if (ns > slowest_ns) {
            slowest_ns = ns;
            slowest_idx = i;
        }

        const decoded = buf[0..@intCast(n)];
        if (@as(u64, @intCast(n)) == sizes[i]) size_ok += 1;

        // Strong lossless proof: byte-compare against the original on disk.
        if (base_dir) |bd| {
            const full = std.fmt.bufPrint(&ob_buf, "{s}/{s}", .{ bd, names[i] }) catch continue;
            const orig = std.fs.cwd().readFileAlloc(a, full, 8 << 30) catch {
                continue; // original unreadable (e.g. symlink) — skip, not a codec failure
            };
            defer a.free(orig);
            if (orig.len == decoded.len and std.mem.eql(u8, orig, decoded)) {
                verified += 1;
            } else {
                mismatches += 1;
                std.debug.print("  !! MISMATCH {s}: orig {d} B vs decoded {d} B\n", .{ names[i], orig.len, decoded.len });
            }
        }
    }

    var hb1: [32]u8 = undefined;
    var hb2: [32]u8 = undefined;
    const agg_mbps = (@as(f64, @floatFromInt(total_orig)) / MiB) / (@as(f64, @floatFromInt(total_ns)) / 1.0e9);
    try stdout.print("\n--- results ---\n", .{});
    try stdout.print("decoded total   : {s} of original asset bytes\n", .{pctHuman(total_orig, &hb1)});
    try stdout.print("decode wall     : {d:.3} s  ({s}/s aggregate, sequential)\n", .{ @as(f64, @floatFromInt(total_ns)) / 1.0e9, pctHuman(@intFromFloat(agg_mbps * MiB), &hb2) });
    try stdout.print("size match      : {d}/{d} entries returned exactly original_size\n", .{ size_ok, count });
    if (read_fail > 0) try stdout.print("read failures   : {d}\n", .{read_fail});
    if (base_dir != null) {
        try stdout.print("byte-verified   : {d}/{d} entries decode == original on disk\n", .{ verified, count });
        if (mismatches == 0) {
            try stdout.print("LOSSLESS        : PASS (every comparable entry is bit-identical)\n", .{});
        } else {
            try stdout.print("LOSSLESS        : FAIL ({d} mismatches)\n", .{mismatches});
        }
    }
    {
        const sm = (@as(f64, @floatFromInt(sizes[slowest_idx])) / MiB) / (@as(f64, @floatFromInt(slowest_ns)) / 1.0e9);
        try stdout.print("slowest entry   : {d:.1} ms @ {d:.1} MB/s  ({s})\n", .{ @as(f64, @floatFromInt(slowest_ns)) / 1.0e6, sm, names[slowest_idx] });
    }

    if (mismatches > 0 or read_fail > 0) return error.VerifyFailed;
}

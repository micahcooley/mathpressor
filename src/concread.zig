//! concread.zig — concurrent read benchmark. Issues `count` scattered 4 KB reads
//! at 4 MB-chunk boundaries across `threads` threads (like a game's async asset
//! loader), measuring wall time. Run against the native pak file and the
//! mathfs-mounted pak to see the parallel-decode speedup.
//!
//! usage: concread <file> <threads> <count>

const std = @import("std");

const CHUNK: u64 = 4 * 1024 * 1024;

const Job = struct {
    file: std.fs.File,
    offsets: []const u64,
    next: *std.atomic.Value(usize),
};

fn worker(job: *Job) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const i = job.next.fetchAdd(1, .monotonic);
        if (i >= job.offsets.len) break;
        _ = job.file.preadAll(&buf, job.offsets[i]) catch {};
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 4) {
        std.debug.print("usage: {s} <file> <threads> <count>\n", .{args[0]});
        return error.Usage;
    }
    const path = args[1];
    const threads = try std.fmt.parseInt(usize, args[2], 10);
    const count = try std.fmt.parseInt(usize, args[3], 10);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = (try file.stat()).size;
    const nchunks = size / CHUNK;

    // `count` distinct, scattered chunk offsets (×7 mod nchunks).
    const offsets = try a.alloc(u64, count);
    for (0..count) |i| offsets[i] = ((@as(u64, i) * 7) % nchunks) * CHUNK;

    var next = std.atomic.Value(usize).init(0);
    var job = Job{ .file = file, .offsets = offsets, .next = &next };

    var timer = try std.time.Timer.start();
    const ts = try a.alloc(std.Thread, threads);
    for (ts) |*t| t.* = try std.Thread.spawn(.{}, worker, .{&job});
    for (ts) |t| t.join();
    const ns = timer.read();

    std.debug.print("{d:.3}\n", .{@as(f64, @floatFromInt(ns)) / 1.0e9});
}

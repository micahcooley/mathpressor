//! mathfs.zig — a read-only FUSE filesystem that serves a directory tree by
//! reaching INTO a compressed Mathpressor `.math` archive and decoding only the
//! bytes each read touches — never the whole file, never to disk.
//!
//! The archive stays compressed on disk (e.g. 320 MB); when a host (a Proton
//! game) reads a region of a file, mathfs decodes just the covering 4 MB
//! chunk(s) in RAM and serves the bytes. To make this indistinguishable from
//! native it runs a concurrent cache engine:
//!   * chunk decodes happen OUTSIDE the global lock (refcounted entries), so
//!     many cores decode at once when the game issues concurrent reads;
//!   * a pool of PREFETCH workers decodes chunks just ahead of the read head,
//!     hiding decode latency on the sequential runs that make up an asset load;
//!   * a large RAM LRU keeps the working set warm so revisits are instant.
//! Nothing is ever inflated to its full size on disk.
//!
//! Links libfuse3 + the Mathpressor C-ABI (mp_open / mp_entry_chunk_size /
//! mp_read_chunk / mp_read_entry). No engine internals.
//!
//! Usage:  mathfs <archive.math> <mountpoint> [--cache-mb N] [fuse opts]
//! Unmount with `fusermount3 -u <mountpoint>`.

const std = @import("std");

const c = @cImport({
    @cDefine("FUSE_USE_VERSION", "31");
    @cDefine("_FILE_OFFSET_BITS", "64");
    @cInclude("fuse3/fuse.h");
    @cInclude("errno.h");
});

// --- Mathpressor public C-ABI (src/abi.zig) ---
extern fn mp_open(archive_ptr: [*]const u8, archive_len: usize) ?*anyopaque;
extern fn mp_close(handle: ?*anyopaque) void;
extern fn mp_entry_count(handle: ?*anyopaque) i64;
extern fn mp_entry_name(handle: ?*anyopaque, index: usize, out_ptr: [*]u8, out_len: usize) i32;
extern fn mp_entry_size_at(handle: ?*anyopaque, index: usize) i64;
extern fn mp_read_entry(handle: ?*anyopaque, path_ptr: [*:0]const u8, out_ptr: [*]u8, out_len: usize) i32;
extern fn mp_entry_chunk_size(handle: ?*anyopaque, path_ptr: [*:0]const u8) i64;
extern fn mp_read_chunk(handle: ?*anyopaque, path_ptr: [*:0]const u8, chunk_index: u32, out_ptr: [*]u8, out_len: usize) i32;

const Node = struct {
    is_dir: bool,
    size: u64 = 0,
    children: std.StringHashMap(void),
};

// Heap-allocated so the pointer stays stable across map rehashes; `refs` pins it
// against eviction while a reader is copying out of it.
const ChunkVal = struct { bytes: []u8, seq: u64, refs: u32 };

const PrefetchReq = struct { rel: []u8, idx: u32, cs: u32, orig: u64 };

const State = struct {
    alloc: std.mem.Allocator,
    archive: []const u8,
    handle: *anyopaque,
    nodes: std.StringHashMap(*Node), // built once, read-only after → no lock

    mu: std.Thread.Mutex = .{},
    file_cache: std.StringHashMap([]u8), // small/non-chunked entries (never evicted)
    chunk_cache: std.StringHashMap(*ChunkVal),
    chunk_size_of: std.StringHashMap(i64),
    last_chunk: std.StringHashMap(u32), // path -> last chunk read (sequential detection)
    cache_bytes: usize = 0,
    cache_cap: usize = 1024 * 1024 * 1024,
    seq: u64 = 0,

    // prefetch
    pf_mu: std.Thread.Mutex = .{},
    pf_cond: std.Thread.Condition = .{},
    pf_queue: std.ArrayList(PrefetchReq) = undefined,
    pf_inflight: std.AutoHashMap(u64, void) = undefined,
    pf_depth: u32 = 6, // chunks to read ahead of the read head
    pf_qcap: usize = 256,

    decode_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    decode_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

var g: *State = undefined;

fn keyHash(rel: []const u8, idx: u32) u64 {
    var h = std.hash.Wyhash.init(0x9E37);
    h.update(rel);
    h.update(std.mem.asBytes(&idx));
    return h.final();
}

// ===========================================================================
// tree
// ===========================================================================
fn ensureDir(rel: []const u8) *Node {
    if (g.nodes.get(rel)) |n| return n;
    const n = g.alloc.create(Node) catch unreachable;
    n.* = .{ .is_dir = true, .children = std.StringHashMap(void).init(g.alloc) };
    const key = g.alloc.dupe(u8, rel) catch unreachable;
    g.nodes.put(key, n) catch unreachable;
    return n;
}

fn addChild(dir: *Node, name: []const u8) void {
    if (dir.children.contains(name)) return;
    const k = g.alloc.dupe(u8, name) catch unreachable;
    dir.children.put(k, {}) catch unreachable;
}

fn buildTree() !void {
    _ = ensureDir("");
    const count: usize = @intCast(mp_entry_count(g.handle));
    var nb: [4096]u8 = undefined;
    for (0..count) |i| {
        const nl = mp_entry_name(g.handle, i, &nb, nb.len);
        if (nl < 0) continue;
        const path = nb[0..@intCast(nl)];
        const sz: u64 = blk: {
            const s = mp_entry_size_at(g.handle, i);
            break :blk if (s < 0) 0 else @intCast(s);
        };
        var parent: []const u8 = "";
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |comp| {
            if (comp.len == 0) continue;
            const is_last = it.rest().len == 0;
            addChild(ensureDir(parent), comp);
            if (is_last) {
                const fnode = g.alloc.create(Node) catch unreachable;
                fnode.* = .{ .is_dir = false, .size = sz, .children = std.StringHashMap(void).init(g.alloc) };
                const key = g.alloc.dupe(u8, path) catch unreachable;
                g.nodes.put(key, fnode) catch unreachable;
            } else {
                const dir_rel = path[0 .. (@intFromPtr(comp.ptr) - @intFromPtr(path.ptr)) + comp.len];
                _ = ensureDir(dir_rel);
                parent = dir_rel;
            }
        }
    }
}

fn relFromPath(path: [*c]const u8) []const u8 {
    const s = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(path)), 0);
    if (s.len == 0) return "";
    if (s[0] == '/') return s[1..];
    return s;
}

// ===========================================================================
// cache engine
// ===========================================================================
fn chunkSizeOf(rel: []const u8) i64 {
    g.mu.lock();
    if (g.chunk_size_of.get(rel)) |v| {
        g.mu.unlock();
        return v;
    }
    g.mu.unlock();
    const z = g.alloc.dupeZ(u8, rel) catch return 0;
    defer g.alloc.free(z);
    const cs = mp_entry_chunk_size(g.handle, z.ptr);
    const v: i64 = if (cs < 0) 0 else cs;
    g.mu.lock();
    if (!g.chunk_size_of.contains(rel)) {
        const key = g.alloc.dupe(u8, rel) catch {
            g.mu.unlock();
            return v;
        };
        g.chunk_size_of.put(key, v) catch {};
    }
    g.mu.unlock();
    return v;
}

/// Evict least-recently-used unpinned chunks until under the cap. Holds g.mu.
fn evictLocked() void {
    while (g.cache_bytes > g.cache_cap) {
        var min_seq: u64 = std.math.maxInt(u64);
        var victim: ?[]const u8 = null;
        var it = g.chunk_cache.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*.refs == 0 and e.value_ptr.*.seq < min_seq) {
                min_seq = e.value_ptr.*.seq;
                victim = e.key_ptr.*;
            }
        }
        const vkey = victim orelse break; // everything pinned → stop
        if (g.chunk_cache.fetchRemove(vkey)) |kv| {
            g.cache_bytes -= kv.value.bytes.len;
            g.alloc.free(kv.value.bytes);
            g.alloc.destroy(kv.value);
            g.alloc.free(kv.key);
        } else break;
    }
}

/// Acquire a decoded chunk, PINNED (refs incremented). Decodes outside the lock
/// so concurrent acquisitions of different chunks run on different cores. Caller
/// must `releaseChunk` when done copying. Returns null on decode error.
fn acquireChunk(rel: []const u8, idx: u32, cs: u32, orig: u64) ?*ChunkVal {
    var kb: [4300]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "{s}\x00{d}", .{ rel, idx }) catch return null;

    g.mu.lock();
    if (g.chunk_cache.get(key)) |cv| {
        cv.refs += 1;
        g.seq += 1;
        cv.seq = g.seq;
        g.mu.unlock();
        return cv;
    }
    g.mu.unlock();

    // Decode this one chunk from the archive (no lock held → parallel).
    const this_usize: usize = @intCast(@min(@as(u64, cs), orig - @as(u64, idx) * cs));
    const buf = g.alloc.alloc(u8, this_usize) catch return null;
    const z = g.alloc.dupeZ(u8, rel) catch {
        g.alloc.free(buf);
        return null;
    };
    var timer = std.time.Timer.start() catch unreachable;
    const n = mp_read_chunk(g.handle, z.ptr, idx, buf.ptr, buf.len);
    const ns = timer.read();
    g.alloc.free(z);
    if (n < 0) {
        g.alloc.free(buf);
        return null;
    }
    _ = g.decode_count.fetchAdd(1, .monotonic);
    _ = g.decode_ns.fetchAdd(ns, .monotonic);

    const cv = g.alloc.create(ChunkVal) catch {
        g.alloc.free(buf);
        return null;
    };
    cv.* = .{ .bytes = buf[0..@intCast(n)], .seq = 0, .refs = 1 };

    g.mu.lock();
    if (g.chunk_cache.get(key)) |existing| { // lost the race
        existing.refs += 1;
        g.seq += 1;
        existing.seq = g.seq;
        g.mu.unlock();
        g.alloc.free(buf);
        g.alloc.destroy(cv);
        return existing;
    }
    const ck = g.alloc.dupe(u8, key) catch {
        g.mu.unlock();
        g.alloc.free(buf);
        g.alloc.destroy(cv);
        return null;
    };
    g.seq += 1;
    cv.seq = g.seq;
    g.chunk_cache.put(ck, cv) catch {
        g.mu.unlock();
        g.alloc.free(ck);
        g.alloc.free(buf);
        g.alloc.destroy(cv);
        return null;
    };
    g.cache_bytes += @intCast(n);
    evictLocked();
    g.mu.unlock();
    return cv;
}

fn releaseChunk(cv: *ChunkVal) void {
    g.mu.lock();
    if (cv.refs > 0) cv.refs -= 1;
    g.mu.unlock();
}

/// Queue read-ahead of chunks [start, start+depth) for the prefetch workers.
fn enqueuePrefetch(rel: []const u8, start: u32, cs: u32, orig: u64, num_chunks: u32) void {
    var d: u32 = 0;
    while (d < g.pf_depth) : (d += 1) {
        const idx2 = start + d;
        if (idx2 >= num_chunks) break;
        var kb: [4300]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{s}\x00{d}", .{ rel, idx2 }) catch continue;
        // Skip if already resident (quick check, no nested lock with pf_mu).
        g.mu.lock();
        const cached = g.chunk_cache.contains(key);
        g.mu.unlock();
        if (cached) continue;
        const h = keyHash(rel, idx2);
        g.pf_mu.lock();
        if (g.pf_inflight.contains(h) or g.pf_queue.items.len >= g.pf_qcap) {
            g.pf_mu.unlock();
            continue;
        }
        const rel_dup = g.alloc.dupe(u8, rel) catch {
            g.pf_mu.unlock();
            continue;
        };
        g.pf_queue.append(.{ .rel = rel_dup, .idx = idx2, .cs = cs, .orig = orig }) catch {
            g.alloc.free(rel_dup);
            g.pf_mu.unlock();
            continue;
        };
        g.pf_inflight.put(h, {}) catch {};
        g.pf_cond.signal();
        g.pf_mu.unlock();
    }
}

/// Periodic stats line so a watcher can see decode activity live (cheap; once/2s).
fn statsThread() void {
    var last: u64 = 0;
    while (true) {
        std.time.sleep(2 * std.time.ns_per_s);
        const dc = g.decode_count.load(.monotonic);
        if (dc == last) continue;
        last = dc;
        g.mu.lock();
        const mb = g.cache_bytes / (1024 * 1024);
        g.mu.unlock();
        std.debug.print("STAT decodes={d} cache={d}MB\n", .{ dc, mb });
    }
}

fn prefetchWorker() void {
    while (true) {
        g.pf_mu.lock();
        while (g.pf_queue.items.len == 0) g.pf_cond.wait(&g.pf_mu);
        const req = g.pf_queue.orderedRemove(0);
        g.pf_mu.unlock();

        const cv = acquireChunk(req.rel, req.idx, req.cs, req.orig);
        if (cv) |c2| releaseChunk(c2); // just warm the cache

        const h = keyHash(req.rel, req.idx);
        g.pf_mu.lock();
        _ = g.pf_inflight.remove(h);
        g.pf_mu.unlock();
        g.alloc.free(req.rel);
    }
}

/// Whole-file decode for non-chunked entries (cached forever; small files).
fn getWhole(rel: []const u8, size: u64) ?[]const u8 {
    g.mu.lock();
    if (g.file_cache.get(rel)) |v| {
        g.mu.unlock();
        return v;
    }
    g.mu.unlock();
    const buf = g.alloc.alloc(u8, @intCast(size)) catch return null;
    const z = g.alloc.dupeZ(u8, rel) catch {
        g.alloc.free(buf);
        return null;
    };
    const n = mp_read_entry(g.handle, z.ptr, buf.ptr, buf.len);
    g.alloc.free(z);
    if (n < 0) {
        g.alloc.free(buf);
        return null;
    }
    g.mu.lock();
    if (g.file_cache.get(rel)) |v| { // raced
        g.mu.unlock();
        g.alloc.free(buf);
        return v;
    }
    const key = g.alloc.dupe(u8, rel) catch {
        g.mu.unlock();
        return buf[0..@intCast(n)];
    };
    g.file_cache.put(key, buf[0..@intCast(n)]) catch {};
    g.mu.unlock();
    return buf[0..@intCast(n)];
}

// ===========================================================================
// FUSE operations
// ===========================================================================
fn opGetattr(path: [*c]const u8, st: [*c]c.struct_stat, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const rel = relFromPath(path);
    const node = g.nodes.get(rel) orelse return -@as(c_int, c.ENOENT);
    st.* = std.mem.zeroes(c.struct_stat);
    if (node.is_dir) {
        st.*.st_mode = @intCast(c.S_IFDIR | @as(c_int, 0o555));
        st.*.st_nlink = 2;
    } else {
        st.*.st_mode = @intCast(c.S_IFREG | @as(c_int, 0o555));
        st.*.st_nlink = 1;
        st.*.st_size = @intCast(node.size);
    }
    return 0;
}

fn opReaddir(
    path: [*c]const u8,
    buf: ?*anyopaque,
    filler: c.fuse_fill_dir_t,
    offset: c.off_t,
    fi: ?*c.struct_fuse_file_info,
    flags: c.enum_fuse_readdir_flags,
) callconv(.c) c_int {
    _ = offset;
    _ = fi;
    _ = flags;
    const rel = relFromPath(path);
    const node = g.nodes.get(rel) orelse return -@as(c_int, c.ENOENT);
    if (!node.is_dir) return -@as(c_int, c.ENOTDIR);
    const fill = filler orelse return -@as(c_int, c.EIO);
    _ = fill(buf, ".", null, 0, 0);
    _ = fill(buf, "..", null, 0, 0);
    var it = node.children.keyIterator();
    while (it.next()) |k| {
        var nb: [4096]u8 = undefined;
        const name = k.*;
        if (name.len >= nb.len) continue;
        @memcpy(nb[0..name.len], name);
        nb[name.len] = 0;
        if (fill(buf, &nb, null, 0, 0) != 0) break;
    }
    return 0;
}

fn opOpen(path: [*c]const u8, fi: ?*c.struct_fuse_file_info) callconv(.c) c_int {
    _ = fi;
    const rel = relFromPath(path);
    const node = g.nodes.get(rel) orelse return -@as(c_int, c.ENOENT);
    if (node.is_dir) return -@as(c_int, c.EISDIR);
    return 0;
}

fn opRead(
    path: [*c]const u8,
    buf: [*c]u8,
    size: usize,
    offset: c.off_t,
    fi: ?*c.struct_fuse_file_info,
) callconv(.c) c_int {
    _ = fi;
    const rel = relFromPath(path);
    const node = g.nodes.get(rel) orelse return -@as(c_int, c.ENOENT);
    if (node.is_dir) return -@as(c_int, c.EISDIR);
    const off: u64 = @intCast(offset);
    if (off >= node.size) return 0;
    const want = @min(size, node.size - off);
    const dst = buf[0..want];

    const cs64 = chunkSizeOf(rel);
    if (cs64 == 0) {
        const whole = getWhole(rel, node.size) orelse return -@as(c_int, c.EIO);
        if (off >= whole.len) return 0;
        const end = @min(whole.len, off + want);
        const nbytes = end - off;
        @memcpy(dst[0..nbytes], whole[@intCast(off)..@intCast(end)]);
        return @intCast(nbytes);
    }

    const cs: u32 = @intCast(cs64);
    const num_chunks: u32 = @intCast((node.size + cs - 1) / cs);
    var produced: usize = 0;
    while (produced < want) {
        const cur = off + produced;
        const idx: u32 = @intCast(cur / cs);
        const cv = acquireChunk(rel, idx, cs, node.size) orelse {
            if (produced > 0) break;
            return -@as(c_int, c.EIO);
        };
        const in_chunk: usize = @intCast(cur % cs);
        if (in_chunk >= cv.bytes.len) {
            releaseChunk(cv);
            break;
        }
        const n = @min(cv.bytes.len - in_chunk, want - produced);
        @memcpy(dst[produced .. produced + n], cv.bytes[in_chunk .. in_chunk + n]); // cv pinned → safe
        releaseChunk(cv);
        produced += n;
        if (n == 0) break;
    }
    // Adaptive read-ahead: only prefetch when this read CONTINUES a sequential
    // run for this file. Scattered jumps (a menu pulling unrelated assets) then
    // pay nothing for wasted readahead, while a sequential asset load gets its
    // upcoming chunks decoded in the background. Detection is a per-file
    // last-chunk marker (heuristic, race-tolerant).
    const first_idx: u32 = @intCast(off / cs);
    const last_idx: u32 = @intCast((off + want - 1) / cs);
    var sequential = false;
    g.mu.lock();
    if (g.last_chunk.get(rel)) |prev| {
        sequential = (first_idx >= prev and first_idx <= prev + 1);
    }
    if (g.last_chunk.getPtr(rel)) |p| {
        p.* = last_idx;
    } else if (g.alloc.dupe(u8, rel)) |k| {
        g.last_chunk.put(k, last_idx) catch {};
    } else |_| {}
    g.mu.unlock();
    if (sequential) enqueuePrefetch(rel, last_idx + 1, cs, node.size, num_chunks);
    return @intCast(produced);
}

var ops: c.struct_fuse_operations = undefined;

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    var arg_it = try std.process.argsWithAllocator(gpa);
    defer arg_it.deinit();
    const prog = arg_it.next() orelse "mathfs";

    var archive_path: ?[]const u8 = null;
    var mountpoint: ?[]const u8 = null;
    var cache_mb: usize = 1024;
    var pf_workers: usize = 6;
    var fuse_args = std.ArrayList([]const u8).init(gpa);
    try fuse_args.append(prog);
    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "--cache-mb")) {
            cache_mb = std.fmt.parseInt(usize, arg_it.next() orelse "1024", 10) catch 1024;
        } else if (std.mem.eql(u8, a, "--prefetch")) {
            pf_workers = std.fmt.parseInt(usize, arg_it.next() orelse "6", 10) catch 6;
        } else if (std.mem.eql(u8, a, "--cache-dir")) {
            _ = arg_it.next(); // accepted for compat, unused
        } else if (a.len > 0 and a[0] == '-') {
            try fuse_args.append(a);
        } else if (archive_path == null) {
            archive_path = a;
        } else if (mountpoint == null) {
            mountpoint = a;
        } else {
            try fuse_args.append(a);
        }
    }
    const apath = archive_path orelse {
        std.debug.print("usage: {s} <archive.math> <mountpoint> [--cache-mb N] [--prefetch N] [fuse opts]\n", .{prog});
        return error.Usage;
    };
    const mp = mountpoint orelse return error.Usage;
    try fuse_args.append(mp);

    const af = try std.fs.cwd().openFile(apath, .{});
    const flen = (try af.stat()).size;
    const archive = try std.posix.mmap(null, flen, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, af.handle, 0);
    af.close();

    const handle = mp_open(archive.ptr, archive.len) orelse {
        std.debug.print("mp_open failed\n", .{});
        return error.OpenFailed;
    };

    g = try gpa.create(State);
    g.* = .{
        .alloc = gpa,
        .archive = archive,
        .handle = handle,
        .nodes = std.StringHashMap(*Node).init(gpa),
        .file_cache = std.StringHashMap([]u8).init(gpa),
        .chunk_cache = std.StringHashMap(*ChunkVal).init(gpa),
        .chunk_size_of = std.StringHashMap(i64).init(gpa),
        .last_chunk = std.StringHashMap(u32).init(gpa),
        .cache_cap = cache_mb * 1024 * 1024,
        .pf_queue = std.ArrayList(PrefetchReq).init(gpa),
        .pf_inflight = std.AutoHashMap(u64, void).init(gpa),
    };
    try buildTree();

    var w: usize = 0;
    while (w < pf_workers) : (w += 1) {
        const t = try std.Thread.spawn(.{}, prefetchWorker, .{});
        t.detach();
    }
    (std.Thread.spawn(.{}, statsThread, .{}) catch unreachable).detach();

    std.debug.print("mathfs: mounted {s} at {s} ({d} entries, {d} MB cache, {d} prefetch workers)\n", .{ apath, mp, mp_entry_count(handle), cache_mb, pf_workers });

    ops = std.mem.zeroes(c.struct_fuse_operations);
    ops.getattr = opGetattr;
    ops.readdir = opReaddir;
    ops.open = opOpen;
    ops.read = opRead;

    var cargv = try gpa.alloc([*c]u8, fuse_args.items.len);
    for (fuse_args.items, 0..) |s, i| {
        cargv[i] = try gpa.dupeZ(u8, s);
    }
    const rc = c.fuse_main_real(@intCast(cargv.len), @ptrCast(cargv.ptr), &ops, @sizeOf(c.struct_fuse_operations), null);
    mp_close(handle);
    std.process.exit(@intCast(rc));
}

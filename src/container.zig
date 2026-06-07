//! container.zig — The .math unified archive container.
//!
//! A .math file is a binary archive that holds four kinds of entries:
//!
//!   MATH_BYTECODE   — a Mathpressor program (tens of bytes) that the VM
//!                     synthesises into the full asset at runtime.
//!   FALLBACK_STREAM — the original bytes, gzip-compressed, for data that
//!                     cannot be represented as a mathematical program.
//!   STORE           — the original bytes verbatim, for data where gzip would
//!                     inflate the output (encrypted, random, already-compressed).
//!                     The STORE guard fires automatically in addBinary().
//!   MATH_RESIDUAL   — a Mathpressor approximation + gzip-compressed residual
//!                     delta.  The block layout inside the data region is:
//!                       [u8:  bytecode_len]
//!                       [bytecode_len bytes: bytecode]
//!                       [u64 le: gz_delta_len]
//!                       [gz_delta_len bytes: gzip-compressed delta]
//!                     Reconstruction: vm_out[i] +% delta[i] == original[i].
//!                     The delta has many zero bytes (exact-match positions),
//!                     so gzip shrinks it substantially.
//!
//! To the caller (the VFS, Steam, etc.) all four look identical: give me
//! bytes for path X, get back the original bytes. The routing is invisible.
//!
//! Wire layout
//! ───────────
//!   [12 B]              Container header
//!   [280 B × N]         File Allocation Table (FAT)
//!   [variable]          Data region — math programs or gzip blocks
//!
//! Header (12 bytes, all integers little-endian):
//!   magic[4]     = "MATH"
//!   version u16  = 1
//!   fat_count u32
//!   reserved u16 = 0
//!
//! FAT entry (280 bytes):
//!   path[240]          null-terminated UTF-8 relative path
//!   comp_type u8       0x01=MathBytecode, 0x02=FallbackStream,
//!                      0x03=Store, 0x04=MathResidual
//!   _pad[7]
//!   data_offset u64    offset from start of data region
//!   original_size u64  uncompressed byte count
//!   compressed_size u64 size of stored block (total, including any framing)
//!   checksum u32       FNV-1a of the ORIGINAL uncompressed data
//!   _pad2[4]

const std = @import("std");
const vm_mod = @import("vm.zig");
const gip = @import("gip_interface.zig");

// ---------------------------------------------------------------------------
// Format constants
// ---------------------------------------------------------------------------

const MAGIC = "MATH";
const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 12;
pub const FAT_ENTRY_SIZE: usize = 280;

pub const MAX_PATH_LEN: usize = 240;

pub const CompressionType = enum(u8) {
    math_bytecode   = 0x01,
    fallback_stream = 0x02, // gzip-compressed block
    store           = 0x03, // raw bytes — gzip STORE guard fired
    math_residual   = 0x04, // approximate program + gzip-compressed delta
};

// ---------------------------------------------------------------------------
// FAT entry (in-memory representation)
// ---------------------------------------------------------------------------

pub const FatEntry = struct {
    /// Relative path, max 239 chars + null.
    path: [MAX_PATH_LEN]u8 = std.mem.zeroes([MAX_PATH_LEN]u8),
    comp_type: CompressionType,
    /// Byte offset from the start of the data region.
    data_offset: u64,
    original_size: u64,
    compressed_size: u64,
    /// FNV-1a of the original uncompressed bytes.
    checksum: u32,

    pub fn setPath(self: *FatEntry, p: []const u8) void {
        const n = @min(p.len, MAX_PATH_LEN - 1);
        @memcpy(self.path[0..n], p[0..n]);
        self.path[n] = 0;
    }

    pub fn getPath(self: *const FatEntry) []const u8 {
        return std.mem.sliceTo(&self.path, 0);
    }
};

// ---------------------------------------------------------------------------
// Container builder
// ---------------------------------------------------------------------------

/// Accumulate entries then call `write` to serialise the whole archive.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(BuildEntry),

    const BuildEntry = struct {
        fat: FatEntry,
        /// Compressed data block (math bytecode OR gzip-compressed bytes).
        data: []const u8,
    };

    pub fn init(a: std.mem.Allocator) Builder {
        return .{ .allocator = a, .entries = std.ArrayList(BuildEntry).init(a) };
    }

    pub fn deinit(self: *Builder) void {
        for (self.entries.items) |e| self.allocator.free(e.data);
        self.entries.deinit();
    }

    /// Add a math-bytecode entry. `bytecode` is duped internally.
    pub fn addMath(
        self: *Builder,
        path: []const u8,
        bytecode: []const u8,
        original_size: u64,
        checksum: u32,
    ) !void {
        var fat = FatEntry{
            .comp_type = .math_bytecode,
            .data_offset = 0,
            .original_size = original_size,
            .compressed_size = bytecode.len,
            .checksum = checksum,
        };
        fat.setPath(path);
        try self.entries.append(.{
            .fat = fat,
            .data = try self.allocator.dupe(u8, bytecode),
        });
    }

    /// Add a fallback-stream entry. `compressed` must already be gzip data;
    /// it is duped internally.
    pub fn addFallback(
        self: *Builder,
        path: []const u8,
        compressed: []const u8,
        original_size: u64,
        checksum: u32,
    ) !void {
        var fat = FatEntry{
            .comp_type = .fallback_stream,
            .data_offset = 0,
            .original_size = original_size,
            .compressed_size = compressed.len,
            .checksum = checksum,
        };
        fat.setPath(path);
        try self.entries.append(.{
            .fat = fat,
            .data = try self.allocator.dupe(u8, compressed),
        });
    }

    /// Routing decision returned by addBinary — lets callers log what happened.
    pub const StorageDecision = struct {
        comp_type: CompressionType,
        /// Bytes actually written into the container for this entry.
        stored_size: usize,
        /// True when gzip output was ≥ raw size and the STORE guard fired.
        guard_fired: bool,
        /// How many bytes gzip would have cost (only meaningful when guard_fired).
        gzip_would_have_been: usize,
    };

    /// Smart binary entry: tries gzip, falls back to raw STORE if gzip inflates.
    ///
    /// This is the STORE guard. It guarantees the container never wastes bytes
    /// on compression that makes things worse — compressed data (zips, jpegs,
    /// encrypted blobs) always stored verbatim, structured data gzip-compressed.
    /// Caller provides raw uncompressed data; the method owns all decisions.
    pub fn addBinary(self: *Builder, path: []const u8, raw: []const u8) !StorageDecision {
        const csum = fnv1a(raw);
        const gz = try gzipCompress(raw, self.allocator);

        if (gz.len < raw.len) {
            // Gzip wins — store the compressed block.
            var fat = FatEntry{
                .comp_type = .fallback_stream,
                .data_offset = 0,
                .original_size = raw.len,
                .compressed_size = gz.len,
                .checksum = csum,
            };
            fat.setPath(path);
            try self.entries.append(.{ .fat = fat, .data = gz });
            return .{
                .comp_type = .fallback_stream,
                .stored_size = gz.len,
                .guard_fired = false,
                .gzip_would_have_been = gz.len,
            };
        } else {
            // STORE guard fires: gzip inflates or breaks even.
            // Capture gz.len before freeing the buffer (slice header is on the stack).
            const gz_len = gz.len;
            self.allocator.free(gz);

            const raw_copy = try self.allocator.dupe(u8, raw);
            var fat = FatEntry{
                .comp_type = .store,
                .data_offset = 0,
                .original_size = raw.len,
                .compressed_size = raw.len, // stored_size == original_size for STORE
                .checksum = csum,
            };
            fat.setPath(path);
            try self.entries.append(.{ .fat = fat, .data = raw_copy });
            return .{
                .comp_type = .store,
                .stored_size = raw.len,
                .guard_fired = true,
                .gzip_would_have_been = gz_len,
            };
        }
    }

    /// Add a math-residual entry: an approximate Mathpressor program plus a
    /// gzip-compressed delta buffer that corrects every byte to bit-perfect.
    ///
    /// Block wire format inside the data region:
    ///   [u8: bytecode_len] [bytecode...] [u64 le: gz_delta_len] [gz_delta...]
    ///
    /// Reconstruction invariant (upheld by extractResidual):
    ///   vm_execute(bytecode)[i] +% delta[i] == original[i]  for all i.
    ///
    /// `bytecode` length must fit in a u8 (max 255 bytes); all built-in
    /// templates are well within this bound (MAX_TEMPLATE_CODE_BYTES = 64).
    pub fn addResidual(
        self: *Builder,
        path: []const u8,
        bytecode: []const u8,
        delta: []const u8,
        original_size: u64,
        checksum: u32,
    ) !void {
        if (bytecode.len > 255) return error.BytecodeTooLong;

        // Gzip the delta: exact-match positions are 0, so gzip shrinks it well.
        const gz_delta = try gzipCompress(delta, self.allocator);
        defer self.allocator.free(gz_delta);

        // Assemble block: [u8 bc_len][bytecode][u64 le gz_len][gz_delta]
        const block_len = 1 + bytecode.len + 8 + gz_delta.len;
        const block = try self.allocator.alloc(u8, block_len);
        errdefer self.allocator.free(block);

        block[0] = @intCast(bytecode.len);
        @memcpy(block[1..][0..bytecode.len], bytecode);
        std.mem.writeInt(u64, block[1 + bytecode.len ..][0..8], gz_delta.len, .little);
        @memcpy(block[1 + bytecode.len + 8 ..], gz_delta);

        var fat = FatEntry{
            .comp_type = .math_residual,
            .data_offset = 0,
            .original_size = original_size,
            .compressed_size = block_len,
            .checksum = checksum,
        };
        fat.setPath(path);
        try self.entries.append(.{ .fat = fat, .data = block });
    }

    /// Serialise the container to `writer`.
    pub fn write(self: *Builder, writer: anytype) !void {
        const fat_count: u32 = @intCast(self.entries.items.len);

        // --- Assign offsets inside the data region ---
        var cursor: u64 = 0;
        for (self.entries.items) |*e| {
            e.fat.data_offset = cursor;
            cursor += e.fat.compressed_size;
        }

        // --- Header ---
        try writer.writeAll(MAGIC);
        try writer.writeInt(u16, VERSION, .little);
        try writer.writeInt(u32, fat_count, .little);
        try writer.writeInt(u16, 0, .little); // reserved

        // --- FAT ---
        for (self.entries.items) |e| {
            var row: [FAT_ENTRY_SIZE]u8 = std.mem.zeroes([FAT_ENTRY_SIZE]u8);
            @memcpy(row[0..MAX_PATH_LEN], &e.fat.path);
            row[240] = @intFromEnum(e.fat.comp_type);
            // row[241..247] = _pad (zero)
            std.mem.writeInt(u64, row[248..256], e.fat.data_offset, .little);
            std.mem.writeInt(u64, row[256..264], e.fat.original_size, .little);
            std.mem.writeInt(u64, row[264..272], e.fat.compressed_size, .little);
            std.mem.writeInt(u32, row[272..276], e.fat.checksum, .little);
            // row[276..280] = _pad2 (zero)
            try writer.writeAll(&row);
        }

        // --- Data region ---
        for (self.entries.items) |e| {
            try writer.writeAll(e.data);
        }
    }
};

// ---------------------------------------------------------------------------
// Streaming container writer
// ---------------------------------------------------------------------------
//
// The in-memory Builder is fine for small archives (game-asset packs, tests)
// but unsuitable for large directory trees: it holds every compressed block
// in RAM simultaneously.
//
// StreamingBuilder solves this with a two-pass approach:
//   Pass 1 — process each file, compress it, write the block directly to a
//             temp file on disk, accumulate FAT entries (sizes already known).
//   Pass 2 — write the real output file: header + FAT (offsets computed from
//             cumulative sizes) + stream the temp file back through.
//
// Peak RAM usage = max(one file compressed) rather than sum(all files compressed).

pub const StreamingBuilder = struct {
    allocator: std.mem.Allocator,
    fat: std.ArrayList(FatEntry),
    /// Temporary file that accumulates compressed data blocks in order.
    tmp_file: std.fs.File,
    tmp_path: []u8, // heap-allocated so we can delete it on deinit
    data_cursor: u64, // running byte offset inside the data region

    pub fn init(a: std.mem.Allocator) !StreamingBuilder {
        // Create a temp file in /tmp.
        var tmp_buf: [64]u8 = undefined;
        const tmp_path_str = try std.fmt.bufPrint(&tmp_buf, "/tmp/mathpressor_{d}.tmp", .{
            std.time.milliTimestamp(),
        });
        const tmp_path = try a.dupe(u8, tmp_path_str);
        errdefer a.free(tmp_path);
        const tmp_file = try std.fs.cwd().createFile(tmp_path, .{ .read = true });

        return .{
            .allocator = a,
            .fat = std.ArrayList(FatEntry).init(a),
            .tmp_file = tmp_file,
            .tmp_path = tmp_path,
            .data_cursor = 0,
        };
    }

    pub fn deinit(self: *StreamingBuilder) void {
        self.fat.deinit();
        self.tmp_file.close();
        std.fs.cwd().deleteFile(self.tmp_path) catch {};
        self.allocator.free(self.tmp_path);
    }

    /// Write a raw block to the temp file and register the FAT entry.
    fn appendBlock(self: *StreamingBuilder, fat: FatEntry, block: []const u8) !void {
        var entry = fat;
        entry.data_offset = self.data_cursor;
        try self.tmp_file.writeAll(block);
        self.data_cursor += block.len;
        try self.fat.append(entry);
    }

    pub fn addMath(
        self: *StreamingBuilder,
        path: []const u8,
        bytecode: []const u8,
        original_size: u64,
        checksum: u32,
    ) !void {
        var fat = FatEntry{
            .comp_type = .math_bytecode,
            .data_offset = 0,
            .original_size = original_size,
            .compressed_size = bytecode.len,
            .checksum = checksum,
        };
        fat.setPath(path);
        try self.appendBlock(fat, bytecode);
    }

    pub fn addResidual(
        self: *StreamingBuilder,
        path: []const u8,
        bytecode: []const u8,
        delta: []const u8,
        original_size: u64,
        checksum: u32,
    ) !void {
        if (bytecode.len > 255) return error.BytecodeTooLong;

        const gz_delta = try gzipCompress(delta, self.allocator);
        defer self.allocator.free(gz_delta);

        const block_len = 1 + bytecode.len + 8 + gz_delta.len;
        const block = try self.allocator.alloc(u8, block_len);
        defer self.allocator.free(block);

        block[0] = @intCast(bytecode.len);
        @memcpy(block[1..][0..bytecode.len], bytecode);
        std.mem.writeInt(u64, block[1 + bytecode.len ..][0..8], gz_delta.len, .little);
        @memcpy(block[1 + bytecode.len + 8 ..], gz_delta);

        var fat = FatEntry{
            .comp_type = .math_residual,
            .data_offset = 0,
            .original_size = original_size,
            .compressed_size = block_len,
            .checksum = checksum,
        };
        fat.setPath(path);
        try self.appendBlock(fat, block);
    }

    /// Smart binary entry with STORE guard — gzip vs raw, never inflates.
    pub fn addBinary(
        self: *StreamingBuilder,
        path: []const u8,
        raw: []const u8,
    ) !Builder.StorageDecision {
        const csum = fnv1a(raw);
        const gz = try gzipCompress(raw, self.allocator);
        defer self.allocator.free(gz);

        if (gz.len < raw.len) {
            var fat = FatEntry{
                .comp_type = .fallback_stream,
                .data_offset = 0,
                .original_size = raw.len,
                .compressed_size = gz.len,
                .checksum = csum,
            };
            fat.setPath(path);
            try self.appendBlock(fat, gz);
            return Builder.StorageDecision{ .comp_type = .fallback_stream, .stored_size = gz.len,
                       .guard_fired = false, .gzip_would_have_been = gz.len };
        } else {
            const gz_len = gz.len;
            var fat = FatEntry{
                .comp_type = .store,
                .data_offset = 0,
                .original_size = raw.len,
                .compressed_size = raw.len,
                .checksum = csum,
            };
            fat.setPath(path);
            try self.appendBlock(fat, raw);
            return Builder.StorageDecision{ .comp_type = .store, .stored_size = raw.len,
                       .guard_fired = true, .gzip_would_have_been = gz_len };
        }
    }

    /// Finalise: write header + FAT + stream the temp file into `out_file`.
    /// Call this once after all addXxx calls.
    pub fn finish(self: *StreamingBuilder, out_file: std.fs.File) !void {
        const fat_count: u32 = @intCast(self.fat.items.len);
        var bw = std.io.bufferedWriter(out_file.writer());
        const w = bw.writer();

        // --- Header ---
        try w.writeAll(MAGIC);
        try w.writeInt(u16, VERSION, .little);
        try w.writeInt(u32, fat_count, .little);
        try w.writeInt(u16, 0, .little);

        // --- FAT (offsets already assigned during appendBlock) ---
        for (self.fat.items) |e| {
            var row: [FAT_ENTRY_SIZE]u8 = std.mem.zeroes([FAT_ENTRY_SIZE]u8);
            @memcpy(row[0..MAX_PATH_LEN], &e.path);
            row[240] = @intFromEnum(e.comp_type);
            std.mem.writeInt(u64, row[248..256], e.data_offset, .little);
            std.mem.writeInt(u64, row[256..264], e.original_size, .little);
            std.mem.writeInt(u64, row[264..272], e.compressed_size, .little);
            std.mem.writeInt(u32, row[272..276], e.checksum, .little);
            try w.writeAll(&row);
        }

        // --- Data region: stream temp file in 1 MB chunks ---
        try self.tmp_file.seekTo(0);
        var chunk_buf: [1024 * 1024]u8 = undefined;
        while (true) {
            const n = try self.tmp_file.read(&chunk_buf);
            if (n == 0) break;
            try w.writeAll(chunk_buf[0..n]);
        }

        try bw.flush();
    }

    pub fn entryCount(self: *const StreamingBuilder) usize {
        return self.fat.items.len;
    }

    pub fn dataBytes(self: *const StreamingBuilder) u64 {
        return self.data_cursor;
    }
};

// ---------------------------------------------------------------------------
// Container reader
// ---------------------------------------------------------------------------

/// Parses a .math archive from `data` (the full file in memory).
pub const Reader = struct {
    fat: []FatEntry,
    /// Slice of `data` that covers just the data region.
    data_region: []const u8,
    allocator: std.mem.Allocator,

    pub fn parse(data: []const u8, a: std.mem.Allocator) !Reader {
        if (data.len < HEADER_SIZE) return error.TruncatedContainer;

        // Header
        if (!std.mem.eql(u8, data[0..4], MAGIC)) return error.BadMagic;
        const ver = std.mem.readInt(u16, data[4..6], .little);
        if (ver != VERSION) return error.UnsupportedVersion;
        const fat_count = std.mem.readInt(u32, data[6..10], .little);

        const fat_end = HEADER_SIZE + FAT_ENTRY_SIZE * fat_count;
        if (data.len < fat_end) return error.TruncatedContainer;

        // Parse FAT
        const fat = try a.alloc(FatEntry, fat_count);
        errdefer a.free(fat);

        for (fat, 0..) |*entry, i| {
            const base = HEADER_SIZE + FAT_ENTRY_SIZE * i;
            const row = data[base..][0..FAT_ENTRY_SIZE];
            @memcpy(&entry.path, row[0..MAX_PATH_LEN]);
            entry.comp_type = @enumFromInt(row[240]);
            entry.data_offset = std.mem.readInt(u64, row[248..256], .little);
            entry.original_size = std.mem.readInt(u64, row[256..264], .little);
            entry.compressed_size = std.mem.readInt(u64, row[264..272], .little);
            entry.checksum = std.mem.readInt(u32, row[272..276], .little);
        }

        return .{
            .fat = fat,
            .data_region = data[fat_end..],
            .allocator = a,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.allocator.free(self.fat);
    }

    /// Reconstruct the original bytes for `path` into a freshly allocated
    /// slice. Caller must free it.
    pub fn extract(self: *const Reader, path: []const u8, a: std.mem.Allocator) ![]u8 {
        const entry = self.findEntry(path) orelse return error.FileNotFound;
        const compressed = self.data_region[entry.data_offset..][0..entry.compressed_size];

        return switch (entry.comp_type) {
            .math_bytecode   => extractMath(compressed, entry.original_size, a),
            .fallback_stream => extractFallback(compressed, entry.original_size, a),
            .store           => extractStore(compressed, entry.original_size, a),
            .math_residual   => extractResidual(compressed, entry.original_size, a),
        };
    }

    pub fn entryCount(self: *const Reader) usize {
        return self.fat.len;
    }

    pub fn entryAt(self: *const Reader, i: usize) FatEntry {
        return self.fat[i];
    }

    fn findEntry(self: *const Reader, path: []const u8) ?*const FatEntry {
        for (self.fat) |*e| {
            if (std.mem.eql(u8, e.getPath(), path)) return e;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Extraction helpers
// ---------------------------------------------------------------------------

fn extractMath(bytecode: []const u8, original_size: u64, a: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var machine = vm_mod.Vm.init(arena.allocator());
    const pixels = try machine.execute(bytecode);

    if (pixels.len != original_size) return error.SizeMismatch;

    const out = try a.alloc(u8, pixels.len);
    @memcpy(out, pixels);
    return out;
}

/// STORE: the data region holds the raw bytes verbatim — just dupe and return.
fn extractStore(raw: []const u8, original_size: u64, a: std.mem.Allocator) ![]u8 {
    if (raw.len != original_size) return error.SizeMismatch;
    return a.dupe(u8, raw);
}

fn extractFallback(gz_data: []const u8, original_size: u64, a: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).init(a);
    errdefer buf.deinit();

    var fbs = std.io.fixedBufferStream(gz_data);
    try std.compress.gzip.decompress(fbs.reader(), buf.writer());

    if (buf.items.len != original_size) return error.SizeMismatch;
    return buf.toOwnedSlice();
}

/// MATH_RESIDUAL: run the approximate VM program, then overlay the delta.
///
/// Block layout: [u8 bc_len][bytecode...][u64 le gz_delta_len][gz_delta...]
/// Reconstruction: out[i] = approx_vm[i] +% delta[i]
fn extractResidual(block: []const u8, original_size: u64, a: std.mem.Allocator) ![]u8 {
    // --- Parse the framing ---
    if (block.len < 1) return error.TruncatedContainer;
    const bc_len: usize = block[0];
    if (block.len < 1 + bc_len + 8) return error.TruncatedContainer;

    const bytecode = block[1..][0..bc_len];
    const gz_delta_len = std.mem.readInt(u64, block[1 + bc_len ..][0..8], .little);
    if (block.len < 1 + bc_len + 8 + gz_delta_len) return error.TruncatedContainer;
    const gz_delta = block[1 + bc_len + 8 ..][0..gz_delta_len];

    // --- Run the VM to produce the approximate pixel pattern ---
    var vm_arena = std.heap.ArenaAllocator.init(a);
    defer vm_arena.deinit();
    var machine = vm_mod.Vm.init(vm_arena.allocator());
    const approx = try machine.execute(bytecode);
    if (approx.len != original_size) return error.SizeMismatch;

    // --- Decompress the delta ---
    var delta_list = std.ArrayList(u8).init(a);
    errdefer delta_list.deinit();
    var gz_fbs = std.io.fixedBufferStream(gz_delta);
    try std.compress.gzip.decompress(gz_fbs.reader(), delta_list.writer());
    const delta = try delta_list.toOwnedSlice();
    defer a.free(delta);
    if (delta.len != original_size) return error.SizeMismatch;

    // --- Reconstruct: approx[i] +% delta[i] == original[i] ---
    const out = try a.alloc(u8, @intCast(original_size));
    for (out, approx, delta) |*o, ap, d| o.* = ap +% d;
    return out;
}

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

pub fn fnv1a(data: []const u8) u32 {
    var h: u32 = 0x811C_9DC5;
    for (data) |b| {
        h ^= b;
        h *%= 0x0100_0193;
    }
    return h;
}

pub fn gzipCompress(data: []const u8, a: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).init(a);
    errdefer buf.deinit();
    var fbs = std.io.fixedBufferStream(data);
    try std.compress.gzip.compress(fbs.reader(), buf.writer(), .{ .level = .best });
    return buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "container round-trip: math entry reconstructs identically" {
    const a = testing.allocator;

    // Build a tiny math texture
    var prog = vm_mod.Builder.init(a);
    defer prog.deinit();
    try prog.seed(0xABCD);
    try prog.intNoise(0, 16, 16, 4);
    try prog.halt();
    const code = prog.bytes();

    var vm_arena = std.heap.ArenaAllocator.init(a);
    defer vm_arena.deinit();
    var machine = vm_mod.Vm.init(vm_arena.allocator());
    const pixels = try machine.execute(code);

    const csum = fnv1a(pixels);

    // Build container
    var cb = Builder.init(a);
    defer cb.deinit();
    try cb.addMath("textures/test.raw", code, pixels.len, csum);

    var container_buf = std.ArrayList(u8).init(a);
    defer container_buf.deinit();
    try cb.write(container_buf.writer());

    // Parse and extract
    var rdr = try Reader.parse(container_buf.items, a);
    defer rdr.deinit();

    try testing.expectEqual(@as(usize, 1), rdr.entryCount());
    const entry = rdr.entryAt(0);
    try testing.expectEqual(CompressionType.math_bytecode, entry.comp_type);

    const reconstructed = try rdr.extract("textures/test.raw", a);
    defer a.free(reconstructed);

    try testing.expectEqualSlices(u8, pixels, reconstructed);
    try testing.expectEqual(csum, fnv1a(reconstructed));
}

test "container round-trip: fallback entry reconstructs identically" {
    const a = testing.allocator;

    // "Messy" binary data that can't be math-encoded
    var rng = @import("math_gen.zig").XorShift32.init(0xDEAD);
    const raw = try a.alloc(u8, 512);
    defer a.free(raw);
    for (raw) |*b| b.* = rng.nextByte();

    const compressed = try gzipCompress(raw, a);
    defer a.free(compressed);
    const csum = fnv1a(raw);

    var cb = Builder.init(a);
    defer cb.deinit();
    try cb.addFallback("binary/enemy_ai.bin", compressed, raw.len, csum);

    var container_buf = std.ArrayList(u8).init(a);
    defer container_buf.deinit();
    try cb.write(container_buf.writer());

    var rdr = try Reader.parse(container_buf.items, a);
    defer rdr.deinit();

    const reconstructed = try rdr.extract("binary/enemy_ai.bin", a);
    defer a.free(reconstructed);

    try testing.expectEqualSlices(u8, raw, reconstructed);
}

test "container: mixed math + fallback entries coexist" {
    const a = testing.allocator;

    // Math entry
    var prog = vm_mod.Builder.init(a);
    defer prog.deinit();
    try prog.seed(1);
    try prog.intNoise(0, 8, 8, 3);
    try prog.halt();
    const code = prog.bytes();
    var vm_arena = std.heap.ArenaAllocator.init(a);
    defer vm_arena.deinit();
    var machine_inst = vm_mod.Vm.init(vm_arena.allocator());
    const pixels = try machine_inst.execute(code);

    // Fallback entry
    const bin_data = [_]u8{0xDE} ** 64;
    const bin_gz = try gzipCompress(&bin_data, a);
    defer a.free(bin_gz);

    var cb = Builder.init(a);
    defer cb.deinit();
    try cb.addMath("tex.raw", code, pixels.len, fnv1a(pixels));
    try cb.addFallback("code.bin", bin_gz, bin_data.len, fnv1a(&bin_data));

    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();
    try cb.write(buf.writer());

    var rdr = try Reader.parse(buf.items, a);
    defer rdr.deinit();
    try testing.expectEqual(@as(usize, 2), rdr.entryCount());

    const r1 = try rdr.extract("tex.raw", a);
    defer a.free(r1);
    try testing.expectEqualSlices(u8, pixels, r1);

    const r2 = try rdr.extract("code.bin", a);
    defer a.free(r2);
    try testing.expectEqualSlices(u8, &bin_data, r2);
}

test "container: bad magic is rejected" {
    var bad = [_]u8{0} ** 64;
    @memcpy(bad[0..4], "NOPE");
    try testing.expectError(error.BadMagic, Reader.parse(&bad, testing.allocator));
}

test "STORE guard: repetitive data is gzip-compressed (FALLBACK_STREAM)" {
    const a = testing.allocator;
    // Highly repetitive — gzip shrinks it dramatically.
    const repetitive = "AAAAAAAAAAAAAAAA" ** 64; // 1024 bytes, 1 distinct symbol
    var cb = Builder.init(a);
    defer cb.deinit();
    const decision = try cb.addBinary("data/repetitive.bin", repetitive);
    try testing.expectEqual(CompressionType.fallback_stream, decision.comp_type);
    try testing.expect(!decision.guard_fired);
    try testing.expect(decision.stored_size < repetitive.len);

    // Verify round-trip.
    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();
    try cb.write(buf.writer());
    var rdr = try Reader.parse(buf.items, a);
    defer rdr.deinit();
    const out = try rdr.extract("data/repetitive.bin", a);
    defer a.free(out);
    try testing.expectEqualSlices(u8, repetitive, out);
}

test "STORE guard: high-entropy data bypasses gzip (STORE)" {
    const a = testing.allocator;
    // 2 KB of XorShift32 output: entropy ≈ 7.9 bits/byte; gzip inflates it.
    var rng = @import("math_gen.zig").XorShift32.init(0xC0FFEE);
    const random = try a.alloc(u8, 2048);
    defer a.free(random);
    for (random) |*b| b.* = rng.nextByte();

    var cb = Builder.init(a);
    defer cb.deinit();
    const decision = try cb.addBinary("binary/bloated.bin", random);
    try testing.expectEqual(CompressionType.store, decision.comp_type);
    try testing.expect(decision.guard_fired);
    // Stored size must be exactly original size — no inflation.
    try testing.expectEqual(random.len, decision.stored_size);
    // The gzip alternative would have been larger.
    try testing.expect(decision.gzip_would_have_been >= random.len);

    // Round-trip: extract gives back the original bytes exactly.
    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();
    try cb.write(buf.writer());
    var rdr = try Reader.parse(buf.items, a);
    defer rdr.deinit();
    const out = try rdr.extract("binary/bloated.bin", a);
    defer a.free(out);
    try testing.expectEqualSlices(u8, random, out);
}

test "MATH_RESIDUAL round-trip: reconstruct bit-perfectly from approx + delta" {
    const a = testing.allocator;

    // Generate a clean noise texture (matches translator's single_noise template).
    const W: u16 = 16;
    const H: u16 = 16;
    var prog = vm_mod.Builder.init(a);
    defer prog.deinit();
    try prog.seed(7);
    try prog.intNoise(0, W, H, 4);
    try prog.halt();
    const bytecode = prog.bytes();

    var vm_arena = std.heap.ArenaAllocator.init(a);
    defer vm_arena.deinit();
    var machine = vm_mod.Vm.init(vm_arena.allocator());
    const clean = try machine.execute(bytecode);

    // Corrupt ~25% of pixels to produce the "original" dirty bytes.
    const original = try a.dupe(u8, clean);
    defer a.free(original);
    var rng = @import("math_gen.zig").XorShift32.init(0xBADBAD);
    for (original) |*p| {
        if (rng.nextBelow(100) < 25) p.* = rng.nextByte();
    }

    // Build the delta: delta[i] = original[i] -% approx[i]
    const delta = try a.alloc(u8, original.len);
    defer a.free(delta);
    for (delta, original, clean) |*d, raw, approx| d.* = raw -% approx;

    // Add to container as math_residual.
    const csum = fnv1a(original);
    var cb = Builder.init(a);
    defer cb.deinit();
    try cb.addResidual("textures/dirty.raw", bytecode, delta,
        original.len, csum);

    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();
    try cb.write(buf.writer());

    // Parse and extract.
    var rdr = try Reader.parse(buf.items, a);
    defer rdr.deinit();

    try testing.expectEqual(@as(usize, 1), rdr.entryCount());
    const entry = rdr.entryAt(0);
    try testing.expectEqual(CompressionType.math_residual, entry.comp_type);

    // The stored block must be smaller than the original raw bytes.
    try testing.expect(entry.compressed_size < original.len);

    const reconstructed = try rdr.extract("textures/dirty.raw", a);
    defer a.free(reconstructed);

    // Byte-perfect reconstruction.
    try testing.expectEqualSlices(u8, original, reconstructed);
    try testing.expectEqual(csum, fnv1a(reconstructed));
}

test "STORE guard: container size never exceeds raw input" {
    const a = testing.allocator;
    // For any binary file, the .math container overhead is fixed (header + FAT).
    // The data payload must never exceed the raw file size.
    var rng = @import("math_gen.zig").XorShift32.init(0xDEAD);
    const sizes = [_]usize{ 128, 512, 1024, 4096 };
    for (sizes) |sz| {
        const raw = try a.alloc(u8, sz);
        defer a.free(raw);
        for (raw) |*b| b.* = rng.nextByte();

        var cb = Builder.init(a);
        defer cb.deinit();
        _ = try cb.addBinary("test.bin", raw);

        var buf = std.ArrayList(u8).init(a);
        defer buf.deinit();
        try cb.write(buf.writer());

        // The data payload region of the container must be ≤ raw size.
        // (Header + FAT are fixed overhead, not attributed to the file data.)
        const data_payload = buf.items.len - HEADER_SIZE - FAT_ENTRY_SIZE;
        try testing.expect(data_payload <= sz);
    }
}

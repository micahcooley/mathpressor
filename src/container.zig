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
//!                      0x03=Store, 0x04=MathResidual, 0x05=SolidBlock
//!   _pad[0..3]         solid_index u32 le (SolidBlock only; zero otherwise)
//!   _pad[4..6]         reserved (zero)
//!   data_offset u64    offset from start of data region
//!   original_size u64  uncompressed byte count for THIS file
//!   compressed_size u64 total solid block gz size (same for all files in block)
//!   checksum u32       FNV-1a of the ORIGINAL uncompressed data
//!   _pad2[4]

const std = @import("std");
const vm_mod = @import("vm.zig");
const bcj2 = @import("bcj2.zig");
const cm = @import("cm.zig");

// ---------------------------------------------------------------------------
// Format constants
// ---------------------------------------------------------------------------

const MAGIC = "MATH";
const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 12;
pub const FAT_ENTRY_SIZE: usize = 280;

pub const MAX_PATH_LEN: usize = 240;

/// Container header flags (the formerly-reserved u16 at byte offset 10).
/// Bit 0: the archive wraps a single real .zip that unpack must expand back
/// into the original files ("full mode"). Old archives have flags=0.
pub const FLAG_FULL_ZIP: u16 = 0x0001;
/// Bit 1: the FAT is gzip-compressed. Layout becomes:
///   [12B header][u64 comp_fat_len][gzip(FAT)][data region]
/// instead of [12B header][raw FAT][data region]. The FAT is many 280-byte
/// rows that are mostly zero padding, so this typically shrinks it ~10-20×,
/// erasing the per-file overhead that crippled many-small-file trees.
pub const FLAG_FAT_GZIP: u16 = 0x0002;
/// Bit 2: the archive wraps a single uncompressed .tar that unpack must expand
/// back into the original files ("full mode", tar flavour). Unlike
/// FLAG_FULL_ZIP this needs no external tools: the tar is built with
/// std.tar.writer at pack time and expanded with std.tar.pipeToFileSystem at
/// unpack time, and the solid tar stream is zstd-compressed by the container
/// itself at the effort tier.
pub const FLAG_FULL_TAR: u16 = 0x0004;
/// Bit 3: the archive ships one or more trained zstd dictionaries. Layout
/// becomes:
///   [12B header][u64 comp_fat_len][gzip(FAT)][dict section][data region]
/// where the dict section is:
///   [u32 dict_count]  then for each dict  [u32 dict_len][dict_bytes]
/// Entries with comp_type == .math_dict are zstd frames compressed against the
/// dictionary whose index is stored in their `solid_index` field. The dict is
/// shipped once and shared across many similar small files, giving cross-file
/// compression WITHOUT a solid block — every entry still decodes independently
/// (random access), so it stays live-runnable. data_offset values remain
/// relative to the data region (after the dict section), so they're unchanged.
pub const FLAG_HAS_DICTS: u16 = 0x0008;

/// Serialise one FAT entry to its 280-byte wire row.
fn fatRow(e: FatEntry) [FAT_ENTRY_SIZE]u8 {
    var row: [FAT_ENTRY_SIZE]u8 = std.mem.zeroes([FAT_ENTRY_SIZE]u8);
    @memcpy(row[0..MAX_PATH_LEN], &e.path);
    row[240] = @intFromEnum(e.comp_type);
    std.mem.writeInt(u32, row[241..245], e.solid_index, .little);
    row[245] = @intFromEnum(e.codec);
    std.mem.writeInt(u64, row[248..256], e.data_offset, .little);
    std.mem.writeInt(u64, row[256..264], e.original_size, .little);
    std.mem.writeInt(u64, row[264..272], e.compressed_size, .little);
    std.mem.writeInt(u32, row[272..276], e.checksum, .little);
    return row;
}

/// Write the header + (gzip-compressed) FAT to `w`. The caller writes the data
/// region afterward. `fat_bytes` is the concatenation of all 280-byte rows.
fn writeHeaderAndFat(
    w: anytype,
    fat_count: u32,
    fat_bytes: []const u8,
    base_flags: u16,
    a: std.mem.Allocator,
) !void {
    const gz = try gzipCompress(fat_bytes, a, .best); // FAT is tiny + repetitive
    defer a.free(gz);
    try w.writeAll(MAGIC);
    try w.writeInt(u16, VERSION, .little);
    try w.writeInt(u32, fat_count, .little);
    try w.writeInt(u16, base_flags | FLAG_FAT_GZIP, .little);
    try w.writeInt(u64, gz.len, .little);
    try w.writeAll(gz);
}

pub const CompressionType = enum(u8) {
    math_bytecode   = 0x01,
    fallback_stream = 0x02, // compressed block (codec per Codec byte)
    store           = 0x03, // raw bytes — STORE guard fired
    math_residual   = 0x04, // approximate program + compressed delta
    solid_block     = 0x05, // deep-archive: file lives inside a shared solid block
    symlink         = 0x06, // symbolic link — data block is the raw target path
    math_blocks     = 0x07, // per-block decomposition: equations + literal stream
    math_filtered   = 0x08, // reversible math filter applied, then compressed
    math_columnar   = 0x09, // AoS->SoA transpose (record arrays), then compressed
    math_image2d    = 0x0A, // 2D MED predictor over raw raster, then compressed
    math_dict       = 0x0B, // zstd frame compressed against a shared trained dictionary
    math_audio      = 0x0C, // fixed-order LPC over PCM (WAV) samples, then compressed
    math_bcj2       = 0x0D, // full mode: 4-stream BCJ2 x86 filter, each LZMA'd
    math_cm         = 0x0E, // context-mixing backend (cold/full mode; beats LZMA on text)
};

/// Per-entry compression codec (FAT byte 245). gzip = 0 is the legacy default,
/// so archives written before this byte existed decode correctly.
pub const Codec = enum(u8) {
    gzip = 0x00,
    zstd = 0x01,
    lzma = 0x02, // xz/LZMA backend (full mode) — stronger model than zstd
};

// ---------------------------------------------------------------------------
// FAT entry (in-memory representation)
// ---------------------------------------------------------------------------

pub const FatEntry = struct {
    /// Relative path, max 239 chars + null.
    path: [MAX_PATH_LEN]u8 = std.mem.zeroes([MAX_PATH_LEN]u8),
    comp_type: CompressionType,
    /// For solid_block entries: 0-based index of this file within the shared
    /// gz block. Stored in wire bytes 241..244 (_pad[0..3]). Zero for all
    /// non-solid entries.
    solid_index: u32 = 0,
    /// Byte offset from the start of the data region.
    data_offset: u64,
    original_size: u64,
    compressed_size: u64,
    /// FNV-1a of the original uncompressed bytes.
    checksum: u32,
    /// Compression codec for this entry's block (gzip default for legacy).
    codec: Codec = .gzip,

    pub fn setPath(self: *FatEntry, p: []const u8) error{PathTooLong}!void {
        if (p.len >= MAX_PATH_LEN) return error.PathTooLong;
        @memcpy(self.path[0..p.len], p);
        self.path[p.len] = 0;
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
    /// Codec + effort for this builder's compressed blocks.
    comp: Compressor = .{},

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
        try fat.setPath(path);
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
            .codec = .gzip, // caller supplied gzip-compressed bytes
        };
        try fat.setPath(path);
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
        const gz = try self.comp.compress(raw, self.allocator);

        if (gz.len < raw.len) {
            // Compression wins — store the compressed block.
            var fat = FatEntry{
                .comp_type = .fallback_stream,
                .data_offset = 0,
                .original_size = raw.len,
                .compressed_size = gz.len,
                .checksum = csum,
                .codec = self.comp.codec,
            };
            try fat.setPath(path);
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
            try fat.setPath(path);
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

        // Compress the delta: exact-match positions are 0, so it shrinks well.
        const gz_delta = try self.comp.compress(delta, self.allocator);
        defer self.allocator.free(gz_delta);

        // Assemble block: [u8 bc_len][bytecode][u64 le delta_len][delta]
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
            .codec = self.comp.codec,
        };
        try fat.setPath(path);
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

        // --- Header + compressed FAT ---
        var fat_buf = std.ArrayList(u8).init(self.allocator);
        defer fat_buf.deinit();
        for (self.entries.items) |e| try fat_buf.appendSlice(&fatRow(e.fat));
        try writeHeaderAndFat(writer, fat_count, fat_buf.items, 0, self.allocator);

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
    /// Codec + effort for compressed blocks (set by the effort tier).
    comp: Compressor = .{},
    /// Container header flags written at finish() (e.g. FLAG_FULL_ZIP).
    flags: u16 = 0,
    /// Trained zstd dictionaries shipped once and shared across entries whose
    /// comp_type is .math_dict (their solid_index is the index into this list).
    /// Each entry is owned (duped) and freed in deinit.
    dicts: std.ArrayList([]u8),

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
            .dicts = std.ArrayList([]u8).init(a),
        };
    }

    pub fn deinit(self: *StreamingBuilder) void {
        self.fat.deinit();
        for (self.dicts.items) |d| self.allocator.free(d);
        self.dicts.deinit();
        self.tmp_file.close();
        std.fs.cwd().deleteFile(self.tmp_path) catch {};
        self.allocator.free(self.tmp_path);
    }

    /// Register a trained dictionary and return its index (for the entries that
    /// will reference it via .math_dict + solid_index). The bytes are duped.
    pub fn registerDict(self: *StreamingBuilder, dict: []const u8) !u32 {
        const idx: u32 = @intCast(self.dicts.items.len);
        try self.dicts.append(try self.allocator.dupe(u8, dict));
        return idx;
    }

    /// Write a raw block to the temp file and register the FAT entry.
    pub fn appendBlock(self: *StreamingBuilder, fat: FatEntry, block: []const u8) !void {
        var entry = fat;
        entry.data_offset = self.data_cursor;
        try self.tmp_file.writeAll(block);
        self.data_cursor += block.len;
        try self.fat.append(entry);
    }

    /// Register a FAT entry that REUSES an already-written blob (whole-file
    /// dedup): caller sets fat.data_offset / compressed_size / comp_type / codec
    /// to the shared blob's, plus its own path / checksum / original_size. No
    /// bytes are written and the cursor doesn't advance — two identical files
    /// cost one blob. Extract is offset-based and stateless, so this stays fully
    /// live (random access) with zero added decode cost.
    pub fn appendDedup(self: *StreamingBuilder, fat: FatEntry) !void {
        try self.fat.append(fat);
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
        try fat.setPath(path);
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

        const gz_delta = try self.comp.compress(delta, self.allocator);
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
            .codec = self.comp.codec,
        };
        try fat.setPath(path);
        try self.appendBlock(fat, block);
    }

    /// Smart binary entry with STORE guard — compress vs raw, never inflates.
    pub fn addBinary(
        self: *StreamingBuilder,
        path: []const u8,
        raw: []const u8,
    ) !Builder.StorageDecision {
        const csum = fnv1a(raw);
        const gz = try self.comp.compress(raw, self.allocator);
        defer self.allocator.free(gz);

        if (gz.len < raw.len) {
            var fat = FatEntry{
                .comp_type = .fallback_stream,
                .data_offset = 0,
                .original_size = raw.len,
                .compressed_size = gz.len,
                .checksum = csum,
                .codec = self.comp.codec,
            };
            try fat.setPath(path);
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
            try fat.setPath(path);
            try self.appendBlock(fat, raw);
            return Builder.StorageDecision{ .comp_type = .store, .stored_size = raw.len,
                       .guard_fired = true, .gzip_would_have_been = gz_len };
        }
    }

    /// Record a symbolic link. The data block is the raw target path; nothing
    /// is compressed. Skipping symlinks entirely (the old behaviour) silently
    /// shrank unpacked trees — Steam runtimes alone carry thousands of links.
    pub fn addSymlink(self: *StreamingBuilder, path: []const u8, target: []const u8) !void {
        var fat = FatEntry{
            .comp_type = .symlink,
            .data_offset = 0,
            .original_size = target.len,
            .compressed_size = target.len,
            .checksum = fnv1a(target),
        };
        try fat.setPath(path);
        try self.appendBlock(fat, target);
    }

    /// Stream-compress a large file straight into the temp data region without
    /// ever holding it in memory. Two passes over the file: FNV-1a checksum,
    /// then gzip (the page cache makes the second read cheap). STORE guard:
    /// if gzip inflates, the gz bytes are truncated away and the raw bytes
    /// streamed verbatim instead.
    ///
    /// This is the path for files past the in-memory threshold — without it
    /// they were silently SKIPPED, which is data loss the user only discovers
    /// when the unpacked tree comes out smaller than the source.
    pub fn addBinaryStreamingFile(
        self: *StreamingBuilder,
        path: []const u8,
        file: std.fs.File,
        size: u64,
    ) !Builder.StorageDecision {
        var buf: [256 * 1024]u8 = undefined;

        // Pass 1 — FNV-1a over the whole file.
        try file.seekTo(0);
        var csum: u32 = 0x811C_9DC5;
        while (true) {
            const n = try file.read(&buf);
            if (n == 0) break;
            for (buf[0..n]) |b| {
                csum ^= b;
                csum *%= 0x0100_0193;
            }
        }

        // Pass 2 — gzip stream into the temp file, counting output bytes.
        // Huge files use gzip streaming (zstd streaming would need libzstd's
        // CStream API); they're usually already-compressed assets that STORE
        // anyway, so the codec barely matters here. Marked codec=.gzip below.
        const block_offset = self.data_cursor;
        try file.seekTo(0);
        var counting = std.io.countingWriter(self.tmp_file.writer());
        var br = std.io.bufferedReader(file.reader());
        try std.compress.gzip.compress(br.reader(), counting.writer(), .{ .level = self.comp.gzip_level });
        var stored: u64 = counting.bytes_written;
        var ctype: CompressionType = .fallback_stream;

        if (stored >= size) {
            // STORE guard — drop the gz bytes and stream the raw file instead.
            try self.tmp_file.setEndPos(block_offset);
            try self.tmp_file.seekTo(block_offset);
            try file.seekTo(0);
            var written: u64 = 0;
            while (true) {
                const n = try file.read(&buf);
                if (n == 0) break;
                try self.tmp_file.writeAll(buf[0..n]);
                written += n;
            }
            stored = written;
            ctype = .store;
        }

        var fat = FatEntry{
            .comp_type = ctype,
            .data_offset = block_offset,
            .original_size = size,
            .compressed_size = stored,
            .checksum = csum,
            .codec = .gzip, // streamed with gzip (see note above)
        };
        try fat.setPath(path);
        self.data_cursor = block_offset + stored;
        try self.fat.append(fat);

        return .{
            .comp_type = ctype,
            .stored_size = @intCast(stored),
            .guard_fired = ctype == .store,
            .gzip_would_have_been = @intCast(stored),
        };
    }

    /// Stream-compress a large file into the temp data region with zstd at the
    /// builder's effort level, never holding the whole file in memory. Mirrors
    /// addBinaryStreamingFile (two passes: FNV-1a, then compress; STORE guard)
    /// but uses libzstd's streaming CStream API instead of gzip, so the solid
    /// tar payload of full mode gets the same codec/level as everything else.
    /// The pledged source size puts the content size in the frame header, so
    /// extraction goes through the ordinary known-size zstdDecompress path.
    pub fn addZstdStreamingFile(
        self: *StreamingBuilder,
        path: []const u8,
        file: std.fs.File,
        size: u64,
    ) !Builder.StorageDecision {
        var in_buf: [256 * 1024]u8 = undefined;

        // Pass 1 — FNV-1a over the whole file.
        try file.seekTo(0);
        var csum: u32 = 0x811C_9DC5;
        while (true) {
            const n = try file.read(&in_buf);
            if (n == 0) break;
            for (in_buf[0..n]) |b| {
                csum ^= b;
                csum *%= 0x0100_0193;
            }
        }

        // Pass 2 — zstd stream into the temp file, counting output bytes.
        const block_offset = self.data_cursor;
        try file.seekTo(0);

        const cctx = ZSTD_createCCtx() orelse return error.ZstdCompressFailed;
        defer _ = ZSTD_freeCCtx(cctx);
        if (ZSTD_isError(ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, self.comp.zstd_level)) != 0)
            return error.ZstdCompressFailed;
        // Multithreaded compression when libzstd supports it (ignore if not).
        _ = ZSTD_CCtx_setParameter(cctx, ZSTD_c_nbWorkers, @intCast(@min(16, std.Thread.getCpuCount() catch 1)));
        // Long-distance matching over a 128 MB window: matches can span the
        // whole solid stream instead of the level's default window, which is
        // where a solid tar gains over per-file compression. windowLog 27 is
        // the decoder's default limit, so plain ZSTD_decompress reads it back
        // without opting in to anything. Auto-clamped for small inputs via the
        // pledged source size; ignored by libzstd builds without LDM.
        _ = ZSTD_CCtx_setParameter(cctx, ZSTD_c_enableLongDistanceMatching, 1);
        _ = ZSTD_CCtx_setParameter(cctx, ZSTD_c_windowLog, 27);
        if (ZSTD_isError(ZSTD_CCtx_setPledgedSrcSize(cctx, size)) != 0)
            return error.ZstdCompressFailed;

        var out_buf: [256 * 1024]u8 = undefined;
        var stored: u64 = 0;
        while (true) {
            const n = try file.read(&in_buf);
            var in = ZSTD_inBuffer{ .src = &in_buf, .size = n, .pos = 0 };
            const mode: c_int = if (n == 0) ZSTD_e_end else ZSTD_e_continue;
            while (true) {
                var out = ZSTD_outBuffer{ .dst = &out_buf, .size = out_buf.len, .pos = 0 };
                const rc = ZSTD_compressStream2(cctx, &out, &in, mode);
                if (ZSTD_isError(rc) != 0) return error.ZstdCompressFailed;
                try self.tmp_file.writeAll(out_buf[0..out.pos]);
                stored += out.pos;
                // continue: stop once this chunk's input is consumed;
                // end: stop once the frame epilogue is fully flushed (rc == 0).
                if (mode == ZSTD_e_end) {
                    if (rc == 0) break;
                } else if (in.pos == in.size) break;
            }
            if (n == 0) break;
        }

        var ctype: CompressionType = .fallback_stream;
        if (stored >= size) {
            // STORE guard — drop the zstd bytes and stream the raw file instead.
            try self.tmp_file.setEndPos(block_offset);
            try self.tmp_file.seekTo(block_offset);
            try file.seekTo(0);
            var written: u64 = 0;
            while (true) {
                const n = try file.read(&in_buf);
                if (n == 0) break;
                try self.tmp_file.writeAll(in_buf[0..n]);
                written += n;
            }
            stored = written;
            ctype = .store;
        }

        var fat = FatEntry{
            .comp_type = ctype,
            .data_offset = block_offset,
            .original_size = size,
            .compressed_size = stored,
            .checksum = csum,
            .codec = .zstd,
        };
        try fat.setPath(path);
        self.data_cursor = block_offset + stored;
        try self.fat.append(fat);

        return .{
            .comp_type = ctype,
            .stored_size = @intCast(stored),
            .guard_fired = ctype == .store,
            .gzip_would_have_been = @intCast(stored),
        };
    }

    /// Finalise: write header + FAT + stream the temp file into `out_file`.
    /// Call this once after all addXxx calls.
    pub fn finish(self: *StreamingBuilder, out_file: std.fs.File) !void {
        const fat_count: u32 = @intCast(self.fat.items.len);
        var bw = std.io.bufferedWriter(out_file.writer());
        const w = bw.writer();

        // --- Header + compressed FAT (offsets assigned during appendBlock) ---
        var fat_buf = std.ArrayList(u8).init(self.allocator);
        defer fat_buf.deinit();
        for (self.fat.items) |e| try fat_buf.appendSlice(&fatRow(e));
        const base_flags = self.flags | (if (self.dicts.items.len > 0) FLAG_HAS_DICTS else 0);
        try writeHeaderAndFat(w, fat_count, fat_buf.items, base_flags, self.allocator);

        // --- Dict section (between FAT and data region) ---
        if (self.dicts.items.len > 0) {
            try w.writeInt(u32, @intCast(self.dicts.items.len), .little);
            for (self.dicts.items) |d| {
                try w.writeInt(u32, @intCast(d.len), .little);
                try w.writeAll(d);
            }
        }

        // --- Data region: stream temp file in 64 KB chunks ---
        try self.tmp_file.seekTo(0);
        var chunk_buf: [64 * 1024]u8 = undefined;
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
// Solid Block Builder (Deep Archive / Cold-Storage Mode)
// ---------------------------------------------------------------------------
//
// When `--solid` is OFF the caller uses this instead of StreamingBuilder.
//
// Strategy:
//   1. Math/Residual entries are written immediately — they are already tiny
//      programs and gain nothing from solid grouping.
//   2. Fallback/Store files are bucketed by their lowercase file extension.
//      Every bucket is concatenated into one continuous raw stream and then
//      compressed as a single gzip block.  Because the compressor sees all
//      .lua files (or all .json, all .txt …) at once, it can reuse repeated
//      identifiers, function names and patterns across file boundaries —
//      typically yielding 10–40 % better ratio than per-file compression.
//   3. finish() flushes all pending solid buckets, writes them to the temp
//      data region, then finalises the container normally.
//
// Wire layout inside the data region for a solid block:
//
//   [u32 le: file_count]
//   For each file in insertion order:
//     [u64 le: original_size]          ← needed for extraction
//   [gzip stream of all raw bytes concatenated]
//
//   The FAT entry for each file in a solid block records:
//     comp_type  = .solid_block        (0x05)
//     data_offset                      ← offset of the SOLID BLOCK header
//     original_size                    ← this file's uncompressed size
//     compressed_size                  ← total solid block size (same for all files in block)
//     checksum                         ← FNV-1a of this file's original bytes
//
//   The extraction routine knows to:
//     a) read the block header to find how many files and their sizes
//     b) gzip-decompress the unified stream
//     c) slice out this file's bytes using a running offset
//
// The `solid_index` field (u32, stored in the _pad bytes of the FAT entry)
// records which file within the solid block this entry is (0-based), letting
// the extractor jump straight to the right slice without re-scanning.

// ---------------------------------------------------------------------------
// Solid block compression type tag (extends CompressionType to 0x05)
// ---------------------------------------------------------------------------
//
// FAT wire layout for solid entries (comp_type byte = 0x05):
//   bytes   0..239  — null-terminated relative path
//   byte  240       — 0x05 (solid_block)
//   bytes 241..244  — solid_index (u32 le): 0-based file position in the block
//   bytes 245..247  — _pad (zero)
//   bytes 248..255  — data_offset (u64 le)
//   bytes 256..263  — original_size (u64 le) — this file only
//   bytes 264..271  — compressed_size (u64 le) — total gz block size
//   bytes 272..275  — checksum (u32 le) — FNV-1a of original uncompressed bytes



/// Deep-archive solid-block builder.
///
/// Call `queueBinary` for every fallback/store file, `addMath`/`addResidual`
/// for math-routed files, then `flush` once to write the archive.
///
/// NOT thread-safe for queueBinary; call from the owning thread and let the
/// inner StreamingBuilder handle its own internal locking during appendBlock.
pub const SolidContainerBuilder = struct {
    // ---- Nested type declarations (must come before fields in Zig) ---- //

    const SolidFile = struct {
        path: []u8,   // heap-owned relative archive path
        raw:  []u8,   // heap-owned uncompressed bytes
        checksum: u32,
    };

    // Extension bucket: maps lowercased ".ext" -> list of files.
    const Bucket = struct {
        ext:   []u8,                      // heap-owned
        files: std.ArrayList(SolidFile),
        /// Sum of raw byte sizes currently queued in this bucket.
        raw_total: usize = 0,

        fn deinit(self: *Bucket, a: std.mem.Allocator) void {
            for (self.files.items) |f| { a.free(f.path); a.free(f.raw); }
            self.files.deinit();
            a.free(self.ext);
        }
    };

    /// Flush a bucket to disk once it accumulates this much raw data.
    /// Bounds three things at once: pack-time RAM (queued raw bytes), the size
    /// of the single concat+gzip allocation at flush, and the cost of
    /// extracting one file later (a solid entry decompresses its whole block).
    const SOLID_BUCKET_FLUSH_BYTES: usize = 48 * 1024 * 1024;
    /// Safety net across ALL buckets: real directory trees have thousands of
    /// distinct extensions, each below the per-bucket cap. Past this total,
    /// every bucket is flushed.
    const SOLID_TOTAL_FLUSH_BYTES: usize = 256 * 1024 * 1024;

    // ---- Fields ---- //

    allocator: std.mem.Allocator,
    /// All math/residual entries are flushed immediately into this builder.
    inner: StreamingBuilder,
    bucket_map:  std.StringHashMap(usize), // ext -> index in bucket_list
    bucket_list: std.ArrayList(Bucket),
    /// Pre-built raw FAT rows for solid entries (written verbatim by flush).
    solid_rows:  std.ArrayList([FAT_ENTRY_SIZE]u8),
    /// Unused — kept for structural symmetry; may be removed.
    solid_fat:   std.ArrayList(FatEntry),
    /// Raw bytes currently queued across all buckets (drives the global cap).
    queued_bytes: usize = 0,
    /// Codec + effort for solid blocks (set by the effort tier).
    comp: Compressor = .{},


    pub fn init(a: std.mem.Allocator) !SolidContainerBuilder {
        return .{
            .allocator   = a,
            .inner       = try StreamingBuilder.init(a),
            .bucket_map  = std.StringHashMap(usize).init(a),
            .bucket_list = std.ArrayList(Bucket).init(a),
            .solid_rows  = std.ArrayList([FAT_ENTRY_SIZE]u8).init(a),
            .solid_fat   = std.ArrayList(FatEntry).init(a),
        };
    }

    /// Set the codec/effort for both solid blocks and the inner per-file builder.
    pub fn setCompressor(self: *SolidContainerBuilder, comp: Compressor) void {
        self.comp = comp;
        self.inner.comp = comp;
    }

    pub fn deinit(self: *SolidContainerBuilder) void {
        self.inner.deinit();
        for (self.bucket_list.items) |*b| b.deinit(self.allocator);
        self.bucket_list.deinit();
        self.bucket_map.deinit();
        self.solid_rows.deinit();
        self.solid_fat.deinit();
    }

    // ------------------------------------------------------------------ //
    // Math pass-throughs (immediate flush to inner)
    // ------------------------------------------------------------------ //

    pub fn addMath(
        self: *SolidContainerBuilder,
        path: []const u8,
        bytecode: []const u8,
        original_size: u64,
        checksum: u32,
    ) !void {
        try self.inner.addMath(path, bytecode, original_size, checksum);
    }

    pub fn addResidual(
        self: *SolidContainerBuilder,
        path: []const u8,
        bytecode: []const u8,
        delta: []const u8,
        original_size: u64,
        checksum: u32,
    ) !void {
        try self.inner.addResidual(path, bytecode, delta, original_size, checksum);
    }

    // ------------------------------------------------------------------ //
    // Solid grouping path
    // ------------------------------------------------------------------ //

    /// Stage a file for solid-block grouping.  Call for every fallback/store
    /// candidate.  The actual compression is deferred until `flush()`.
    pub fn queueBinary(
        self: *SolidContainerBuilder,
        path: []const u8,
        raw: []const u8,
    ) !void {
        const csum = fnv1a(raw);

        // Build lowercase extension key.
        const ext_key: []const u8 = blk: {
            const base = std.fs.path.basename(path);
            if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot|
                break :blk base[dot..];
            break :blk "";
        };
        var ext_lower_buf: [64]u8 = undefined;
        const ext_lower = if (ext_key.len <= ext_lower_buf.len) lo: {
            for (ext_lower_buf[0..ext_key.len], ext_key) |*d, c|
                d.* = std.ascii.toLower(c);
            break :lo ext_lower_buf[0..ext_key.len];
        } else ext_key; // >64-char extension: treat as-is (pathological)

        // Find or create bucket.
        const bucket_idx: usize = if (self.bucket_map.get(ext_lower)) |i|
            i
        else blk: {
            const i = self.bucket_list.items.len;
            const owned = try self.allocator.dupe(u8, ext_lower);
            errdefer self.allocator.free(owned);
            try self.bucket_list.append(.{
                .ext   = owned,
                .files = std.ArrayList(SolidFile).init(self.allocator),
            });
            try self.bucket_map.put(self.bucket_list.items[i].ext, i);
            break :blk i;
        };

        const bucket = &self.bucket_list.items[bucket_idx];
        try bucket.files.append(.{
            .path     = try self.allocator.dupe(u8, path),
            .raw      = try self.allocator.dupe(u8, raw),
            .checksum = csum,
        });
        bucket.raw_total += raw.len;
        self.queued_bytes += raw.len;

        // Incremental flushing keeps memory bounded on real directory trees:
        // without it every queued file's raw bytes live in RAM until the final
        // flush, which on a multi-GB folder freezes or OOMs the host.
        if (bucket.raw_total >= SOLID_BUCKET_FLUSH_BYTES) {
            try self.flushOneBucket(bucket);
        } else if (self.queued_bytes >= SOLID_TOTAL_FLUSH_BYTES) {
            for (self.bucket_list.items) |*b| try self.flushOneBucket(b);
        }
    }

    // ------------------------------------------------------------------ //
    // Flush a single bucket into the temp file
    // ------------------------------------------------------------------ //

    fn flushOneBucket(self: *SolidContainerBuilder, bucket: *Bucket) !void {
        // The bucket's queued bytes are released no matter how we return: the
        // data either reached the temp file or the whole pack is failing anyway.
        defer {
            for (bucket.files.items) |f| {
                self.allocator.free(f.path);
                self.allocator.free(f.raw);
            }
            bucket.files.clearRetainingCapacity();
            self.queued_bytes -= bucket.raw_total;
            bucket.raw_total = 0;
        }
        try self.writeSolidBlock(bucket.files.items);
    }

    /// Write one solid block from `files`. Does NOT free or clear the files —
    /// the caller owns their lifetime.
    fn writeSolidBlock(self: *SolidContainerBuilder, files: []const SolidFile) !void {
        if (files.len == 0) return;

        // Single-file fast path: just gzip it normally (no solid overhead).
        if (files.len == 1) {
            const f = &files[0];
            _ = try self.inner.addBinary(f.path, f.raw);
            return;
        }

        // -----------------------------------------------------------
        // Build the solid block:
        //   [u32 le: N] [u64 le: size_0] … [u64 le: size_{N-1}]
        //   [raw_0 || raw_1 || … || raw_{N-1}]
        // Then gzip the whole thing as one stream.
        // -----------------------------------------------------------
        const n = files.len;
        const header_sz: usize = 4 + n * 8;
        var total_raw: usize = 0;
        for (files) |f| total_raw += f.raw.len;

        const concat = try self.allocator.alloc(u8, header_sz + total_raw);
        defer self.allocator.free(concat);

        std.mem.writeInt(u32, concat[0..4], @intCast(n), .little);
        for (files, 0..) |f, i|
            std.mem.writeInt(u64, concat[4 + i * 8 ..][0..8],
                @intCast(f.raw.len), .little);

        var dst: usize = header_sz;
        for (files) |f| {
            @memcpy(concat[dst..][0..f.raw.len], f.raw);
            dst += f.raw.len;
        }

        const gz = try self.comp.compress(concat, self.allocator);
        defer self.allocator.free(gz);

        // -----------------------------------------------------------
        // Write the compressed block exactly once to the temp file.
        // -----------------------------------------------------------
        const block_offset = self.inner.data_cursor;
        try self.inner.tmp_file.writeAll(gz);
        self.inner.data_cursor += gz.len;

        // -----------------------------------------------------------
        // Register one FAT row per file, all pointing at block_offset.
        // comp_type wire byte = 0x05 (solid_block).
        // Bytes 241..244 carry the solid_index (u32 le).
        // -----------------------------------------------------------
        for (files, 0..) |f, idx| {
            var row: [FAT_ENTRY_SIZE]u8 = std.mem.zeroes([FAT_ENTRY_SIZE]u8);
            if (f.path.len < MAX_PATH_LEN)
                @memcpy(row[0..f.path.len], f.path);
            row[240] = 0x05;                              // solid_block
            std.mem.writeInt(u32, row[241..245], @intCast(idx), .little);
            row[245] = @intFromEnum(self.comp.codec);     // codec for this block
            std.mem.writeInt(u64, row[248..256], block_offset, .little);
            std.mem.writeInt(u64, row[256..264], @intCast(f.raw.len), .little);
            std.mem.writeInt(u64, row[264..272], @intCast(gz.len), .little);
            std.mem.writeInt(u32, row[272..276], f.checksum, .little);
            try self.solid_rows.append(row);
        }
    }

    // ------------------------------------------------------------------ //
    // Final write
    // ------------------------------------------------------------------ //

    /// Flush all buckets and write the finished archive to `out_file`.
    pub fn flush(self: *SolidContainerBuilder, out_file: std.fs.File) !void {
        // Merge everything still queued — across ALL extensions — into shared
        // blocks of ≤ SOLID_BUCKET_FLUSH_BYTES, keeping bucket order so files
        // of the same type stay adjacent for the compressor. Without this
        // merge, rare extensions become single-file buckets and solid mode
        // degrades to exactly per-file gzip (no size win at all).
        {
            var pending = std.ArrayList(SolidFile).init(self.allocator);
            defer {
                for (pending.items) |f| {
                    self.allocator.free(f.path);
                    self.allocator.free(f.raw);
                }
                pending.deinit();
            }
            for (self.bucket_list.items) |*bucket| {
                for (bucket.files.items) |f| try pending.append(f);
                // Ownership of path/raw moved into `pending`.
                bucket.files.clearRetainingCapacity();
                self.queued_bytes -= bucket.raw_total;
                bucket.raw_total = 0;
            }

            var start: usize = 0;
            var acc: usize = 0;
            for (pending.items, 0..) |f, i| {
                acc += f.raw.len;
                if (acc >= SOLID_BUCKET_FLUSH_BYTES) {
                    try self.writeSolidBlock(pending.items[start .. i + 1]);
                    start = i + 1;
                    acc = 0;
                }
            }
            try self.writeSolidBlock(pending.items[start..]);
        }

        // Compute total FAT count = math/residual entries + solid entries.
        const math_count  = self.inner.fat.items.len;
        const solid_count = self.solid_rows.items.len;
        const fat_count: u32 = @intCast(math_count + solid_count);

        var bw = std.io.bufferedWriter(out_file.writer());
        const w = bw.writer();

        // Header + compressed FAT: math/residual rows then pre-built solid rows.
        var fat_buf = std.ArrayList(u8).init(self.allocator);
        defer fat_buf.deinit();
        for (self.inner.fat.items) |e| try fat_buf.appendSlice(&fatRow(e));
        for (self.solid_rows.items) |*row| try fat_buf.appendSlice(row);
        try writeHeaderAndFat(w, fat_count, fat_buf.items, 0, self.allocator);

        // Data region: stream temp file.
        try self.inner.tmp_file.seekTo(0);
        var chunk_buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = try self.inner.tmp_file.read(&chunk_buf);
            if (n == 0) break;
            try w.writeAll(chunk_buf[0..n]);
        }
        try bw.flush();
    }

    pub fn entryCount(self: *const SolidContainerBuilder) usize {
        return self.inner.fat.items.len + self.solid_rows.items.len;
    }

    pub fn dataBytes(self: *const SolidContainerBuilder) u64 {
        return self.inner.data_cursor;
    }
};

// ---------------------------------------------------------------------------
// SolidContainerReader — extracts files from a solid-block archive
// ---------------------------------------------------------------------------

/// Extends the standard Reader to handle comp_type = 0x05 (solid_block).
///
/// For a solid entry the data block contains the gzip of:
///   [u32 le: N] [u64 le: size_0] … [u64 le: size_{N-1}] [raw_0 || … || raw_{N-1}]
///
/// The FAT carries `solid_index` in bytes 241..244, letting us slice out
/// exactly the right file without decompressing the full block more than once
/// per unique block_offset.
pub const SolidReader = struct {
    reader: Reader,
    /// Cache: block_offset -> decompressed raw bytes (all files in the block).
    cache: std.AutoHashMap(u64, []u8),
    allocator: std.mem.Allocator,

    pub fn parse(data: []const u8, a: std.mem.Allocator) !SolidReader {
        return .{
            .reader    = try Reader.parse(data, a),
            .cache     = std.AutoHashMap(u64, []u8).init(a),
            .allocator = a,
        };
    }

    pub fn deinit(self: *SolidReader) void {
        var it = self.cache.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.cache.deinit();
        self.reader.deinit();
    }

    /// Extract a file by path, handling both regular and solid-block entries.
    pub fn extract(self: *SolidReader, path: []const u8, a: std.mem.Allocator) ![]u8 {
        // Find FAT entry.
        const entry = blk: {
            for (self.reader.fat) |*e| {
                if (std.mem.eql(u8, e.getPath(), path)) break :blk e;
            }
            return error.FileNotFound;
        };

        // Regular entry — delegate to the normal extractor.
        // Note: the raw FAT bytes carry comp_type; we read the wire byte via
        // the data region layout.  For solid we detect by checking the raw
        // byte stored in the path padding.  Since Reader.parse reads the byte
        // at row[240] into entry.comp_type via @enumFromInt, comp_type = 0x05
        // will fail the enum cast.  We catch that here.
        // Safer: re-read the wire byte from the original data.
        // For simplicity we use a sentinel: mark solid entries with .store
        // and rely on a parallel solid_meta table.
        //
        // The cleanest approach: peek at the raw FAT byte in `self.reader`'s
        // source slice.  We store a pointer to the data.
        //
        // ---- REVISED APPROACH ----
        // comp_type byte 0x05 is outside the declared enum range; @enumFromInt
        // on it is undefined behaviour.  The Reader.parse() call will return
        // error.InvalidEnumTag for 0x05 entries.  We pre-filter those rows in
        // parseSolid() below.  For non-solid entries fall through normally.
        _ = entry;
        return self.reader.extract(path, a);
    }
};

// Solid block extraction helper (standalone function).
//
// `block_gz`   — the raw gzip blob read from the data region
// `solid_index` — 0-based position of the desired file within the block
// `original_size` — expected byte count for this file (from FAT)
/// Decompress an entire solid block (header + concatenated payload).
/// Callers extracting many files from the same block should call this once
/// and slice with `sliceSolidFile` — re-decompressing per file is quadratic.
pub fn decompressSolidBlock(block_gz: []const u8, codec: Codec, a: std.mem.Allocator) ![]u8 {
    switch (codec) {
        .zstd => return zstdDecompressUnknown(block_gz, a),
        .gzip => {
            var all = std.ArrayList(u8).init(a);
            errdefer all.deinit();
            var fbs = std.io.fixedBufferStream(block_gz);
            try std.compress.gzip.decompress(fbs.reader(), all.writer());
            return all.toOwnedSlice();
        },
        // Solid blocks are only ever built with gzip/zstd (full mode, which
        // uses LZMA, doesn't bucket into solid blocks). Unreachable in practice.
        .lzma => return error.LzmaDecompressFailed,
    }
}

/// Slice one file out of a decompressed solid block.
pub fn sliceSolidFile(
    raw: []const u8,
    solid_index: u32,
    original_size: u64,
    a: std.mem.Allocator,
) ![]u8 {
    if (raw.len < 4) return error.TruncatedContainer;
    const n = std.mem.readInt(u32, raw[0..4], .little);
    if (solid_index >= n) return error.SolidIndexOutOfRange;
    if (raw.len < 4 + @as(usize, n) * 8) return error.TruncatedContainer;

    var payload_offset: usize = 4 + @as(usize, n) * 8; // start of payload
    for (0..solid_index) |i| {
        const sz = std.mem.readInt(u64, raw[4 + i * 8 ..][0..8], .little);
        payload_offset += @intCast(sz);
    }
    const file_sz = std.mem.readInt(u64, raw[4 + @as(usize, solid_index) * 8 ..][0..8], .little);

    if (payload_offset + file_sz > raw.len) return error.TruncatedContainer;
    if (file_sz != original_size) return error.SizeMismatch;

    return a.dupe(u8, raw[payload_offset..][0..file_sz]);
}

fn extractSolidEntry(
    block_gz: []const u8,
    solid_index: u32,
    original_size: u64,
    codec: Codec,
    a: std.mem.Allocator,
) ![]u8 {
    const raw = try decompressSolidBlock(block_gz, codec, a);
    defer a.free(raw);
    return sliceSolidFile(raw, solid_index, original_size, a);
}

// ---------------------------------------------------------------------------
// Container reader
// ---------------------------------------------------------------------------

/// Parses a .math archive from `data` (the full file in memory).
pub const Reader = struct {
    fat: []FatEntry,
    /// Slice of `data` that covers just the data region.
    data_region: []const u8,
    allocator: std.mem.Allocator,
    /// Container header flags (e.g. FLAG_FULL_ZIP).
    flags: u16 = 0,
    /// Shared dictionaries (slices into `data`); empty when FLAG_HAS_DICTS unset.
    /// The outer array is allocator-owned; the slices alias `data` (not freed).
    dicts: [][]const u8 = &[_][]const u8{},

    pub fn parse(data: []const u8, a: std.mem.Allocator) !Reader {
        if (data.len < HEADER_SIZE) return error.TruncatedContainer;

        // Header
        if (!std.mem.eql(u8, data[0..4], MAGIC)) return error.BadMagic;
        const ver = std.mem.readInt(u16, data[4..6], .little);
        if (ver != VERSION) return error.UnsupportedVersion;
        const fat_count = std.mem.readInt(u32, data[6..10], .little);
        const flags = std.mem.readInt(u16, data[10..12], .little);

        // Locate the FAT bytes. New archives gzip-compress the FAT (FLAG_FAT_GZIP)
        // with a u64 length prefix; legacy archives store it raw inline.
        const fat_size = FAT_ENTRY_SIZE * @as(usize, fat_count);
        var fat_decoded: ?[]u8 = null;
        defer if (fat_decoded) |fd| a.free(fd);
        var fat_blob: []const u8 = undefined;
        var data_start: usize = undefined;

        if (flags & FLAG_FAT_GZIP != 0) {
            if (data.len < HEADER_SIZE + 8) return error.TruncatedContainer;
            const comp_len: usize = @intCast(std.mem.readInt(u64, data[HEADER_SIZE..][0..8], .little));
            const comp_start = HEADER_SIZE + 8;
            if (data.len < comp_start + comp_len) return error.TruncatedContainer;
            var list = std.ArrayList(u8).init(a);
            errdefer list.deinit();
            var fbs = std.io.fixedBufferStream(data[comp_start..][0..comp_len]);
            try std.compress.gzip.decompress(fbs.reader(), list.writer());
            if (list.items.len != fat_size) return error.TruncatedContainer;
            fat_decoded = try list.toOwnedSlice();
            fat_blob = fat_decoded.?;
            data_start = comp_start + comp_len;
        } else {
            const fat_end = HEADER_SIZE + fat_size;
            if (data.len < fat_end) return error.TruncatedContainer;
            fat_blob = data[HEADER_SIZE..fat_end];
            data_start = fat_end;
        }

        // Dict section (between FAT and data region): [u32 count] then
        // [u32 len][bytes] per dict. Slices alias `data`; data_start advances
        // past it so per-entry data_offset values stay region-relative.
        var dicts: [][]const u8 = &[_][]const u8{};
        errdefer if (dicts.len > 0) a.free(dicts);
        if (flags & FLAG_HAS_DICTS != 0) {
            if (data.len < data_start + 4) return error.TruncatedContainer;
            const count: usize = @intCast(std.mem.readInt(u32, data[data_start..][0..4], .little));
            data_start += 4;
            const ds = try a.alloc([]const u8, count);
            errdefer a.free(ds);
            for (ds) |*slot| {
                if (data.len < data_start + 4) return error.TruncatedContainer;
                const dlen: usize = @intCast(std.mem.readInt(u32, data[data_start..][0..4], .little));
                data_start += 4;
                if (data.len < data_start + dlen) return error.TruncatedContainer;
                slot.* = data[data_start..][0..dlen];
                data_start += dlen;
            }
            dicts = ds;
        }

        // Parse FAT rows (280 bytes each). Layout:
        //   [0..239] path  [240] comp_type  [241..245] solid_index u32
        //   [245] codec  [248..256] data_offset  [256..264] original_size
        //   [264..272] compressed_size  [272..276] checksum u32
        const fat = try a.alloc(FatEntry, fat_count);
        errdefer a.free(fat);

        for (fat, 0..) |*entry, i| {
            const row = fat_blob[i * FAT_ENTRY_SIZE ..][0..FAT_ENTRY_SIZE];
            @memcpy(&entry.path, row[0..MAX_PATH_LEN]);
            entry.comp_type   = @enumFromInt(row[240]);
            entry.solid_index = std.mem.readInt(u32, row[241..245], .little);
            entry.codec       = std.meta.intToEnum(Codec, row[245]) catch .gzip;
            entry.data_offset = std.mem.readInt(u64, row[248..256], .little);
            entry.original_size    = std.mem.readInt(u64, row[256..264], .little);
            entry.compressed_size  = std.mem.readInt(u64, row[264..272], .little);
            entry.checksum    = std.mem.readInt(u32, row[272..276], .little);
        }

        return .{
            .fat = fat,
            .data_region = data[data_start..],
            .allocator = a,
            .flags = flags,
            .dicts = dicts,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.allocator.free(self.fat);
        if (self.dicts.len > 0) self.allocator.free(self.dicts);
    }

    /// Reconstruct the original bytes for `path` into a freshly allocated
    /// slice. Caller must free it.
    ///
    /// Supports all five compression types:
    ///   .math_bytecode   — run the VM, return synthesised pixels
    ///   .fallback_stream — gzip decompress
    ///   .store           — verbatim copy
    ///   .math_residual   — VM approx + gzip delta overlay
    ///   .solid_block     — decompress the shared gz block, slice out this file
    pub fn extract(self: *const Reader, path: []const u8, a: std.mem.Allocator) ![]u8 {
        const entry = self.findEntry(path) orelse return error.FileNotFound;
        const block = self.data_region[entry.data_offset..][0..entry.compressed_size];

        return switch (entry.comp_type) {
            .math_bytecode   => extractMath(block, entry.original_size, a),
            .fallback_stream => inflateBlock(block, entry.original_size, entry.codec, a),
            .store           => extractStore(block, entry.original_size, a),
            .math_residual   => extractResidual(block, entry.original_size, entry.codec, a),
            .math_blocks     => extractMathBlocks(block, entry.original_size, entry.codec, a),
            .math_filtered   => extractFiltered(block, entry.original_size, entry.codec, a),
            .math_columnar   => extractColumnar(block, entry.original_size, entry.codec, a),
            .math_image2d    => extractImage2D(block, entry.original_size, entry.codec, a),
            .math_dict       => blk: {
                if (entry.solid_index >= self.dicts.len) break :blk error.BadDictIndex;
                break :blk zstdDecompressUsingDict(block, entry.original_size, self.dicts[entry.solid_index], a);
            },
            .math_audio      => extractAudio(block, entry.original_size, entry.codec, a),
            .math_bcj2       => extractBcj2(block, entry.original_size, a),
            .math_cm         => cm.decompress(block, @intCast(entry.original_size), a),
            // A symlink's "contents" are its target path, stored verbatim.
            .symlink         => extractStore(block, entry.original_size, a),
            .solid_block     => extractSolidEntry(
                block,
                entry.solid_index,
                entry.original_size,
                entry.codec,
                a,
            ),
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

    // The canvas may exceed the file: the translator pads non-rectangular
    // lengths up to width×height and only the first original_size bytes are
    // the file. A canvas *smaller* than the file is still corruption.
    if (pixels.len < original_size) return error.SizeMismatch;

    const out = try a.alloc(u8, @intCast(original_size));
    @memcpy(out, pixels[0..@intCast(original_size)]);
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
fn extractResidual(block: []const u8, original_size: u64, codec: Codec, a: std.mem.Allocator) ![]u8 {
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
    const full = try machine.execute(bytecode);
    // Canvas ≥ file length (padded last row); the delta covers only the file.
    if (full.len < original_size) return error.SizeMismatch;
    const approx = full[0..@intCast(original_size)];

    // --- Decompress the delta (codec-aware) ---
    const delta = try inflateBlock(gz_delta, original_size, codec, a);
    defer a.free(delta);
    if (delta.len != original_size) return error.SizeMismatch;

    // --- Reconstruct: approx[i] +% delta[i] == original[i] ---
    const out = try a.alloc(u8, @intCast(original_size));
    for (out, approx, delta) |*o, ap, d| o.* = ap +% d;
    return out;
}

/// MATH_BLOCKS: per-block decomposition. Block layout:
///
///   [u32 le: block_size]
///   [u32 le: n_blocks]
///   [n_blocks bytes: kind per block — 0=literal 1=const 2=ramp 3=repeat]
///   [param stream: per non-literal block in order —
///      const: u8 value | ramp: u8 start, u8 step | repeat: u8 plen, plen bytes]
///   [u64 le: comp_lit_len]
///   [comp_lit_len bytes: codec-compressed concatenation of literal blocks]
///
/// Reconstruction is pure integer formula evaluation per analytic block plus
/// one decompression of the literal stream — bit-perfect by construction.
fn extractMathBlocks(block: []const u8, original_size: u64, codec: Codec, a: std.mem.Allocator) ![]u8 {
    if (block.len < 8) return error.TruncatedContainer;
    const bs: usize = std.mem.readInt(u32, block[0..4], .little);
    const n_blocks: usize = std.mem.readInt(u32, block[4..8], .little);
    if (bs == 0 or n_blocks == 0) return error.TruncatedContainer;
    if (block.len < 8 + n_blocks) return error.TruncatedContainer;
    const kinds = block[8..][0..n_blocks];

    const out_len: usize = @intCast(original_size);
    if ((n_blocks - 1) * bs >= out_len or n_blocks * bs < out_len)
        return error.SizeMismatch;

    // Pass 1 over kinds: size the param stream and the literal stream.
    var p: usize = 8 + n_blocks; // param cursor into `block`
    var lit_total: usize = 0;
    for (kinds, 0..) |k, i| {
        const blk_len = @min(bs, out_len - i * bs);
        switch (k) {
            0 => lit_total += blk_len,
            1 => p += 1,
            2 => p += 2,
            3 => {
                if (p >= block.len) return error.TruncatedContainer;
                p += 1 + @as(usize, block[p]);
            },
            else => return error.TruncatedContainer,
        }
        if (p > block.len) return error.TruncatedContainer;
    }

    // Literal stream.
    if (block.len < p + 8) return error.TruncatedContainer;
    const comp_lit_len = std.mem.readInt(u64, block[p..][0..8], .little);
    if (block.len < p + 8 + comp_lit_len) return error.TruncatedContainer;
    const lits: []u8 = if (lit_total > 0)
        try inflateBlock(block[p + 8 ..][0..@intCast(comp_lit_len)], lit_total, codec, a)
    else
        &.{};
    defer if (lit_total > 0) a.free(lits);
    if (lits.len != lit_total) return error.SizeMismatch;

    // Pass 2: synthesize.
    const out = try a.alloc(u8, out_len);
    errdefer a.free(out);
    p = 8 + n_blocks;
    var lit_off: usize = 0;
    for (kinds, 0..) |k, i| {
        const start = i * bs;
        const dst = out[start..@min(start + bs, out_len)];
        switch (k) {
            0 => {
                @memcpy(dst, lits[lit_off..][0..dst.len]);
                lit_off += dst.len;
            },
            1 => {
                @memset(dst, block[p]);
                p += 1;
            },
            2 => {
                const rs = block[p];
                const step = block[p + 1];
                p += 2;
                for (dst, 0..) |*o, j| o.* = rs +% (step *% @as(u8, @truncate(j)));
            },
            3 => {
                const plen: usize = block[p];
                const pat = block[p + 1 ..][0..plen];
                p += 1 + plen;
                for (dst, 0..) |*o, j| o.* = pat[j % plen];
            },
            else => unreachable, // validated in pass 1
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Reversible math filters
//
// A filter is a length-preserving, exactly-invertible integer transform run
// BEFORE the LZ/entropy stage. It doesn't shrink anything itself — it rewrites
// the bytes so the compressor finds more redundancy. This is how xz beats
// plain DEFLATE on executables (its BCJ filter) and on smooth data (its delta
// filter): "use math to make the file cheaper to compress" in the literal
// sense. Every filter here is bijective, so reconstruction is bit-perfect.
// ---------------------------------------------------------------------------

pub const Filter = enum(u8) {
    none = 0,
    delta1 = 1, // byte delta, distance 1 (counters, gradients, audio)
    delta2 = 2, // distance 2 (16-bit samples)
    delta4 = 3, // distance 4 (32-bit samples / RGBA)
    bcj_x86 = 4, // x86 call/jump relative→absolute (executables, .so/.dll)
};

fn deltaDistance(f: Filter) usize {
    return switch (f) {
        .delta1 => 1,
        .delta2 => 2,
        .delta4 => 4,
        else => 0,
    };
}

/// x86 CALL/JMP rel32 ↔ absolute converter. The same function called from many
/// sites has a different rel32 at each site (rel = target − source) but the
/// same absolute target, so converting rel→abs makes those call sites
/// byte-identical and the LZ stage matches them.
///
/// Reversibility: the scan advances by 5 past a hit and by 1 otherwise, and it
/// never modifies the E8/E9 opcode byte — only the 4 operand bytes, which the
/// skip then steps over. So encode and decode land on exactly the same
/// positions and the transform is an exact involution pair.
fn bcjX86(buf: []u8, encode: bool) void {
    if (buf.len < 5) return;
    var i: usize = 0;
    while (i + 5 <= buf.len) {
        if (buf[i] == 0xE8 or buf[i] == 0xE9) {
            const p = buf[i + 1 ..][0..4];
            const rel = std.mem.readInt(u32, p, .little);
            const adj: u32 = @truncate(i + 5);
            std.mem.writeInt(u32, p, if (encode) rel +% adj else rel -% adj, .little);
            i += 5;
        } else {
            i += 1;
        }
    }
}

/// Forward transform: returns a fresh length-preserving buffer (caller frees).
pub fn applyFilter(f: Filter, data: []const u8, a: std.mem.Allocator) ![]u8 {
    const out = try a.alloc(u8, data.len);
    errdefer a.free(out);
    switch (f) {
        .none => @memcpy(out, data),
        .delta1, .delta2, .delta4 => {
            const d = deltaDistance(f);
            for (out, 0..) |*o, i| o.* = if (i < d) data[i] else data[i] -% data[i - d];
        },
        .bcj_x86 => {
            @memcpy(out, data);
            bcjX86(out, true);
        },
    }
    return out;
}

/// Inverse transform, in place.
pub fn unapplyFilter(f: Filter, buf: []u8) void {
    switch (f) {
        .none => {},
        .delta1, .delta2, .delta4 => {
            const d = deltaDistance(f);
            var i: usize = d;
            while (i < buf.len) : (i += 1) buf[i] = buf[i] +% buf[i - d];
        },
        .bcj_x86 => bcjX86(buf, false),
    }
}

/// MATH_FILTERED: [u8 filter_id][codec-compressed filtered bytes].
/// Decompress to original_size, then invert the filter — bit-perfect.
fn extractFiltered(block: []const u8, original_size: u64, codec: Codec, a: std.mem.Allocator) ![]u8 {
    if (block.len < 1) return error.TruncatedContainer;
    const filter = std.meta.intToEnum(Filter, block[0]) catch return error.TruncatedContainer;
    const filtered = try inflateBlock(block[1..], original_size, codec, a);
    errdefer a.free(filtered);
    if (filtered.len != original_size) return error.SizeMismatch;
    unapplyFilter(filter, filtered);
    return filtered;
}

// ---------------------------------------------------------------------------
// Columnar (AoS -> SoA) transform
//
// Record arrays — vertex/index buffers, float tables, sensor logs — store
// fields interleaved per record (array-of-structs). Transposing to put every
// record's field-k together (struct-of-arrays) groups like-typed, slowly-
// varying bytes so the codec's matches and contexts line up across records.
// This is genuinely absent from LZ streams (xz/zstd/brotli don't transpose),
// so it's net-new ground vs every general-purpose archiver. Pure index
// permutation -> exact involution, no verify step needed.
//
// Layout: R = len / stride records, tail = len % stride bytes kept verbatim.
//   out = [col 0 of every record][col 1 ...]...[col stride-1 ...][tail bytes]
// ---------------------------------------------------------------------------

pub fn columnarForward(data: []const u8, stride: usize, a: std.mem.Allocator) ![]u8 {
    const out = try a.alloc(u8, data.len);
    errdefer a.free(out);
    const rows = data.len / stride;
    const body = rows * stride;
    var o: usize = 0;
    var c: usize = 0;
    while (c < stride) : (c += 1) {
        var r: usize = 0;
        var src = c;
        while (r < rows) : (r += 1) {
            out[o] = data[src];
            o += 1;
            src += stride;
        }
    }
    // Tail (leftover bytes that don't fill a record) verbatim.
    @memcpy(out[body..], data[body..]);
    return out;
}

fn columnarInverse(t: []const u8, stride: usize, a: std.mem.Allocator) ![]u8 {
    const out = try a.alloc(u8, t.len);
    errdefer a.free(out);
    const rows = t.len / stride;
    const body = rows * stride;
    var o: usize = 0;
    var c: usize = 0;
    while (c < stride) : (c += 1) {
        var r: usize = 0;
        var dst = c;
        while (r < rows) : (r += 1) {
            out[dst] = t[o];
            o += 1;
            dst += stride;
        }
    }
    @memcpy(out[body..], t[body..]);
    return out;
}

/// MATH_COLUMNAR: [u16 le stride][codec-compressed transposed bytes].
/// Decompress to original_size, then inverse-transpose — bit-perfect.
fn extractColumnar(block: []const u8, original_size: u64, codec: Codec, a: std.mem.Allocator) ![]u8 {
    if (block.len < 2) return error.TruncatedContainer;
    const stride: usize = std.mem.readInt(u16, block[0..2], .little);
    if (stride == 0) return error.TruncatedContainer;
    const transposed = try inflateBlock(block[2..], original_size, codec, a);
    defer a.free(transposed);
    if (transposed.len != original_size) return error.SizeMismatch;
    return columnarInverse(transposed, stride, a);
}

test "columnar transform is an exact involution" {
    const a = testing.allocator;
    var rng = @import("math_gen.zig").XorShift32.init(0xC0FF);
    // Fake 12-byte vertex records: 3 floats-ish fields with slow variation.
    const recs = 5000;
    const stride = 12;
    const data = try a.alloc(u8, recs * stride + 7); // +7 tail
    defer a.free(data);
    for (0..recs) |r| {
        for (0..stride) |c| data[r * stride + c] = @truncate(r / (c + 1) +% c * 7);
    }
    for (data[recs * stride ..]) |*p| p.* = rng.nextByte();
    const fwd = try columnarForward(data, stride, a);
    defer a.free(fwd);
    const back = try columnarInverse(fwd, stride, a);
    defer a.free(back);
    try testing.expectEqualSlices(u8, data, back);
}

// ---------------------------------------------------------------------------
// 2D MED image predictor (LOCO-I / JPEG-LS, also PNG's "Paeth"-family idea)
//
// Raw raster (TGA/PGM/PPM/uncompressed textures) is 2D-correlated: a pixel is
// close to its left, up, and up-left neighbors. The Median Edge Detector picks
// min/max/gradient based on those three, and we store the residual
// (pixel -% prediction). On smooth images the residuals collapse to near-zero
// runs the codec crushes — and crucially, general compressors (xz/zstd/brotli)
// have NO 2D predictor, only 1D delta, so this is net-new ground on raster.
// Per-channel (stride = channels); exact involution (raster order, neighbors
// are always already-known).
// ---------------------------------------------------------------------------

fn medPredict(a: u8, b: u8, c: u8) u8 {
    const mx = @max(a, b);
    const mn = @min(a, b);
    if (c >= mx) return mn;
    if (c <= mn) return mx;
    // Gradient predictor a+b-c, clamped to [0,255] (standard MED; clamping
    // predicts better than wrapping and is equally reversible — deterministic).
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    if (p < 0) return 0;
    if (p > 255) return 255;
    return @intCast(p);
}

pub fn medForward(src: []const u8, w: u32, h: u32, ch: u8, a: std.mem.Allocator) ![]u8 {
    const out = try a.alloc(u8, src.len);
    errdefer a.free(out);
    const c: usize = ch;
    const row = @as(usize, w) * c;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            var k: usize = 0;
            while (k < c) : (k += 1) {
                const idx = y * row + x * c + k;
                const left = if (x > 0) src[idx - c] else 0;
                const up = if (y > 0) src[idx - row] else 0;
                const ul = if (x > 0 and y > 0) src[idx - row - c] else 0;
                out[idx] = src[idx] -% medPredict(left, up, ul);
            }
        }
    }
    return out;
}

/// Inverse MED, in place: `buf` enters as residuals, leaves as pixels.
fn medInverse(buf: []u8, w: u32, h: u32, ch: u8) void {
    const c: usize = ch;
    const row = @as(usize, w) * c;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            var k: usize = 0;
            while (k < c) : (k += 1) {
                const idx = y * row + x * c + k;
                const left = if (x > 0) buf[idx - c] else 0;
                const up = if (y > 0) buf[idx - row] else 0;
                const ul = if (x > 0 and y > 0) buf[idx - row - c] else 0;
                buf[idx] = buf[idx] +% medPredict(left, up, ul);
            }
        }
    }
}

/// MATH_IMAGE2D block layout:
///   [u32 header_len][u32 footer_len][u32 width][u32 height][u8 channels][T]
/// where T (length == original_size, codec-compressed) is
///   raw header ++ medForward(pixels) ++ raw footer.
/// Header and footer (e.g. a TGA 2.0 footer) stay verbatim; only the pixel
/// region is predicted.
fn extractImage2D(block: []const u8, original_size: u64, codec: Codec, a: std.mem.Allocator) ![]u8 {
    if (block.len < 17) return error.TruncatedContainer;
    const header_len: usize = std.mem.readInt(u32, block[0..4], .little);
    const footer_len: usize = std.mem.readInt(u32, block[4..8], .little);
    const w = std.mem.readInt(u32, block[8..12], .little);
    const h = std.mem.readInt(u32, block[12..16], .little);
    const ch = block[16];
    if (ch == 0 or w == 0 or h == 0) return error.TruncatedContainer;
    const pixels = @as(u64, w) * h * ch;
    if (header_len + pixels + footer_len != original_size) return error.SizeMismatch;

    const t = try inflateBlock(block[17..], original_size, codec, a);
    errdefer a.free(t);
    if (t.len != original_size) return error.SizeMismatch;
    // Header (front) and footer (back) are verbatim; invert MED over the pixels.
    medInverse(t[header_len .. header_len + @as(usize, @intCast(pixels))], w, h, ch);
    return t;
}

// ---------------------------------------------------------------------------
// Fixed-order linear predictors (FLAC / Shorten family) for raw PCM audio.
//
// 16-bit PCM samples are strongly correlated sample-to-sample; a fixed integer
// predictor on the SAMPLE stream collapses smooth waveforms to small residuals.
// General compressors only have byte-level delta — they can't predict across a
// 2-byte sample or per channel — so this is net-new ground on audio, the same
// way the 2D MED predictor is on raster. It's a per-entry transform, so it
// stays live (random access). Stereo is deinterleaved per channel before
// prediction (residuals stored channel-major). Wrapping i16 arithmetic makes it
// an exact involution: residual r = wrap(x - pred), reconstruction wrap(r + pred).
// Order 0..3 are the standard FLAC fixed predictors; warm-up history is 0 (the
// inverse uses the same zero history, so it stays exact).
// ---------------------------------------------------------------------------

inline fn lpcPredict(order: u8, h1: i32, h2: i32, h3: i32) i32 {
    return switch (order) {
        1 => h1,
        2 => 2 * h1 - h2,
        3 => 3 * h1 - 3 * h2 + h3,
        else => 0,
    };
}

inline fn wrapI16(v: i32) i16 {
    return @bitCast(@as(u16, @truncate(@as(u32, @bitCast(v)))));
}

/// Deinterleave by channel and apply the order-`order` fixed predictor; output
/// is channel-major residuals (same byte length as input). Trailing bytes that
/// don't fill a full per-channel sample row are copied verbatim.
pub fn lpcForward(data: []const u8, channels: u8, order: u8, a: std.mem.Allocator) ![]u8 {
    const out = try a.alloc(u8, data.len);
    errdefer a.free(out);
    const ch: usize = channels;
    const n_total = data.len / 2;
    const n_per = n_total / ch;
    const body = n_per * ch * 2;
    var c: usize = 0;
    while (c < ch) : (c += 1) {
        var h1: i32 = 0;
        var h2: i32 = 0;
        var h3: i32 = 0;
        var k: usize = 0;
        while (k < n_per) : (k += 1) {
            const in_off = (k * ch + c) * 2;
            const x: i32 = @as(i16, @bitCast(std.mem.readInt(u16, data[in_off..][0..2], .little)));
            const pred = lpcPredict(order, h1, h2, h3);
            const r = wrapI16(x - pred);
            const out_off = (c * n_per + k) * 2;
            std.mem.writeInt(u16, out[out_off..][0..2], @bitCast(r), .little);
            h3 = h2;
            h2 = h1;
            h1 = x;
        }
    }
    @memcpy(out[body..], data[body..]);
    return out;
}

/// Inverse of lpcForward: channel-major residuals -> interleaved PCM samples.
fn lpcInverse(res: []const u8, channels: u8, order: u8, a: std.mem.Allocator) ![]u8 {
    const out = try a.alloc(u8, res.len);
    errdefer a.free(out);
    const ch: usize = channels;
    const n_total = res.len / 2;
    const n_per = n_total / ch;
    const body = n_per * ch * 2;
    var c: usize = 0;
    while (c < ch) : (c += 1) {
        var h1: i32 = 0;
        var h2: i32 = 0;
        var h3: i32 = 0;
        var k: usize = 0;
        while (k < n_per) : (k += 1) {
            const in_off = (c * n_per + k) * 2;
            const r: i32 = @as(i16, @bitCast(std.mem.readInt(u16, res[in_off..][0..2], .little)));
            const pred = lpcPredict(order, h1, h2, h3);
            const x = wrapI16(r + pred);
            const out_off = (k * ch + c) * 2;
            std.mem.writeInt(u16, out[out_off..][0..2], @bitCast(x), .little);
            h3 = h2;
            h2 = h1;
            h1 = x;
        }
    }
    @memcpy(out[body..], res[body..]);
    return out;
}

/// MATH_AUDIO block layout:
///   [u32 header_len][u32 data_len][u8 channels][u8 order][T]
/// where T (len == original_size, codec-compressed) is
///   raw header ++ lpcForward(samples) ++ raw trailer.
/// The WAV header and any post-data chunks stay verbatim; only the PCM sample
/// region is predicted.
fn extractAudio(block: []const u8, original_size: u64, codec: Codec, a: std.mem.Allocator) ![]u8 {
    if (block.len < 10) return error.TruncatedContainer;
    const header_len: usize = std.mem.readInt(u32, block[0..4], .little);
    const data_len: usize = std.mem.readInt(u32, block[4..8], .little);
    const channels = block[8];
    const order = block[9];
    if (channels == 0) return error.TruncatedContainer;
    if (@as(u64, header_len) + data_len > original_size) return error.SizeMismatch;

    const t = try inflateBlock(block[10..], original_size, codec, a);
    errdefer a.free(t);
    if (t.len != original_size) return error.SizeMismatch;
    const samples = try lpcInverse(t[header_len .. header_len + data_len], channels, order, a);
    defer a.free(samples);
    @memcpy(t[header_len .. header_len + data_len], samples);
    return t;
}

test "LPC fixed predictors are exact involutions (mono + stereo, all orders)" {
    const a = testing.allocator;
    var rng = @import("math_gen.zig").XorShift32.init(0xA0D1);
    for ([_]u8{ 1, 2 }) |channels| {
        // Smooth-ish waveform + a little noise, interleaved across channels.
        const n_per: usize = 4000;
        const ch: usize = channels;
        const data = try a.alloc(u8, n_per * ch * 2 + 3); // +3 ragged tail
        defer a.free(data);
        var k: usize = 0;
        while (k < n_per) : (k += 1) {
            var c: usize = 0;
            while (c < ch) : (c += 1) {
                const phase = @as(f32, @floatFromInt(k)) * 0.05 + @as(f32, @floatFromInt(c));
                const s: i16 = @intFromFloat(@sin(phase) * 8000.0 + @as(f32, @floatFromInt(rng.nextByte() & 7)));
                std.mem.writeInt(u16, data[(k * ch + c) * 2 ..][0..2], @bitCast(s), .little);
            }
        }
        for (data[n_per * ch * 2 ..]) |*p| p.* = rng.nextByte();
        for ([_]u8{ 0, 1, 2, 3 }) |order| {
            const res = try lpcForward(data, channels, order, a);
            defer a.free(res);
            const back = try lpcInverse(res, channels, order, a);
            defer a.free(back);
            try testing.expectEqualSlices(u8, data, back);
        }
    }
}

test "2D MED predictor is an exact involution" {
    const a = testing.allocator;
    var rng = @import("math_gen.zig").XorShift32.init(0x2D2D);
    const w: u32 = 64;
    const h: u32 = 48;
    const ch: u8 = 3;
    const pixels = try a.alloc(u8, w * h * ch);
    defer a.free(pixels);
    // Smooth gradient + a little noise (a plausible image).
    for (0..h) |y| {
        for (0..w) |x| {
            for (0..ch) |k| {
                const v = (x * 3 + y * 2 + k * 40) & 0xFF;
                pixels[(y * w + x) * ch + k] = @truncate(v +% (rng.nextByte() & 3));
            }
        }
    }
    const res = try medForward(pixels, w, h, ch, a);
    defer a.free(res);
    medInverse(res, w, h, ch);
    try testing.expectEqualSlices(u8, pixels, res);
}

test "filters are exact involutions" {
    const a = testing.allocator;
    var rng = @import("math_gen.zig").XorShift32.init(0x5151);
    const data = try a.alloc(u8, 9000);
    defer a.free(data);
    // Mixed content: a gradient region, a random region, and some E8 sequences.
    for (data, 0..) |*p, i| p.* = @truncate(i / 4);
    for (data[3000..6000]) |*p| p.* = rng.nextByte();
    var k: usize = 6000;
    while (k + 5 < data.len) : (k += 7) {
        data[k] = 0xE8;
        std.mem.writeInt(u32, data[k + 1 ..][0..4], rng.next(), .little);
    }
    for ([_]Filter{ .delta1, .delta2, .delta4, .bcj_x86 }) |f| {
        const fwd = try applyFilter(f, data, a);
        defer a.free(fwd);
        unapplyFilter(f, fwd);
        try testing.expectEqualSlices(u8, data, fwd);
    }
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

/// DEFLATE effort level for gzip. Mirrors std.compress.flate.deflate.Level so
/// callers (and the C-ABI effort tier) can pick fast/default/best.
pub const GzipLevel = std.compress.flate.deflate.Level;

pub fn gzipCompress(data: []const u8, a: std.mem.Allocator, level: GzipLevel) ![]u8 {
    var buf = std.ArrayList(u8).init(a);
    errdefer buf.deinit();
    var fbs = std.io.fixedBufferStream(data);
    try std.compress.gzip.compress(fbs.reader(), buf.writer(), .{ .level = level });
    return buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// zstd backend (libzstd) — modern entropy coder, beats DEFLATE on ~everything.
// Zig std ships only a zstd decoder, so we bind libzstd's C API directly.
// ---------------------------------------------------------------------------

extern fn ZSTD_compressBound(srcSize: usize) usize;
extern fn ZSTD_compress(dst: [*]u8, dstCap: usize, src: [*]const u8, srcSize: usize, level: c_int) usize;
extern fn ZSTD_decompress(dst: [*]u8, dstCap: usize, src: [*]const u8, srcSize: usize) usize;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_getFrameContentSize(src: [*]const u8, srcSize: usize) u64;

const ZSTD_CONTENTSIZE_ERROR: u64 = std.math.maxInt(u64) - 1; // (size_t)-2
const ZSTD_CONTENTSIZE_UNKNOWN: u64 = std.math.maxInt(u64); // (size_t)-1

// Streaming compression (CStream API) — used by addZstdStreamingFile so the
// full-mode tar payload is zstd'd without loading it into memory.
const ZSTD_inBuffer = extern struct { src: ?*const anyopaque, size: usize, pos: usize };
const ZSTD_outBuffer = extern struct { dst: ?*anyopaque, size: usize, pos: usize };
extern fn ZSTD_createCCtx() ?*anyopaque;
extern fn ZSTD_freeCCtx(cctx: ?*anyopaque) usize;
extern fn ZSTD_CCtx_setParameter(cctx: ?*anyopaque, param: c_int, value: c_int) usize;
extern fn ZSTD_CCtx_setPledgedSrcSize(cctx: ?*anyopaque, pledged: u64) usize;
extern fn ZSTD_compressStream2(cctx: ?*anyopaque, out: *ZSTD_outBuffer, in: *ZSTD_inBuffer, endOp: c_int) usize;
const ZSTD_c_compressionLevel: c_int = 100;
const ZSTD_c_windowLog: c_int = 101;
const ZSTD_c_enableLongDistanceMatching: c_int = 160;
const ZSTD_c_nbWorkers: c_int = 400;
const ZSTD_e_continue: c_int = 0;
const ZSTD_e_end: c_int = 2;

pub fn zstdCompress(data: []const u8, a: std.mem.Allocator, level: c_int) ![]u8 {
    const bound = ZSTD_compressBound(data.len);
    const buf = try a.alloc(u8, bound);
    defer a.free(buf);
    const n = ZSTD_compress(buf.ptr, bound, data.ptr, data.len, level);
    if (ZSTD_isError(n) != 0) return error.ZstdCompressFailed;
    return a.dupe(u8, buf[0..n]);
}

/// Decompress a zstd block whose original size is known (from the FAT).
pub fn zstdDecompress(data: []const u8, original_size: u64, a: std.mem.Allocator) ![]u8 {
    const out = try a.alloc(u8, @intCast(original_size));
    errdefer a.free(out);
    const n = ZSTD_decompress(out.ptr, out.len, data.ptr, data.len);
    if (ZSTD_isError(n) != 0) return error.ZstdDecompressFailed;
    if (n != original_size) return error.SizeMismatch;
    return out;
}

/// Decompress a zstd block whose original size is read from the frame header
/// (used for solid blocks, where the framed-payload size isn't in the FAT).
pub fn zstdDecompressUnknown(data: []const u8, a: std.mem.Allocator) ![]u8 {
    const content = ZSTD_getFrameContentSize(data.ptr, data.len);
    if (content == ZSTD_CONTENTSIZE_ERROR or content == ZSTD_CONTENTSIZE_UNKNOWN)
        return error.ZstdDecompressFailed;
    const out = try a.alloc(u8, @intCast(content));
    errdefer a.free(out);
    const n = ZSTD_decompress(out.ptr, out.len, data.ptr, data.len);
    if (ZSTD_isError(n) != 0) return error.ZstdDecompressFailed;
    return out;
}

// ---------------------------------------------------------------------------
// zstd dictionary API (ZSTD_*_usingDict) + dictionary trainer (ZDICT). A
// dictionary is a shared prefix the codec primes its window with before each
// frame, so many similar small files compress as if they could reference one
// another — cross-file sharing WITHOUT a solid block. Each frame still decodes
// on its own (random access), which is what keeps the live (regular) mode live.
// ---------------------------------------------------------------------------
extern fn ZSTD_createDCtx() ?*anyopaque;
extern fn ZSTD_freeDCtx(dctx: ?*anyopaque) usize;
extern fn ZSTD_compress_usingDict(
    cctx: ?*anyopaque,
    dst: [*]u8,
    dstCap: usize,
    src: [*]const u8,
    srcSize: usize,
    dict: [*]const u8,
    dictSize: usize,
    level: c_int,
) usize;
extern fn ZSTD_decompress_usingDict(
    dctx: ?*anyopaque,
    dst: [*]u8,
    dstCap: usize,
    src: [*]const u8,
    srcSize: usize,
    dict: [*]const u8,
    dictSize: usize,
) usize;
extern fn ZDICT_trainFromBuffer(
    dictBuffer: [*]u8,
    dictBufferCapacity: usize,
    samplesBuffer: [*]const u8,
    samplesSizes: [*]const usize,
    nbSamples: c_uint,
) usize;
extern fn ZDICT_isError(code: usize) c_uint;

/// Compress `data` as a single zstd frame primed with `dict`. Returns owned bytes.
pub fn zstdCompressUsingDict(data: []const u8, dict: []const u8, level: c_int, a: std.mem.Allocator) ![]u8 {
    const cctx = ZSTD_createCCtx() orelse return error.ZstdCompressFailed;
    defer _ = ZSTD_freeCCtx(cctx);
    const bound = ZSTD_compressBound(data.len);
    const buf = try a.alloc(u8, bound);
    defer a.free(buf);
    const n = ZSTD_compress_usingDict(cctx, buf.ptr, bound, data.ptr, data.len, dict.ptr, dict.len, level);
    if (ZSTD_isError(n) != 0) return error.ZstdCompressFailed;
    return a.dupe(u8, buf[0..n]);
}

/// Decompress a dict-primed zstd frame of known original size (from the FAT).
pub fn zstdDecompressUsingDict(data: []const u8, original_size: u64, dict: []const u8, a: std.mem.Allocator) ![]u8 {
    const dctx = ZSTD_createDCtx() orelse return error.ZstdDecompressFailed;
    defer _ = ZSTD_freeDCtx(dctx);
    const out = try a.alloc(u8, @intCast(original_size));
    errdefer a.free(out);
    const n = ZSTD_decompress_usingDict(dctx, out.ptr, out.len, data.ptr, data.len, dict.ptr, dict.len);
    if (ZSTD_isError(n) != 0) return error.ZstdDecompressFailed;
    if (n != original_size) return error.SizeMismatch;
    return out;
}

/// Train a zstd dictionary from `samples` (concatenated) with `sizes` giving
/// each sample's length. Returns owned dict bytes, or null when training fails
/// (too few/too-similar samples — ZDICT needs a minimum corpus). `capacity` is
/// the target dictionary size; the trainer returns whatever fits within it.
pub fn trainDict(
    samples: []const u8,
    sizes: []const usize,
    capacity: usize,
    a: std.mem.Allocator,
) !?[]u8 {
    if (sizes.len == 0 or samples.len == 0 or capacity == 0) return null;
    const buf = try a.alloc(u8, capacity);
    errdefer a.free(buf);
    const n = ZDICT_trainFromBuffer(buf.ptr, capacity, samples.ptr, sizes.ptr, @intCast(sizes.len));
    if (ZDICT_isError(n) != 0) {
        a.free(buf);
        return null;
    }
    return try a.realloc(buf, n);
}

// ---------------------------------------------------------------------------
// LZMA / xz backend (liblzma) — stronger model than zstd (range coder +
// adaptive bit-contexts + match model). Used by full mode where the extra
// ratio is worth the slower, heavier compression. One-shot buffer API only:
// no lzma_stream struct (ABI-fragile) crosses the boundary, just three stable
// C functions. Full-mode decode already loads the whole tar into memory, so
// one-shot decode fits the existing memory profile.
// ---------------------------------------------------------------------------

extern fn lzma_stream_buffer_bound(uncompressed_size: usize) usize;
extern fn lzma_easy_buffer_encode(
    preset: u32,
    check: c_int,
    allocator: ?*const anyopaque,
    in: [*]const u8,
    in_size: usize,
    out: [*]u8,
    out_pos: *usize,
    out_size: usize,
) c_int;
extern fn lzma_stream_buffer_decode(
    memlimit: *u64,
    flags: u32,
    allocator: ?*const anyopaque,
    in: [*]const u8,
    in_pos: *usize,
    in_size: usize,
    out: [*]u8,
    out_pos: *usize,
    out_size: usize,
) c_int;

const LZMA_OK: c_int = 0;
const LZMA_PRESET_EXTREME: u32 = 0x8000_0000;
const LZMA_CHECK_NONE: c_int = 0; // container carries its own FNV-1a checksum

/// LZMA preset for an effort tier: 6 balanced, 9|extreme for Max.
pub fn lzmaPreset(tier: u8) u32 {
    return switch (tier) {
        0 => 2,
        2 => 9 | LZMA_PRESET_EXTREME,
        else => 6,
    };
}

pub fn lzmaCompress(data: []const u8, a: std.mem.Allocator, preset: u32) ![]u8 {
    const bound = lzma_stream_buffer_bound(data.len);
    const buf = try a.alloc(u8, bound);
    defer a.free(buf);
    var out_pos: usize = 0;
    const rc = lzma_easy_buffer_encode(
        preset, LZMA_CHECK_NONE, null,
        data.ptr, data.len, buf.ptr, &out_pos, buf.len,
    );
    if (rc != LZMA_OK) return error.LzmaCompressFailed;
    return a.dupe(u8, buf[0..out_pos]);
}

// Filter-chain encode with liblzma's own x86 BCJ in front of LZMA2 — the same
// thing `xz --x86` does, using xz's mature, conservative BCJ (transforms a
// CALL/JMP operand only when it looks like a real near address), which beats
// the hand-rolled byte filter. The .xz stream header self-describes the chain,
// so lzmaDecompress (lzma_stream_buffer_decode) reverses it with no extra code.
const lzma_filter = extern struct { id: u64, options: ?*anyopaque };
const lzma_options_lzma = extern struct {
    dict_size: u32,
    preset_dict: ?[*]const u8,
    preset_dict_size: u32,
    lc: u32,
    lp: u32,
    pb: u32,
    mode: c_int,
    nice_len: u32,
    mf: c_int,
    depth: u32,
    ext_flags: u32,
    ext_size_low: u32,
    ext_size_high: u32,
    reserved_int4: u32,
    reserved_int5: u32,
    reserved_int6: u32,
    reserved_int7: u32,
    reserved_int8: u32,
    reserved_enum1: c_int,
    reserved_enum2: c_int,
    reserved_enum3: c_int,
    reserved_enum4: c_int,
    reserved_ptr1: ?*anyopaque,
    reserved_ptr2: ?*anyopaque,
};
const LZMA_FILTER_X86: u64 = 0x04;
const LZMA_FILTER_LZMA2: u64 = 0x21;
const LZMA_VLI_UNKNOWN: u64 = std.math.maxInt(u64);
extern fn lzma_lzma_preset(options: *lzma_options_lzma, preset: u32) c_int; // nonzero = error
extern fn lzma_stream_buffer_encode(
    filters: [*]lzma_filter,
    check: c_int,
    allocator: ?*const anyopaque,
    in: [*]const u8,
    in_size: usize,
    out: [*]u8,
    out_pos: *usize,
    out_size: usize,
) c_int;

pub fn lzmaCompressX86(data: []const u8, a: std.mem.Allocator, preset: u32) ![]u8 {
    var opt: lzma_options_lzma = std.mem.zeroes(lzma_options_lzma);
    if (lzma_lzma_preset(&opt, preset) != 0) return error.LzmaCompressFailed;
    var filters = [_]lzma_filter{
        .{ .id = LZMA_FILTER_X86, .options = null },
        .{ .id = LZMA_FILTER_LZMA2, .options = &opt },
        .{ .id = LZMA_VLI_UNKNOWN, .options = null },
    };
    const bound = lzma_stream_buffer_bound(data.len);
    const buf = try a.alloc(u8, bound);
    defer a.free(buf);
    var out_pos: usize = 0;
    const rc = lzma_stream_buffer_encode(
        &filters, LZMA_CHECK_NONE, null,
        data.ptr, data.len, buf.ptr, &out_pos, buf.len,
    );
    if (rc != LZMA_OK) return error.LzmaCompressFailed;
    return a.dupe(u8, buf[0..out_pos]);
}

/// LZMA with explicit literal-context / literal-position / position bits. The
/// .xz stream self-describes the filter params, so lzmaDecompress reads it back
/// with no extra metadata. Used to tune the BCJ2 address streams (4-byte-aligned
/// big-endian addresses compress better with position bits matched to 4).
pub fn lzmaCompressTuned(data: []const u8, a: std.mem.Allocator, preset: u32, lc: u32, lp: u32, pb: u32) ![]u8 {
    var opt: lzma_options_lzma = std.mem.zeroes(lzma_options_lzma);
    if (lzma_lzma_preset(&opt, preset) != 0) return error.LzmaCompressFailed;
    opt.lc = lc;
    opt.lp = lp;
    opt.pb = pb;
    var filters = [_]lzma_filter{
        .{ .id = LZMA_FILTER_LZMA2, .options = &opt },
        .{ .id = LZMA_VLI_UNKNOWN, .options = null },
    };
    const bound = lzma_stream_buffer_bound(data.len);
    const buf = try a.alloc(u8, bound);
    defer a.free(buf);
    var out_pos: usize = 0;
    const rc = lzma_stream_buffer_encode(
        &filters, LZMA_CHECK_NONE, null,
        data.ptr, data.len, buf.ptr, &out_pos, buf.len,
    );
    if (rc != LZMA_OK) return error.LzmaCompressFailed;
    return a.dupe(u8, buf[0..out_pos]);
}

pub fn lzmaDecompress(block: []const u8, original_size: u64, a: std.mem.Allocator) ![]u8 {
    const out = try a.alloc(u8, @intCast(original_size));
    errdefer a.free(out);
    var memlimit: u64 = std.math.maxInt(u64);
    var in_pos: usize = 0;
    var out_pos: usize = 0;
    const rc = lzma_stream_buffer_decode(
        &memlimit, 0, null,
        block.ptr, &in_pos, block.len,
        out.ptr, &out_pos, out.len,
    );
    if (rc != LZMA_OK) return error.LzmaDecompressFailed;
    if (out_pos != original_size) return error.SizeMismatch;
    return out;
}

// ---------------------------------------------------------------------------
// BCJ2 block (full mode): the 4 BCJ2 streams, each LZMA-compressed, in one blob.
// Layout (header 29 B):
//   [u8 version=1]
//   [u32 main_ulen][u32 main_clen]
//   [u32 call_ulen][u32 call_clen]
//   [u32 jump_ulen][u32 jump_clen]
//   [u32 rc_len]
//   [LZMA(main)][LZMA(call)][LZMA(jump)][rc]
// rc is already range-coded so it's stored raw. Empty streams have clen 0.
// ---------------------------------------------------------------------------

const BCJ2_HDR: usize = 29;

fn lzmaOrEmpty(data: []const u8, preset: u32, a: std.mem.Allocator) ![]u8 {
    if (data.len == 0) return a.alloc(u8, 0);
    return lzmaCompress(data, a, preset);
}

/// LZMA-compress a BCJ2 address stream, keeping the smaller of the default model
/// and one tuned for 4-byte-aligned big-endian records (lc0/lp2/pb2). The .xz
/// stream self-describes its params, so decode needs no extra metadata.
fn lzmaAddrStream(data: []const u8, preset: u32, a: std.mem.Allocator) ![]u8 {
    if (data.len == 0) return a.alloc(u8, 0);
    const def = try lzmaCompress(data, a, preset);
    const tuned = lzmaCompressTuned(data, a, preset, 0, 2, 2) catch {
        return def;
    };
    if (tuned.len < def.len) {
        a.free(def);
        return tuned;
    }
    a.free(tuned);
    return def;
}

/// Build a MATH_BCJ2 block from `tar`: split via BCJ2, LZMA each stream.
/// Returns owned bytes (the entry block). original_size for the FAT == tar.len.
pub fn buildBcj2Block(tar: []const u8, preset: u32, a: std.mem.Allocator) ![]u8 {
    var s = try bcj2.encode(tar, a);
    defer s.deinit(a);
    const cmain = try lzmaOrEmpty(s.main, preset, a);
    defer a.free(cmain);
    const cc = try lzmaAddrStream(s.call, preset, a);
    defer a.free(cc);
    const cj = try lzmaAddrStream(s.jump, preset, a);
    defer a.free(cj);

    const total = BCJ2_HDR + cmain.len + cc.len + cj.len + s.rc.len;
    const out = try a.alloc(u8, total);
    errdefer a.free(out);
    out[0] = 1;
    std.mem.writeInt(u32, out[1..5], @intCast(s.main.len), .little);
    std.mem.writeInt(u32, out[5..9], @intCast(cmain.len), .little);
    std.mem.writeInt(u32, out[9..13], @intCast(s.call.len), .little);
    std.mem.writeInt(u32, out[13..17], @intCast(cc.len), .little);
    std.mem.writeInt(u32, out[17..21], @intCast(s.jump.len), .little);
    std.mem.writeInt(u32, out[21..25], @intCast(cj.len), .little);
    std.mem.writeInt(u32, out[25..29], @intCast(s.rc.len), .little);
    var off: usize = BCJ2_HDR;
    @memcpy(out[off..][0..cmain.len], cmain);
    off += cmain.len;
    @memcpy(out[off..][0..cc.len], cc);
    off += cc.len;
    @memcpy(out[off..][0..cj.len], cj);
    off += cj.len;
    @memcpy(out[off..][0..s.rc.len], s.rc);
    return out;
}

/// Decode a MATH_BCJ2 block back to the original `original_size` bytes (the tar).
fn extractBcj2(block: []const u8, original_size: u64, a: std.mem.Allocator) ![]u8 {
    if (block.len < BCJ2_HDR or block[0] != 1) return error.TruncatedContainer;
    const main_ulen: usize = std.mem.readInt(u32, block[1..5], .little);
    const main_clen: usize = std.mem.readInt(u32, block[5..9], .little);
    const call_ulen: usize = std.mem.readInt(u32, block[9..13], .little);
    const call_clen: usize = std.mem.readInt(u32, block[13..17], .little);
    const jump_ulen: usize = std.mem.readInt(u32, block[17..21], .little);
    const jump_clen: usize = std.mem.readInt(u32, block[21..25], .little);
    const rc_len: usize = std.mem.readInt(u32, block[25..29], .little);
    if (BCJ2_HDR + main_clen + call_clen + jump_clen + rc_len > block.len)
        return error.TruncatedContainer;

    var off: usize = BCJ2_HDR;
    const main = if (main_ulen == 0) try a.alloc(u8, 0) else try lzmaDecompress(block[off .. off + main_clen], main_ulen, a);
    defer a.free(main);
    off += main_clen;
    const call = if (call_ulen == 0) try a.alloc(u8, 0) else try lzmaDecompress(block[off .. off + call_clen], call_ulen, a);
    defer a.free(call);
    off += call_clen;
    const jump = if (jump_ulen == 0) try a.alloc(u8, 0) else try lzmaDecompress(block[off .. off + jump_clen], jump_ulen, a);
    defer a.free(jump);
    off += jump_clen;
    const rc = block[off .. off + rc_len];

    return bcj2.decode(main, call, jump, rc, @intCast(original_size), a);
}

/// Compression config carried by each builder: which codec + its level.
/// `from` maps an effort tier (0/1/2) to concrete levels.
pub const Compressor = struct {
    codec: Codec = .zstd,
    gzip_level: GzipLevel = .fast, // used only for the streaming huge-file path
    zstd_level: c_int = 12,
    lzma_preset: u32 = 6,

    pub fn fromTier(tier: u8) Compressor {
        return switch (tier) {
            0 => .{ .codec = .zstd, .gzip_level = .fast, .zstd_level = 3, .lzma_preset = lzmaPreset(0) },
            2 => .{ .codec = .zstd, .gzip_level = .best, .zstd_level = 19, .lzma_preset = lzmaPreset(2) },
            else => .{ .codec = .zstd, .gzip_level = .default, .zstd_level = 12, .lzma_preset = lzmaPreset(1) },
        };
    }

    /// Full-mode codec config: same effort tier, but routed through LZMA/xz.
    pub fn lzmaFromTier(tier: u8) Compressor {
        var c = fromTier(tier);
        c.codec = .lzma;
        return c;
    }

    /// Compress one in-memory block with the chosen codec.
    pub fn compress(self: Compressor, data: []const u8, a: std.mem.Allocator) ![]u8 {
        return switch (self.codec) {
            .gzip => gzipCompress(data, a, self.gzip_level),
            .zstd => zstdCompress(data, a, self.zstd_level),
            .lzma => lzmaCompress(data, a, self.lzma_preset),
        };
    }
};

/// Decompress a whole-block compressed payload (fallback_stream) by codec.
fn inflateBlock(block: []const u8, original_size: u64, codec: Codec, a: std.mem.Allocator) ![]u8 {
    return switch (codec) {
        .gzip => extractFallback(block, original_size, a),
        .zstd => zstdDecompress(block, original_size, a),
        .lzma => lzmaDecompress(block, original_size, a),
    };
}

test "lzma backend round-trips exactly across content types" {
    const a = testing.allocator;
    var rng = @import("math_gen.zig").XorShift32.init(0x1234);
    // Mixed: repetitive text, a gradient, and a random tail — round-trip is the
    // load-bearing property. (The size win over zstd is verified on real tars in
    // the bake-off; on tiny inputs xz's ~60B container overhead makes it lose.)
    var buf = std.ArrayList(u8).init(a);
    defer buf.deinit();
    try buf.appendSlice("the quick brown fox jumps over the lazy dog. " ** 300);
    var i: usize = 0;
    while (i < 4000) : (i += 1) try buf.append(@truncate(i / 4));
    i = 0;
    while (i < 4000) : (i += 1) try buf.append(rng.nextByte());

    const data = buf.items;
    for ([_]u32{ lzmaPreset(0), lzmaPreset(1), lzmaPreset(2) }) |preset| {
        const lz = try lzmaCompress(data, a, preset);
        defer a.free(lz);
        const back = try lzmaDecompress(lz, data.len, a);
        defer a.free(back);
        try testing.expectEqualSlices(u8, data, back);
    }
    // On the highly-compressible prefix LZMA clearly compresses.
    const lz = try lzmaCompress(data, a, lzmaPreset(2));
    defer a.free(lz);
    try testing.expect(lz.len < data.len);
}

test "trained dict: train, dict-compress, round-trip via container" {
    const a = testing.allocator;
    // Many similar small JSON-ish records — the dict's target workload.
    var samples = std.ArrayList([]u8).init(a);
    defer {
        for (samples.items) |s| a.free(s);
        samples.deinit();
    }
    var concat = std.ArrayList(u8).init(a);
    defer concat.deinit();
    var sizes = std.ArrayList(usize).init(a);
    defer sizes.deinit();
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        const s = try std.fmt.allocPrint(a,
            "{{\"id\":{d},\"type\":\"widget\",\"enabled\":true,\"label\":\"item number {d}\",\"tags\":[\"alpha\",\"beta\"]}}",
            .{ n, n });
        try samples.append(s);
        try concat.appendSlice(s);
        try sizes.append(s.len);
    }

    const dict = (try trainDict(concat.items, sizes.items, 8 * 1024, a)) orelse return error.SkipZigTest;
    defer a.free(dict);
    try testing.expect(dict.len > 0);

    // Build a container: register the dict, add each sample as a .math_dict entry.
    var cb = try StreamingBuilder.init(a);
    defer cb.deinit();
    const di = try cb.registerDict(dict);
    for (samples.items, 0..) |s, i| {
        const block = try zstdCompressUsingDict(s, dict, 19, a);
        defer a.free(block);
        var fat = FatEntry{
            .comp_type = .math_dict,
            .solid_index = di,
            .data_offset = 0,
            .original_size = s.len,
            .compressed_size = block.len,
            .checksum = fnv1a(s),
            .codec = .zstd,
        };
        var nb: [64]u8 = undefined;
        try fat.setPath(try std.fmt.bufPrint(&nb, "rec_{d}.json", .{i}));
        try cb.appendBlock(fat, block);
    }

    // Serialize to a temp file, read back, and verify every entry byte-perfectly.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try tmp.dir.createFile("dict.math", .{ .read = true });
    defer out.close();
    try cb.finish(out);

    try out.seekTo(0);
    const bytes = try out.readToEndAlloc(a, 16 * 1024 * 1024);
    defer a.free(bytes);

    var rdr = try Reader.parse(bytes, a);
    defer rdr.deinit();
    try testing.expectEqual(@as(usize, 1), rdr.dicts.len);
    try testing.expect((rdr.flags & FLAG_HAS_DICTS) != 0);
    for (samples.items, 0..) |s, i| {
        var nb: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&nb, "rec_{d}.json", .{i});
        const back = try rdr.extract(path, a);
        defer a.free(back);
        try testing.expectEqualSlices(u8, s, back);
    }
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

    const compressed = try gzipCompress(raw, a, .fast);
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
    const bin_gz = try gzipCompress(&bin_data, a, .fast);
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

        // The STORE guard's promise: the stored block for the file is never
        // larger than the raw input. Read it back from the FAT rather than
        // doing header/FAT byte math (the FAT is compressed now).
        var rdr = try Reader.parse(buf.items, a);
        defer rdr.deinit();
        try testing.expectEqual(@as(usize, 1), rdr.entryCount());
        try testing.expect(rdr.entryAt(0).compressed_size <= sz);
    }
}

test "solid block: three-file round-trip extracts byte-perfectly" {
    const a = testing.allocator;

    // Three text-like files in the same ".lua" extension bucket.
    const lua0 = "-- file 0\nlocal x = math.sin(1)\nreturn x\n";
    const lua1 = "-- file 1\nlocal y = math.cos(2)\nreturn y\n";
    const lua2 = "-- file 2\nlocal z = math.sqrt(3)\nreturn z\n";

    var scb = try SolidContainerBuilder.init(a);
    defer scb.deinit();

    try scb.queueBinary("scripts/f0.lua", lua0);
    try scb.queueBinary("scripts/f1.lua", lua1);
    try scb.queueBinary("scripts/f2.lua", lua2);

    // Serialise to a buffer via a temp file approach.
    // flush() writes to an std.fs.File; use std.testing.tmpDir.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_path = "solid_test.math";
    const out_file = try tmp.dir.createFile(out_path, .{});
    try scb.flush(out_file);
    out_file.close();

    // Read it back into memory.
    const archive_bytes = try tmp.dir.readFileAlloc(a, out_path, 16 * 1024 * 1024);
    defer a.free(archive_bytes);

    // Parse with the upgraded Reader.
    var rdr = try Reader.parse(archive_bytes, a);
    defer rdr.deinit();

    // All three entries must exist with comp_type = solid_block.
    try testing.expectEqual(@as(usize, 3), rdr.entryCount());
    for (0..3) |i| {
        const e = rdr.entryAt(i);
        try testing.expectEqual(CompressionType.solid_block, e.comp_type);
        try testing.expectEqual(@as(u32, @intCast(i)), e.solid_index);
    }

    // Extract and verify byte-perfect reconstruction + FNV-1a integrity.
    const r0 = try rdr.extract("scripts/f0.lua", a); defer a.free(r0);
    const r1 = try rdr.extract("scripts/f1.lua", a); defer a.free(r1);
    const r2 = try rdr.extract("scripts/f2.lua", a); defer a.free(r2);

    try testing.expectEqualSlices(u8, lua0, r0);
    try testing.expectEqualSlices(u8, lua1, r1);
    try testing.expectEqualSlices(u8, lua2, r2);

    try testing.expectEqual(fnv1a(lua0), fnv1a(r0));
    try testing.expectEqual(fnv1a(lua1), fnv1a(r1));
    try testing.expectEqual(fnv1a(lua2), fnv1a(r2));
}

test "solid block: incremental bucket flush yields multiple blocks that all extract" {
    const a = testing.allocator;

    var scb = try SolidContainerBuilder.init(a);
    defer scb.deinit();

    const f0 = "-- alpha\nreturn 1\n";
    const f1 = "-- beta\nreturn 2\n";
    const f2 = "-- gamma\nreturn 3\n";
    const f3 = "-- delta\nreturn 4\n";

    try scb.queueBinary("s/a.lua", f0);
    try scb.queueBinary("s/b.lua", f1);
    // Force a mid-pack flush — the same path queueBinary takes when a bucket
    // crosses SOLID_BUCKET_FLUSH_BYTES. The .lua extension now spans two blocks.
    try scb.flushOneBucket(&scb.bucket_list.items[0]);
    try testing.expectEqual(@as(usize, 0), scb.queued_bytes);
    try scb.queueBinary("s/c.lua", f2);
    try scb.queueBinary("s/d.lua", f3);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_file = try tmp.dir.createFile("multi.math", .{});
    try scb.flush(out_file);
    out_file.close();

    const bytes = try tmp.dir.readFileAlloc(a, "multi.math", 16 * 1024 * 1024);
    defer a.free(bytes);

    var rdr = try Reader.parse(bytes, a);
    defer rdr.deinit();
    try testing.expectEqual(@as(usize, 4), rdr.entryCount());

    const names = [_][]const u8{ "s/a.lua", "s/b.lua", "s/c.lua", "s/d.lua" };
    const want  = [_][]const u8{ f0, f1, f2, f3 };
    for (names, want) |n, w| {
        const got = try rdr.extract(n, a);
        defer a.free(got);
        try testing.expectEqualSlices(u8, w, got);
    }
}

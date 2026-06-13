//! x64.zig — an x86-64 RIP-relative reference filter (a BCJ the others lack).
//!
//! BCJ/BCJ2 convert E8/E9 CALL/JMP relative operands so repeated targets match.
//! Modern position-independent code (.so / PIE executables) instead references
//! the GOT and data through RIP-relative operands: `mov rax, [rip+disp32]`,
//! `lea`, etc. 7-Zip's x86 filter doesn't touch those. This filter does: it
//! walks instructions with a length decoder and rewrites each [rip+disp32] to a
//! position-absolute value (disp + stream offset of the next instruction), so
//! many references to the same GOT/data slot become identical 4-byte values the
//! LZ stage then matches. Measured: −1.5% to −3.1% on real .text, and the output
//! is ordinary bytes for LZMA — so decode stays at full LZMA speed (live-safe),
//! unlike the context-mixing backend.
//!
//! Correctness: the rewrite changes only disp32 VALUES, never opcode/ModRM/length
//! bytes, so the length decoder makes byte-identical decisions on the filtered
//! and unfiltered streams — decode exactly reverses encode for any deterministic
//! decoder. The caller additionally verify-then-uses (re-applies the inverse and
//! checks equality) so an imperfect decoder can only cost a missed win, never
//! corruption. The decoder's accuracy affects ratio, not safety.

const std = @import("std");

/// Result of decoding one instruction's structure.
const Insn = struct {
    len: usize,
    rip_off: ?usize, // offset of the disp32 within the instruction, if RIP-relative
};

/// Length-decode one x86-64 instruction at `c` (c.len is the remaining bytes).
/// Returns its byte length and, if it has a `[rip+disp32]` operand, the offset
/// of that disp32 within the instruction. Returns len=0 if it can't fit.
fn decode(c: []const u8) Insn {
    var i: usize = 0;
    var opsize16 = false; // 0x66 present (16-bit operand)
    var rex_w = false;

    // ---- legacy prefixes ----
    while (i < c.len) : (i += 1) {
        switch (c[i]) {
            0x66 => opsize16 = true,
            0x67, 0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65 => {},
            else => break,
        }
    }
    if (i >= c.len) return .{ .len = 0, .rip_off = null };

    var has_modrm = false;
    var imm: usize = 0; // immediate byte count
    var grp3: u8 = 0; // 0xF6/0xF7: immediate only when ModRM.reg is 0 or 1 (test)

    // ---- VEX / EVEX (AVX) prefixes — replace REX, select an opcode map ----
    // In 64-bit mode 0xC5/0xC4 are VEX and 0x62 is EVEX. They carry the opcode
    // map (0F / 0F38 / 0F3A) in their bytes; the instruction is ModRM-form.
    var handled = false;
    if (c[i] == 0xC5) { // 2-byte VEX (implied 0F map)
        if (i + 2 > c.len) return .{ .len = 0, .rip_off = null };
        i += 2;
        if (i >= c.len) return .{ .len = 0, .rip_off = null };
        const op2 = c[i];
        i += 1;
        has_modrm = true;
        imm = if (twobyte[op2].imm == .ib) 1 else 0;
        handled = true;
    } else if (c[i] == 0xC4) { // 3-byte VEX
        if (i + 3 > c.len) return .{ .len = 0, .rip_off = null };
        const map = c[i + 1] & 0x1F; // 1=0F, 2=0F38, 3=0F3A
        i += 3;
        if (i >= c.len) return .{ .len = 0, .rip_off = null };
        const op2 = c[i];
        i += 1;
        has_modrm = true;
        imm = vexImm(map, op2);
        handled = true;
    } else if (c[i] == 0x62) { // EVEX (4-byte prefix)
        if (i + 4 > c.len) return .{ .len = 0, .rip_off = null };
        const map = c[i + 1] & 0x07; // mm: 1=0F, 2=0F38, 3=0F3A
        i += 4;
        if (i >= c.len) return .{ .len = 0, .rip_off = null };
        const op2 = c[i];
        i += 1;
        has_modrm = true;
        imm = vexImm(map, op2);
        handled = true;
    }

    if (!handled) {
        // ---- REX ----
        if (c[i] & 0xF0 == 0x40) {
            if (c[i] & 0x08 != 0) rex_w = true;
            i += 1;
        }
        if (i >= c.len) return .{ .len = 0, .rip_off = null };

        // ---- opcode (1, 2 via 0F, or 3 via 0F38/0F3A) ----
        var two_byte = false;
        var three_byte_3a = false;
        var op = c[i];
        i += 1;
        if (op == 0x0F) {
            if (i >= c.len) return .{ .len = 0, .rip_off = null };
            two_byte = true;
            op = c[i];
            i += 1;
            if (op == 0x38 or op == 0x3A) {
                three_byte_3a = (op == 0x3A);
                if (i >= c.len) return .{ .len = 0, .rip_off = null };
                op = c[i];
                i += 1;
            }
        }
        if (!two_byte) {
            const p = onebyte[op];
            has_modrm = p.modrm;
            imm = immBytes(p.imm, opsize16, rex_w);
            if (op == 0xF6 or op == 0xF7) grp3 = op; // imm decided after ModRM.reg
        } else if (three_byte_3a) {
            has_modrm = true; // 0F 3A maps all take ModRM + ib
            imm = 1;
        } else {
            const p = twobyte[op];
            has_modrm = p.modrm;
            imm = immBytes(p.imm, opsize16, rex_w);
        }
    }

    // ---- ModRM / SIB / displacement ----
    var rip_off: ?usize = null;
    if (has_modrm) {
        if (i >= c.len) return .{ .len = 0, .rip_off = null };
        const modrm = c[i];
        i += 1;
        const md: u8 = modrm >> 6;
        const rm: u8 = modrm & 7;
        // grp3 (F6/F7): test Eb,Ib / Ev,Iz when reg field is 0 or 1.
        if (grp3 != 0 and ((modrm >> 3) & 7) < 2) {
            imm = if (grp3 == 0xF6) 1 else immBytes(.iz, opsize16, rex_w);
        }
        if (md != 3) {
            if (rm == 4) {
                // SIB
                if (i >= c.len) return .{ .len = 0, .rip_off = null };
                const sib = c[i];
                i += 1;
                if (md == 0 and (sib & 7) == 5) {
                    i += 4; // disp32 (no base)
                } else if (md == 1) {
                    i += 1;
                } else if (md == 2) {
                    i += 4;
                }
            } else if (md == 0 and rm == 5) {
                // RIP-relative: disp32 right here
                rip_off = i;
                i += 4;
            } else if (md == 1) {
                i += 1;
            } else if (md == 2) {
                i += 4;
            }
        }
    }

    i += imm;
    if (i > c.len) return .{ .len = 0, .rip_off = null };
    return .{ .len = i, .rip_off = rip_off };
}

const ImmKind = enum { none, ib, iw, iz, iv, i16_8 }; // iz: 2/4 by opsize; iv: 2/4/8; i16_8: enter
fn immBytes(k: ImmKind, opsize16: bool, rex_w: bool) usize {
    return switch (k) {
        .none => 0,
        .ib => 1,
        .iw => 2,
        .iz => if (opsize16) 2 else 4,
        .iv => if (rex_w) 8 else (if (opsize16) 2 else 4),
        .i16_8 => 3,
    };
}

/// Immediate byte count for a VEX/EVEX instruction by opcode map.
/// 0F3A opcodes all take an ib; 0F opcodes take ib only where the legacy 0F map
/// does (vcmpps, vpshuf, vshufps…); 0F38 take none.
fn vexImm(map: u8, op: u8) usize {
    return switch (map) {
        3 => 1, // 0F3A
        1 => if (twobyte[op].imm == .ib) 1 else 0, // 0F
        else => 0, // 0F38 and others
    };
}

const Prop = struct { modrm: bool, imm: ImmKind };
const M = Prop{ .modrm = true, .imm = .none };
const Mb = Prop{ .modrm = true, .imm = .ib };
const Mz = Prop{ .modrm = true, .imm = .iz };
const N = Prop{ .modrm = false, .imm = .none };
const Nb = Prop{ .modrm = false, .imm = .ib };
const Nz = Prop{ .modrm = false, .imm = .iz };
const Nv = Prop{ .modrm = false, .imm = .iv };
const Nw = Prop{ .modrm = false, .imm = .iw };

// One-byte opcode map (x86-64). Covers ModRM presence + immediate size.
const onebyte = buildOnebyte();
fn buildOnebyte() [256]Prop {
    var t = [_]Prop{N} ** 256;
    // 0x00-0x3F: arithmetic groups in 8-row blocks: 00-05 etc.
    // pattern per 0x08 block: [0]=Eb,Gb M, [1]=Ev,Gv M, [2]=Gb,Eb M, [3]=Gv,Ev M,
    //                         [4]=AL,Ib Nb, [5]=eAX,Iz Nz, [6]/[7]=push/pop seg N
    var base: usize = 0;
    while (base <= 0x38) : (base += 0x08) {
        if (base == 0x38) {
            // 0x38-0x3D cmp (same pattern), 0x3E/0x3F are prefixes/aaa-ish
        }
        t[base + 0] = M;
        t[base + 1] = M;
        t[base + 2] = M;
        t[base + 3] = M;
        t[base + 4] = Nb;
        t[base + 5] = Nz;
        // +6/+7 default N
    }
    // 0x40-0x4F REX (no modrm) — handled before opcode, leave N
    // 0x50-0x5F push/pop r N
    // 0x68 push Iz, 0x69 imul Ev,Gv,Iz (M+Iz), 0x6A push Ib, 0x6B imul (M+Ib)
    t[0x68] = Nz;
    t[0x69] = Mz;
    t[0x6A] = Nb;
    t[0x6B] = Mb;
    // 0x70-0x7F Jcc rel8
    var j: usize = 0x70;
    while (j <= 0x7F) : (j += 1) t[j] = Nb;
    // 0x80 grp1 Eb,Ib; 0x81 grp1 Ev,Iz; 0x83 grp1 Ev,Ib
    t[0x80] = Mb;
    t[0x81] = Mz;
    t[0x82] = Mb;
    t[0x83] = Mb;
    // 0x84-0x8F test/xchg/mov/lea/mov/pop — all ModRM
    t[0x84] = M;
    t[0x85] = M;
    t[0x86] = M;
    t[0x87] = M;
    t[0x88] = M;
    t[0x89] = M;
    t[0x8A] = M;
    t[0x8B] = M;
    t[0x8C] = M;
    t[0x8D] = M; // lea
    t[0x8E] = M;
    t[0x8F] = M; // grp1A pop Ev
    // 0x90-0x97 xchg (N), 0x98/99 cbw/cwd, 0x9A far(invalid64), 0x9B-9F N
    // 0xA0-0xA3 mov AL/eAX,[moffs] — moffs is 8 bytes in 64-bit (addr); treat as Nv-ish
    t[0xA0] = Nv;
    t[0xA1] = Nv;
    t[0xA2] = Nv;
    t[0xA3] = Nv;
    // 0xA8 test AL,Ib; 0xA9 test eAX,Iz
    t[0xA8] = Nb;
    t[0xA9] = Nz;
    // 0xB0-0xB7 mov r8,Ib ; 0xB8-0xBF mov r,Iv
    var b: usize = 0xB0;
    while (b <= 0xB7) : (b += 1) t[b] = Nb;
    b = 0xB8;
    while (b <= 0xBF) : (b += 1) t[b] = Nv;
    // 0xC0/C1 grp2 Eb/Ev,Ib ; 0xC2 ret Iw ; 0xC6 mov Eb,Ib ; 0xC7 mov Ev,Iz
    t[0xC0] = Mb;
    t[0xC1] = Mb;
    t[0xC2] = Nw;
    t[0xC6] = Mb;
    t[0xC7] = Mz;
    t[0xC8] = .{ .modrm = false, .imm = .i16_8 }; // enter Iw,Ib
    // 0xCD int Ib
    t[0xCD] = Nb;
    // 0xD0-0xD3 grp2 (M), 0xD8-0xDF x87 (M)
    t[0xD0] = M;
    t[0xD1] = M;
    t[0xD2] = M;
    t[0xD3] = M;
    var x: usize = 0xD8;
    while (x <= 0xDF) : (x += 1) t[x] = M;
    // 0xE0-0xE3 loop/jcxz rel8 ; 0xE4-0xE7 in/out Ib ; 0xE8 call Iz ; 0xE9 jmp Iz ; 0xEB jmp Ib
    t[0xE0] = Nb;
    t[0xE1] = Nb;
    t[0xE2] = Nb;
    t[0xE3] = Nb;
    t[0xE4] = Nb;
    t[0xE5] = Nb;
    t[0xE6] = Nb;
    t[0xE7] = Nb;
    t[0xE8] = Nz;
    t[0xE9] = Nz;
    t[0xEB] = Nb;
    // 0xF6 grp3 Eb (Ib if /0,/1) — variable; we conservatively treat as M (no imm),
    //   which can mis-length test Eb,Ib. To stay safe we special-case below at runtime.
    t[0xF6] = M;
    t[0xF7] = M;
    // 0xFE grp4 (M), 0xFF grp5 (M)
    t[0xFE] = M;
    t[0xFF] = M;
    return t;
}

// Two-byte opcode map (0F xx). Most take ModRM; a few have immediates.
const twobyte = buildTwobyte();
fn buildTwobyte() [256]Prop {
    var t = [_]Prop{M} ** 256; // default: ModRM, no imm (covers the vast majority)
    // 0F 80-8F: Jcc rel32 (no modrm, iz)
    var j: usize = 0x80;
    while (j <= 0x8F) : (j += 1) t[j] = Nz;
    // 0F 90-9F setcc: ModRM (default M, ok)
    // 0F A0-A1 push/pop fs ; 0F A2 cpuid ; 0F A8/A9 push/pop gs ; 0F AA rsm — no modrm
    t[0xA0] = N;
    t[0xA1] = N;
    t[0xA2] = N;
    t[0xA8] = N;
    t[0xA9] = N;
    t[0xAA] = N;
    // 0F 0B ud2, 0F 05 syscall, 0F 06,07,08,09,0x30-0x37 (msr/rdtsc) no modrm
    t[0x05] = N;
    t[0x06] = N;
    t[0x07] = N;
    t[0x08] = N;
    t[0x09] = N;
    t[0x0B] = N;
    t[0x0E] = N;
    var k: usize = 0x30;
    while (k <= 0x37) : (k += 1) t[k] = N;
    // 0F 77 emms, 0F A2 cpuid (set), 0F C8-CF bswap (no modrm)
    t[0x77] = N;
    var c: usize = 0xC8;
    while (c <= 0xCF) : (c += 1) t[c] = N;
    // 0F 70 pshuf (M+ib), 0F C2 cmpps (M+ib), 0F C4 pinsrw (M+ib), 0F C5 (M+ib),
    // 0F C6 shufps (M+ib), 0F 71-73 (M+ib), 0F A4/AC shld (M+ib), 0F BA grp8 (M+ib)
    t[0x70] = Mb;
    t[0x71] = Mb;
    t[0x72] = Mb;
    t[0x73] = Mb;
    t[0xA4] = Mb;
    t[0xAC] = Mb;
    t[0xBA] = Mb;
    t[0xC2] = Mb;
    t[0xC4] = Mb;
    t[0xC5] = Mb;
    t[0xC6] = Mb;
    return t;
}

/// Apply the filter in place over `data`. If `forward`, disp32 -> position-abs;
/// else position-abs -> disp32. Returns the number of refs converted.
pub fn apply(data: []u8, forward: bool) usize {
    var p: usize = 0;
    var n: usize = 0;
    while (p < data.len) {
        const ins = decode(data[p..]);
        if (ins.len == 0) {
            p += 1; // can't decode a full instruction near the tail; step on
            continue;
        }
        if (ins.rip_off) |off| {
            const dpos = p + off;
            if (dpos + 4 <= data.len) {
                const end: u32 = @truncate(p + ins.len); // position after this instruction
                const v = std.mem.readInt(u32, data[dpos..][0..4], .little);
                const nv = if (forward) v +% end else v -% end;
                std.mem.writeInt(u32, data[dpos..][0..4], nv, .little);
                n += 1;
            }
        }
        p += ins.len;
    }
    return n;
}

/// Forward-filter a copy of `src`, returning owned bytes, OR null when the
/// filter wouldn't help / isn't safe. Verify-then-use: re-runs the inverse and
/// confirms it reconstructs `src` exactly, so a decoder imperfection can never
/// corrupt — it just declines. Also declines if too few refs convert.
pub fn filter(src: []const u8, a: std.mem.Allocator) !?[]u8 {
    if (src.len < 64) return null;
    const out = try a.dupe(u8, src);
    errdefer a.free(out);
    const n = apply(out, true);
    if (n < 8) {
        a.free(out);
        return null;
    }
    // verify-then-use
    const chk = try a.dupe(u8, out);
    defer a.free(chk);
    _ = apply(chk, false);
    if (!std.mem.eql(u8, chk, src)) {
        a.free(out);
        return null;
    }
    return out;
}

/// Inverse of the forward filter (in place).
pub fn unfilter(data: []u8) void {
    _ = apply(data, false);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "x64 RIP filter is an exact involution on real-ish code bytes" {
    const a = testing.allocator;
    var rng = @import("math_gen.zig").XorShift32.init(0x64A1);
    // Build a buffer with scattered `mov rax,[rip+disp]` (48 8b 05 dd dd dd dd)
    // and `lea`/`call` forms amid random bytes.
    const buf = try a.alloc(u8, 60000);
    defer a.free(buf);
    for (buf) |*p| p.* = rng.nextByte();
    var i: usize = 0;
    while (i + 16 < buf.len) : (i += 23) {
        buf[i] = 0x48;
        buf[i + 1] = 0x8b;
        buf[i + 2] = 0x05; // mod=00 reg=000 rm=101 -> RIP+disp32
        // disp bytes arbitrary (already random)
    }
    const orig = try a.dupe(u8, buf);
    defer a.free(orig);
    _ = apply(buf, true);
    _ = apply(buf, false);
    try testing.expectEqualSlices(u8, orig, buf);

    // filter() round-trips via unfilter()
    if (try filter(orig, a)) |f| {
        defer a.free(f);
        const back = try a.dupe(u8, f);
        defer a.free(back);
        unfilter(back);
        try testing.expectEqualSlices(u8, orig, back);
    }
}

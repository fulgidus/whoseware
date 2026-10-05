//! Name similarity without a language model: a name becomes a hashed vector
//! of its character trigrams (lowercased, ASCII-folded, padded), normalised to
//! length 1. Cosine similarity of two such vectors tracks spelling closeness:
//! "NeoVim" ≈ "neo-vim" ≈ "neovim", "Rafał" ≈ "Rafal". Stored in libSQL's
//! vector index (F32_BLOB(dims)) by build_db, queried the same way by main.

const std = @import("std");

pub const dims = 64;

/// Lowercase, keep letters and digits, fold common accents to ASCII.
pub fn normalize(out: []u8, s: []const u8) []u8 {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(s) catch return out[0..0]).iterator();
    while (it.nextCodepoint()) |cp| {
        const ch: u21 = switch (cp) {
            'A'...'Z' => cp + 32,
            'a'...'z', '0'...'9' => cp,
            0xe0...0xe5, 0xc0...0xc5 => 'a',
            0xe8...0xeb, 0xc8...0xcb => 'e',
            0xec...0xef, 0xcc...0xcf => 'i',
            0xf2...0xf6, 0xd2...0xd6, 0xf8 => 'o',
            0xf9...0xfc, 0xd9...0xdc => 'u',
            0xe7, 0xc7, 0x107, 0x106, 0x10d, 0x10c => 'c',
            0x142, 0x141 => 'l',
            0x144, 0x143, 0xf1 => 'n',
            0x15b, 0x15a, 0x161, 0x160 => 's',
            0x17a, 0x17c, 0x17e, 0x179, 0x17b, 0x17d => 'z',
            else => continue, // spaces, punctuation, everything else
        };
        if (n == out.len) break;
        out[n] = @intCast(ch);
        n += 1;
    }
    return out[0..n];
}

/// Hashed trigram vector of `s` (normalised to unit length; zero if too short).
pub fn embed(s: []const u8) [dims]f32 {
    var v: [dims]f32 = @splat(0);
    var buf: [256]u8 = undefined;
    const core = normalize(buf[2 .. buf.len - 2], s);
    if (core.len == 0) return v;
    // pad so first and last letters get their own trigrams
    buf[0] = '^';
    buf[1] = '^';
    buf[core.len + 2] = '$';
    buf[core.len + 3] = '$';
    const t = buf[0 .. core.len + 4];
    var i: usize = 0;
    while (i + 3 <= t.len) : (i += 1) {
        const h = std.hash.Wyhash.hash(0, t[i .. i + 3]);
        v[h % dims] += 1;
    }
    var norm: f32 = 0;
    for (v) |x| norm += x * x;
    norm = @sqrt(norm);
    if (norm > 0) for (&v) |*x| {
        x.* /= norm;
    };
    return v;
}

pub fn cosine(a: [dims]f32, b: [dims]f32) f32 {
    var s: f32 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

/// "[0.1,0.2,…]": the text form libSQL's vector32() parses.
pub fn toText(buf: []u8, v: [dims]f32) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeByte('[') catch return "";
    for (v, 0..) |x, i| {
        if (i > 0) w.writeByte(',') catch return "";
        w.print("{d:.5}", .{x}) catch return "";
    }
    w.writeByte(']') catch return "";
    return w.buffered();
}

test "spelling variants are close, different names are not" {
    const nv = embed("NeoVim");
    try std.testing.expect(cosine(nv, embed("neo-vim")) > 0.95);
    try std.testing.expect(cosine(nv, embed("neovim-git")) > 0.7);
    try std.testing.expect(cosine(embed("Rafał Kucharski"), embed("Rafal Kucharski")) > 0.99);
    try std.testing.expect(cosine(nv, embed("network")) < 0.5);
}

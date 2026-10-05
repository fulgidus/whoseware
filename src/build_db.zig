//! build_db — build the entity graph whoseware embeds.
//!
//!   build_db --out entities.db --verdicts data/verdicts.json
//!            [--relations data/relations.json]
//!            [--fashware fashware.md] [--weird-guys weird-guys.html]
//!
//! The two lists are parsed into entities (people, companies, the projects
//! they're known for) with their source links; the curated files add the
//! reviewed verdicts and relations (package → project, maintainers, funders).
//! Runs at release time; users never fetch anything.
const std = @import("std");
const Io = std.Io;
const json = std.json;
const ngram = @import("ngram.zig");
const dbm = @import("db.zig");

const W_URL = "https://drewdevault.com/weird-guys/";
const F_URL = "https://git.sr.ht/~rabbits/fashware";

const Builder = struct {
    gpa: std.mem.Allocator,
    db: dbm.Db,
    ins_entity: dbm.Stmt,
    find_entity: dbm.Stmt,
    ins_rel: dbm.Stmt,
    upd_desc: dbm.Stmt,

    /// Append the sources' own text and links to an entity (an entity listed
    /// by both lists gets both texts).
    fn describe(b: *Builder, id: i64, text: []const u8, links: []const u8) !void {
        b.upd_desc.reset();
        try b.upd_desc.bind(1, text);
        try b.upd_desc.bind(2, links);
        try b.upd_desc.bind(3, id);
        _ = try b.upd_desc.step();
    }

    /// id of (kind, name), inserting it (with its vector) if new.
    fn entity(b: *Builder, kind: []const u8, name: []const u8, aliases: []const u8, note: []const u8) !i64 {
        const clean = std.mem.trim(u8, name, " \t.,;:");
        b.find_entity.reset();
        try b.find_entity.bind(1, kind);
        try b.find_entity.bind(2, clean);
        if (try b.find_entity.step()) return b.find_entity.int(0);
        var vbuf: [2048]u8 = undefined;
        b.ins_entity.reset();
        try b.ins_entity.bind(1, kind);
        try b.ins_entity.bind(2, clean);
        try b.ins_entity.bind(3, aliases);
        try b.ins_entity.bind(4, note);
        try b.ins_entity.bind(5, ngram.toText(&vbuf, ngram.embed(clean)));
        _ = try b.ins_entity.step();
        return b.db.lastId();
    }

    fn rel(b: *Builder, src: i64, r: []const u8, dst: i64, detail: []const u8, source: []const u8, date: []const u8) !void {
        b.ins_rel.reset();
        try b.ins_rel.bind(1, src);
        try b.ins_rel.bind(2, r);
        try b.ins_rel.bind(3, dst);
        try b.ins_rel.bind(4, detail);
        try b.ins_rel.bind(5, source);
        try b.ins_rel.bind(6, date);
        _ = try b.ins_rel.step();
    }
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("build_db: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const argv = init.minimal.args.vector;
    var out: ?[:0]const u8 = null;
    var verdicts: ?[]const u8 = null;
    var relations: ?[]const u8 = null;
    var fashware: ?[]const u8 = null;
    var weird: ?[]const u8 = null;
    var tags_file: ?[]const u8 = null;
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        const k = std.mem.span(argv[i]);
        const v = std.mem.span(argv[i + 1]);
        if (std.mem.eql(u8, k, "--out")) out = v
        else if (std.mem.eql(u8, k, "--verdicts")) verdicts = v
        else if (std.mem.eql(u8, k, "--relations")) relations = v
        else if (std.mem.eql(u8, k, "--fashware")) fashware = v
        else if (std.mem.eql(u8, k, "--weird-guys")) weird = v
        else if (std.mem.eql(u8, k, "--tags")) tags_file = v
        else fatal("unknown option {s}", .{k});
    }
    const out_path = out orelse fatal("--out is required", .{});
    Io.Dir.cwd().deleteFile(io, out_path) catch {};

    const db = try dbm.Db.open(out_path.ptr);
    defer db.close();
    try db.exec(dbm.schema);
    try db.exec("BEGIN");
    var b: Builder = .{
        .gpa = gpa,
        .db = db,
        .ins_entity = try db.prepare("INSERT INTO entity(kind,name,aliases,note,emb) VALUES (?,?,?,?,vector32(?))"),
        .find_entity = try db.prepare("SELECT id FROM entity WHERE kind = ? AND name = ? COLLATE NOCASE"),
        .ins_rel = try db.prepare("INSERT INTO relation(src,rel,dst,detail,source,date) VALUES (?,?,?,?,?,?)"),
        .upd_desc = try db.prepare("UPDATE entity SET description = CASE WHEN description = '' THEN ?1 ELSE description || char(10) || ?1 END, links = CASE WHEN links = '' THEN ?2 ELSE links || char(10) || ?2 END WHERE id = ?3"),
    };

    var counts = [_]usize{0} ** 3;
    if (fashware) |p| counts[0] = try parseFashware(&b, try Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(8 << 20)));
    if (weird) |p| counts[1] = try parseWeird(&b, try Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(8 << 20)));
    if (verdicts) |p| counts[2] = try loadVerdicts(&b, try Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(16 << 20)));
    if (relations) |p| try loadRelations(&b, try Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(16 << 20)));

    if (tags_file) |p| try applyTags(&b, try Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20)));
    try finishVerdicts(&b);
    try db.exec("INSERT INTO entity_text(rowid, name, aliases, description) SELECT id, name, aliases, description FROM entity");
    try db.exec("INSERT INTO entity_fts(entity_fts) VALUES ('rebuild')");
    try db.exec("CREATE INDEX entity_emb ON entity(libsql_vector_idx(emb))");
    const stamp = try db.prepare("INSERT INTO meta VALUES ('built', datetime('now')), ('lists', ?)");
    try stamp.bind(1, if (fashware != null and weird != null) "fashware, weird-guys" else if (fashware != null) "fashware" else if (weird != null) "weird-guys" else "none");
    _ = try stamp.step();
    stamp.finalize();
    b.ins_entity.finalize();
    b.find_entity.finalize();
    b.ins_rel.finalize();
    b.upd_desc.finalize();
    try db.exec("COMMIT");
    try db.exec("VACUUM");
    std.debug.print("build_db: {d} fashware entries, {d} weird-guys entries, {d} verdicts → {s}\n", .{ counts[0], counts[1], counts[2], out_path });
}

/// fashware README: "## Groups" / "## Individuals" sections of
/// "- [Name](source): product, product" bullets.
fn parseFashware(b: *Builder, text: []const u8) !usize {
    const list = try b.entity("list", "fashware", "", F_URL);
    var kind: ?[]const u8 = null;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (std.mem.startsWith(u8, line, "## ")) {
            const h = line[3..];
            kind = if (std.ascii.eqlIgnoreCase(h, "Groups")) "company" else if (std.ascii.eqlIgnoreCase(h, "Individuals")) "person" else null;
            continue;
        }
        const k = kind orelse continue;
        if (!std.mem.startsWith(u8, line, "- [")) continue;
        const close = std.mem.indexOfPos(u8, line, 3, "](") orelse continue;
        const name = line[3..close];
        const url_end = std.mem.indexOfScalarPos(u8, line, close + 2, ')') orelse continue;
        const url = line[close + 2 .. url_end];
        const id = try b.entity(k, name, "", "");
        try b.rel(id, "listed_on", list, "", url, "");
        n += 1;
        // products / projects after the last "): "
        const colon = std.mem.lastIndexOf(u8, line, "): ") orelse continue;
        try b.describe(id, try std.fmt.allocPrint(b.gpa, "Known for: {s}", .{std.mem.trim(u8, line[colon + 3 ..], " ")}), url);
        var prods = std.mem.splitScalar(u8, line[colon + 3 ..], ',');
        while (prods.next()) |pr| {
            const p = std.mem.trim(u8, pr, " ");
            if (p.len < 2 or std.ascii.eqlIgnoreCase(p, name) or std.ascii.eqlIgnoreCase(p, "nothing")) continue;
            const pid = try b.entity("project", p, "", "");
            try b.rel(id, "known_for", pid, "", url, "");
        }
    }
    return n;
}

/// The text between `open` and the next `close` after position `from`.
fn between(s: []const u8, from: usize, open: []const u8, close: []const u8) ?[]const u8 {
    const a = (std.mem.indexOfPos(u8, s, from, open) orelse return null) + open.len;
    const z = std.mem.indexOfPos(u8, s, a, close) orelse return null;
    return s[a..z];
}

/// Drop tags and collapse whitespace.
fn plain(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    var j: usize = 0;
    var sp = false;
    while (j < s.len) : (j += 1) {
        if (s[j] == '<') {
            while (j < s.len and s[j] != '>') j += 1;
            continue;
        }
        if (std.ascii.isWhitespace(s[j])) {
            sp = true;
            continue;
        }
        if (sp and o.items.len > 0) try o.append(gpa, ' ');
        sp = false;
        try o.append(gpa, s[j]);
    }
    return o.items;
}

/// The entry's text: "Known for: …" and every paragraph except the alias and
/// "Added" lines, tags dropped, "[source]" markers removed.
fn weirdDescription(gpa: std.mem.Allocator, block: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    var pp: usize = 0;
    while (std.mem.indexOfPos(u8, block, pp, "<p")) |ps| {
        const gt = std.mem.indexOfScalarPos(u8, block, ps, '>') orelse break;
        const pe = std.mem.indexOfPos(u8, block, gt, "</p>") orelse break;
        pp = pe + 4;
        const inner = std.mem.trim(u8, block[gt + 1 .. pe], " \n\t");
        if (std.mem.startsWith(u8, inner, "<strong>Alias") or std.mem.startsWith(u8, inner, "<em>Added")) continue;
        const text = try std.mem.replaceOwned(u8, gpa, try plain(gpa, inner), "[source]", "");
        const clean = std.mem.trim(u8, text, " ");
        if (clean.len == 0) continue;
        if (o.items.len > 0) try o.append(gpa, '\n');
        try o.appendSlice(gpa, clean);
    }
    return o.items;
}

/// The entry's own URL and every external link in it (the [source] links), one per line.
fn weirdLinks(gpa: std.mem.Allocator, block: []const u8, own: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(gpa, own);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, block, from, "href=\"")) |at| {
        const a = at + 6;
        const z = std.mem.indexOfScalarPos(u8, block, a, '"') orelse break;
        from = z;
        const url = block[a..z];
        if (!std.mem.startsWith(u8, url, "http") or std.mem.indexOf(u8, url, "weird-guys/#") != null) continue;
        if (std.mem.indexOf(u8, o.items, url) != null) continue;
        try o.append(gpa, '\n');
        try o.appendSlice(gpa, url);
    }
    return o.items;
}

/// weird-guys page: <div id="slug" class="weird-guy"> blocks with the name,
/// "Known for", "Alias", links to other entries (#slug) and "Added <date>".
fn parseWeird(b: *Builder, html: []const u8) !usize {
    const list = try b.entity("list", "weird-guys", "", W_URL);
    const Entry = struct { slug: []const u8, id: i64, block: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, html, pos, "class=\"weird-guy\"")) |at| {
        const div = std.mem.lastIndexOf(u8, html[0..at], "<div id=\"") orelse break;
        const slug = between(html, div, "<div id=\"", "\"") orelse break;
        const next = std.mem.indexOfPos(u8, html, at + 10, "class=\"weird-guy\"") orelse html.len;
        const block = html[at..next];
        pos = at + 10;
        const name = between(block, 0, "<span>", "</span>") orelse continue;
        const alias = if (between(block, 0, "<strong>Alias</strong>", "</p>")) |a| std.mem.trimStart(u8, a, ": ") else "";
        const date = if (std.mem.indexOf(u8, block, "Added ")) |d| blk: {
            const end = std.mem.indexOfAnyPos(u8, block, d, "<\n") orelse block.len;
            break :blk block[d + 6 .. end];
        } else "";
        const id = try b.entity("person", name, try plain(b.gpa, alias), "");
        const src = try std.fmt.allocPrint(b.gpa, "{s}#{s}", .{ W_URL, slug });
        try b.rel(id, "listed_on", list, "", src, date);
        try b.describe(id, try weirdDescription(b.gpa, block), try weirdLinks(b.gpa, block, src));
        if (between(block, 0, "<strong>Known for</strong>", "</p>")) |kf_raw| {
            const kf = try plain(b.gpa, std.mem.trimStart(u8, kf_raw, ": "));
            var items = std.mem.tokenizeAny(u8, kf, ",;");
            while (items.next()) |item| {
                var p = std.mem.trim(u8, item, " ");
                var detail: []const u8 = "";
                // "Hashicorp (co-founder)" → project Hashicorp, detail co-founder
                if (std.mem.indexOfScalar(u8, p, '(')) |o| {
                    detail = std.mem.trim(u8, p[o..], " ()");
                    p = std.mem.trim(u8, p[0..o], " ");
                }
                for ([_][]const u8{ " maintainer", " founder", " creator", " (founder)" }) |suf| {
                    if (std.mem.endsWith(u8, p, suf)) {
                        detail = suf[1..];
                        p = p[0 .. p.len - suf.len];
                    }
                }
                if (p.len < 2 or std.mem.eql(u8, p, "etc")) continue;
                const pid = try b.entity("project", p, "", "");
                try b.rel(id, "known_for", pid, detail, src, date);
            }
        }
        try entries.append(b.gpa, .{ .slug = slug, .id = id, .block = block });
    }
    // Entries linking to each other: "financially supported by <a #dorsey>".
    for (entries.items) |e| {
        var p: usize = 0;
        while (std.mem.indexOfPos(u8, e.block, p, "weird-guys/#")) |at| {
            p = at + 12;
            const end = std.mem.indexOfAnyPos(u8, e.block, p, "\"'") orelse continue;
            const target = e.block[p..end];
            for (entries.items) |o| if (o.id != e.id and std.mem.eql(u8, o.slug, target)) {
                // the paragraph around the link (as plain text), as the detail
                const p0 = std.mem.lastIndexOf(u8, e.block[0..at], "<p>") orelse 0;
                const p1 = std.mem.indexOfPos(u8, e.block, at, "</p>") orelse e.block.len;
                const para = try plain(b.gpa, e.block[p0..p1]);
                try b.rel(e.id, "associated", o.id, para[0..@min(para.len, 400)], try std.fmt.allocPrint(b.gpa, "{s}#{s}", .{ W_URL, e.slug }), "");
            };
        }
    }
    return entries.items.len;
}

fn joinStrings(gpa: std.mem.Allocator, v: ?json.Value) ![]const u8 {
    const arr = v orelse return "";
    if (arr != .array) return "";
    var o: std.ArrayList(u8) = .empty;
    for (arr.array.items, 0..) |x, k| {
        if (x != .string) continue;
        if (k > 0) try o.appendSlice(gpa, "\n");
        try o.appendSlice(gpa, x.string);
    }
    return o.items;
}

fn str(v: json.Value, key: []const u8) []const u8 {
    const x = v.object.get(key) orelse return "";
    return if (x == .string) x.string else "";
}

/// data/verdicts.json: the reviewed layer ({"packages": {name: verdict}}).
fn loadVerdicts(b: *Builder, data: []const u8) !usize {
    const root = try json.parseFromSliceLeaky(json.Value, b.gpa, data, .{});
    const pk = (root.object.get("packages") orelse fatal("verdicts: no \"packages\"", .{})).object;
    const ins = try b.db.prepare("INSERT INTO verdict(package,tier,axis,reason,sources,alternatives,date,status,entities,tags) VALUES (?,?,?,?,?,?,?,?,?,?)");
    var it = pk.iterator();
    var n: usize = 0;
    while (it.next()) |e| {
        const v = e.value_ptr.*;
        ins.reset();
        try ins.bind(1, e.key_ptr.*);
        try ins.bind(2, str(v, "tier"));
        try ins.bind(3, str(v, "axis"));
        try ins.bind(4, str(v, "reason"));
        try ins.bind(5, try joinStrings(b.gpa, v.object.get("sources")));
        try ins.bind(6, try joinStrings(b.gpa, v.object.get("alternatives")));
        try ins.bind(7, str(v, "date"));
        try ins.bind(8, str(v, "status"));
        try ins.bind(9, try joinStrings(b.gpa, v.object.get("entities")));
        var explicit: std.ArrayList(u8) = .empty;
        if (v.object.get("tags")) |tg| if (tg == .array) for (tg.array.items) |t| if (t == .string) {
            if (explicit.items.len > 0) try explicit.append(b.gpa, ' ');
            try explicit.appendSlice(b.gpa, t.string);
        };
        try ins.bind(10, explicit.items);
        _ = try ins.step();
        _ = try b.entity("package", e.key_ptr.*, "", "");
        n += 1;
    }
    ins.finalize();
    return n;
}

/// data/relations.json: [{"src": "kind:name", "rel": "...", "dst": "kind:name",
/// "detail": "...", "source": "url"}], e.g. package:neovim packages project:NeoVim.
fn loadRelations(b: *Builder, data: []const u8) !void {
    const root = try json.parseFromSliceLeaky(json.Value, b.gpa, data, .{});
    if (root != .array) fatal("relations: expected a JSON array", .{});
    for (root.array.items) |r| {
        const s = str(r, "src");
        const d = str(r, "dst");
        const sc = std.mem.indexOfScalar(u8, s, ':') orelse fatal("relations: src \"{s}\" isn't kind:name", .{s});
        const dc = std.mem.indexOfScalar(u8, d, ':') orelse fatal("relations: dst \"{s}\" isn't kind:name", .{d});
        const src = try b.entity(s[0..sc], s[sc + 1 ..], "", "");
        const dst = try b.entity(d[0..dc], d[dc + 1 ..], "", "");
        try b.rel(src, str(r, "rel"), dst, str(r, "detail"), str(r, "source"), str(r, "date"));
    }
}

// ------------------------------------------------------------ tags

/// First case-insensitive occurrence of `kw` starting at a word boundary.
fn findKeyword(text: []const u8, kw: []const u8) ?usize {
    var from: usize = 0;
    while (from + kw.len <= text.len) {
        const at = std.ascii.indexOfIgnoreCasePos(text, from, kw) orelse return null;
        if (at == 0 or !std.ascii.isAlphanumeric(text[at - 1])) return at;
        from = at + 1;
    }
    return null;
}

/// Cut at n bytes without splitting a UTF-8 character.
fn safeCut(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var e = n;
    while (e > 0 and (s[e] & 0xC0) == 0x80) e -= 1;
    return s[0..e];
}

/// The sentence of `text` containing byte `at`, for tag evidence.
fn sentenceAround(text: []const u8, at: usize) []const u8 {
    var s: usize = 0;
    if (std.mem.lastIndexOf(u8, text[0..at], ". ")) |p| s = p + 2;
    if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |p| s = @max(s, p + 1);
    var e: usize = text.len;
    if (std.mem.indexOfPos(u8, text, at, ". ")) |p| e = p + 1;
    if (std.mem.indexOfScalarPos(u8, text, at, '\n')) |p| e = @min(e, p);
    return safeCut(text[s..e], 280);
}

fn entityByRef(b: *Builder, ref: []const u8) !i64 {
    const c = std.mem.indexOfScalar(u8, ref, ':') orelse fatal("\"{s}\" isn't kind:name", .{ref});
    b.find_entity.reset();
    try b.find_entity.bind(1, ref[0..c]);
    try b.find_entity.bind(2, ref[c + 1 ..]);
    if (!try b.find_entity.step()) fatal("no entity {s} in the graph", .{ref});
    return b.find_entity.int(0);
}

/// Categories (data/tags.json): each tag on an entity records why.
fn applyTags(b: *Builder, data: []const u8) !void {
    const root = try json.parseFromSliceLeaky(json.Value, b.gpa, data, .{});
    const defs = (root.object.get("tags") orelse fatal("tags.json: no \"tags\"", .{})).object;
    const ins_def = try b.db.prepare("INSERT INTO tag_def VALUES (?,?,?)");
    var di = defs.iterator();
    while (di.next()) |e| {
        ins_def.reset();
        try ins_def.bind(1, e.key_ptr.*);
        try ins_def.bind(2, str(e.value_ptr.*, "title"));
        try ins_def.bind(3, str(e.value_ptr.*, "description"));
        _ = try ins_def.step();
    }
    ins_def.finalize();

    const ins = try b.db.prepare("INSERT OR IGNORE INTO entity_tag(entity,tag,evidence,source,method) VALUES (?,?,?,?,?)");
    const Row = struct { id: i64, desc: []const u8, list: []const u8, source: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    {
        const q = try b.db.prepare("SELECT e.id, e.description, l.name, r.source FROM relation r JOIN entity e ON e.id = r.src JOIN entity l ON l.id = r.dst WHERE r.rel = 'listed_on'");
        defer q.finalize();
        while (try q.step()) try rows.append(b.gpa, .{ .id = q.int(0), .desc = try b.gpa.dupe(u8, q.text(1)), .list = try b.gpa.dupe(u8, q.text(2)), .source = try b.gpa.dupe(u8, q.text(3)) });
    }
    const defaults = if (root.object.get("list_defaults")) |d| d.object else null;
    const keywords = (root.object.get("keywords") orelse fatal("tags.json: no \"keywords\"", .{})).object;
    const hints = if (root.object.get("link_hints")) |h| h.object else null;
    var added: usize = 0;
    for (rows.items) |row| {
        const put = struct {
            fn go(i: @TypeOf(ins), id: i64, tag: []const u8, ev: []const u8, src: []const u8, m: []const u8) !void {
                i.reset();
                try i.bind(1, id);
                try i.bind(2, tag);
                try i.bind(3, ev);
                try i.bind(4, src);
                try i.bind(5, m);
                _ = try i.step();
            }
        }.go;
        if (defaults) |d| if (d.get(row.list)) |ld| {
            if (ld.object.get("tags")) |tl| for (tl.array.items) |t| {
                try put(ins, row.id, t.string, str(ld, "evidence"), row.source, "list-default");
                added += 1;
            };
        };
        var ki = keywords.iterator();
        while (ki.next()) |e| {
            for (e.value_ptr.array.items) |kw| {
                const at = findKeyword(row.desc, kw.string) orelse continue;
                try put(ins, row.id, e.key_ptr.*, sentenceAround(row.desc, at), row.source, "list-text");
                added += 1;
                break; // one piece of evidence per tag is enough
            }
        }
        if (hints) |h| {
            var hi = h.iterator();
            while (hi.next()) |e| {
                if (std.mem.indexOf(u8, row.source, e.key_ptr.*) == null) continue;
                for (e.value_ptr.array.items) |t| {
                    try put(ins, row.id, t.string, try std.fmt.allocPrint(b.gpa, "cited source: {s}", .{row.source}), row.source, "link-hint");
                    added += 1;
                }
            }
        }
    }
    // hand-made additions and removals
    if (root.object.get("add")) |a| for (a.array.items) |x| {
        const id = try entityByRef(b, str(x, "entity"));
        ins.reset();
        try ins.bind(1, id);
        try ins.bind(2, str(x, "tag"));
        try ins.bind(3, str(x, "evidence"));
        try ins.bind(4, str(x, "source"));
        try ins.bind(5, "manual");
        _ = try ins.step();
    };
    ins.finalize();
    if (root.object.get("suppress")) |a| for (a.array.items) |x| {
        const id = try entityByRef(b, str(x, "entity"));
        const del = try b.db.prepare("DELETE FROM entity_tag WHERE entity = ? AND tag = ? AND method <> 'manual'");
        try del.bind(1, id);
        try del.bind(2, str(x, "tag"));
        _ = try del.step();
        del.finalize();
    };
    std.debug.print("build_db: {d} tags applied ({d} list entries)\n", .{ added, rows.items.len });
}

/// A verdict's tags: its own plus those of the list entities it names. A tag
/// is firm (the list's own definition, or checked by hand) or inferred from
/// the entry's text; inferred ones get a "~" suffix.
fn finishVerdicts(b: *Builder) !void {
    const V = struct { pkg: []const u8, entities: []const u8, own: []const u8 };
    var vs: std.ArrayList(V) = .empty;
    {
        const q = try b.db.prepare("SELECT package, entities, tags FROM verdict");
        defer q.finalize();
        while (try q.step()) try vs.append(b.gpa, .{ .pkg = try b.gpa.dupe(u8, q.text(0)), .entities = try b.gpa.dupe(u8, q.text(1)), .own = try b.gpa.dupe(u8, q.text(2)) });
    }
    const upd = try b.db.prepare("UPDATE verdict SET tags = ? WHERE package = ?");
    const q_tags = try b.db.prepare("SELECT tag, max(method IN ('list-default', 'manual')) FROM entity_tag WHERE entity = ? GROUP BY tag");
    const T = struct { tag: []const u8, firm: bool };
    for (vs.items) |v| {
        var set: std.ArrayList(T) = .empty;
        var own = std.mem.tokenizeScalar(u8, v.own, ' ');
        while (own.next()) |t| try set.append(b.gpa, .{ .tag = t, .firm = true }); // named in verdicts.json: checked by hand
        var ents = std.mem.tokenizeScalar(u8, v.entities, '\n');
        while (ents.next()) |ref| {
            const id = try entityByRef(b, ref);
            q_tags.reset();
            try q_tags.bind(1, id);
            while (try q_tags.step()) {
                const t = q_tags.text(0);
                const firm = q_tags.int(1) == 1;
                var found = false;
                for (set.items) |*x| if (std.mem.eql(u8, x.tag, t)) {
                    x.firm = x.firm or firm;
                    found = true;
                };
                if (!found) try set.append(b.gpa, .{ .tag = try b.gpa.dupe(u8, t), .firm = firm });
            }
        }
        std.mem.sort(T, set.items, {}, struct {
            fn lt(_: void, a: T, c: T) bool {
                return std.mem.lessThan(u8, a.tag, c.tag);
            }
        }.lt);
        var joined: std.ArrayList(u8) = .empty;
        for (set.items, 0..) |t, k| {
            if (k > 0) try joined.append(b.gpa, ' ');
            try joined.appendSlice(b.gpa, t.tag);
            if (!t.firm) try joined.append(b.gpa, '~');
        }
        upd.reset();
        try upd.bind(1, joined.items);
        try upd.bind(2, v.pkg);
        _ = try upd.step();
    }
    q_tags.finalize();
    upd.finalize();
}

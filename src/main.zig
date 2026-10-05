//! whoseware — who owns, leads or funds the software you run?
//!
//! An entity graph (people, companies, projects, packages; who maintains,
//! founded, funds, forked what; who is on which list, with sources) is built
//! at release time (build_db) and embedded in this binary. For each package:
//!
//!   1. a reviewed verdict, if there is one (HIT / clean / infra);
//!   2. else a walk of the graph from the package to anyone on a list,
//!      printed as an evidence chain;
//!   3. else a fuzzy match of the package (and its upstream's name) against
//!      the graph — trigram full-text search ranked by BM25, plus vector
//!      similarity of hashed trigrams (libSQL) — followed by the same walk,
//!      reported as MAYBE with the similarity.
//!
//!   whoseware PACKAGE…          whoseware --system
//!   whoseware --pacman-hook     (names on stdin; only speaks up for hits,
//!                                never fails)
//! Options: --fail-on-hit (exit 1 on any HIT), --about (graph facts).
//! No network: the graph changes with whoseware releases.
const std = @import("std");
const Io = std.Io;
const ngram = @import("ngram.zig");
const dbm = @import("db.zig");

const version = "0.1.0";
const image = @embedFile("gen/entities.db");
const min_similarity = 0.80;

const usage =
    \\usage: whoseware [--fail-on-hit] PACKAGE…
    \\       whoseware [--fail-on-hit] --system      every explicitly installed package
    \\       whoseware --pacman-hook                 package names on stdin; informs, never fails
    \\       whoseware --about                       what the embedded graph contains
    \\
;

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    db: dbm.Db,
    out: *Io.Writer,
    color: bool,
    hook: bool,
    urls: std.StringHashMapUnmanaged([]const u8) = .empty, // package → upstream URL (pacman)
    // every matchable entity's trigram vector, loaded once: comparing them
    // in Zig takes microseconds, libSQL's vector_top_k took ~0.3 s a query
    vecs: std.ArrayList(Vec) = .empty,
    q_verdict: dbm.Stmt,
    q_entity: dbm.Stmt,
    q_listed: dbm.Stmt,
    q_out: dbm.Stmt,
    q_known_by: dbm.Stmt,
    q_fts: dbm.Stmt,

    fn paint(c: *Ctx, code: []const u8, s: []const u8) !void {
        if (c.color) try c.out.print("\x1b[{s}m{s}\x1b[0m", .{ code, s }) else try c.out.writeAll(s);
    }
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("whoseware: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const argv = init.minimal.args.vector;

    var fail_on_hit = false;
    var system = false;
    var hook = false;
    var about = false;
    var names: std.ArrayList([]const u8) = .empty;
    for (argv[1..]) |raw| {
        const a = std.mem.span(raw);
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, a, "--version")) {
            std.debug.print("whoseware {s}\n", .{version});
            return;
        } else if (std.mem.eql(u8, a, "--fail-on-hit")) fail_on_hit = true
        else if (std.mem.eql(u8, a, "--system")) system = true
        else if (std.mem.eql(u8, a, "--pacman-hook")) hook = true
        else if (std.mem.eql(u8, a, "--about")) about = true
        else if (a.len > 0 and a[0] == '-') fatal("unknown option {s}\n{s}", .{ a, usage })
        else try names.append(gpa, a);
    }

    var buf: [16 * 1024]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    defer fw.interface.flush() catch {};

    const db = dbm.Db.fromImage(image) catch fatal("can't open the embedded graph", .{});
    var ctx: Ctx = .{
        .gpa = gpa,
        .io = io,
        .db = db,
        .out = &fw.interface,
        .color = !hook and (Io.File.stdout().isTty(io) catch false) and init.environ_map.get("NO_COLOR") == null,
        .hook = hook,
        .q_verdict = try db.prepare("SELECT tier, axis, reason, sources, alternatives, date, status FROM verdict WHERE package = ?"),
        .q_entity = try db.prepare("SELECT id FROM entity WHERE kind = 'package' AND name = ?"),
        .q_listed = try db.prepare("SELECT l.name, r.source, r.date FROM relation r JOIN entity l ON l.id = r.dst WHERE r.src = ? AND r.rel = 'listed_on'"),
        .q_out = try db.prepare("SELECT r.rel, e.id, e.name, e.kind, r.detail FROM relation r JOIN entity e ON e.id = r.dst WHERE r.src = ? AND r.rel NOT IN ('listed_on', 'known_for', 'associated')"),
        .q_known_by = try db.prepare("SELECT e.id, e.name, e.kind, r.detail FROM relation r JOIN entity e ON e.id = r.src WHERE r.dst = ? AND r.rel = 'known_for'"),
        .q_fts = try db.prepare(
            \\SELECT e.id, e.name, e.kind, 1 - vector_distance_cos(e.emb, vector32(?1)) AS sim
            \\FROM entity_fts f JOIN entity e ON e.id = f.rowid
            \\WHERE entity_fts MATCH ?2 AND e.kind IN ('project', 'company', 'person')
            \\ORDER BY bm25(entity_fts) LIMIT 8
        ),
    };

    if (about) return aboutGraph(&ctx);

    if (system) {
        const r = std.process.run(gpa, io, .{ .argv = &.{ "pacman", "-Qqe" } }) catch |e| fatal("running pacman -Qqe: {s}", .{@errorName(e)});
        var it = std.mem.tokenizeAny(u8, r.stdout, "\n");
        while (it.next()) |n| try names.append(gpa, n);
    }
    if (hook) {
        var rbuf: [4096]u8 = undefined;
        var fr = Io.File.stdin().reader(io, &rbuf);
        const in = try fr.interface.allocRemaining(gpa, .unlimited);
        var it = std.mem.tokenizeAny(u8, in, "\n ");
        while (it.next()) |n| try names.append(gpa, n);
    }
    if (names.items.len == 0) fatal("nothing to check\n{s}", .{usage});
    if (!hook) try loadUrls(&ctx, names.items);

    var hits: usize = 0;
    var maybes: usize = 0;
    for (names.items) |n| switch (try report(&ctx, n)) {
        .hit => hits += 1,
        .maybe => maybes += 1,
        .none => {},
    };
    if (!hook and names.items.len > 1)
        try ctx.out.print("\n{d} packages: {d} hit{s}, {d} maybe\n", .{ names.items.len, hits, if (hits == 1) "" else "s", maybes });
    try ctx.out.flush();
    if (fail_on_hit and hits > 0) std.process.exit(1);
}

fn aboutGraph(ctx: *Ctx) !void {
    const q = try ctx.db.prepare("SELECT kind, count(*) FROM entity GROUP BY kind ORDER BY 2 DESC");
    try ctx.out.print("whoseware {s}, embedded graph:\n", .{version});
    while (try q.step()) try ctx.out.print("  {d:>6} {s}\n", .{ @as(u64, @intCast(q.int(1))), q.text(0) });
    const r = try ctx.db.prepare("SELECT count(*) FROM relation");
    _ = try r.step();
    try ctx.out.print("  {d:>6} relations\n", .{@as(u64, @intCast(r.int(0)))});
    const m = try ctx.db.prepare("SELECT key, value FROM meta");
    while (try m.step()) try ctx.out.print("  {s}: {s}\n", .{ m.text(0), m.text(1) });
}

const Vec = struct { id: i64, name: []const u8, kind: []const u8, v: [ngram.dims]f32 };

fn loadVecs(ctx: *Ctx) !void {
    const q = try ctx.db.prepare("SELECT id, name, kind, emb FROM entity WHERE kind IN ('project', 'company', 'person')");
    defer q.finalize();
    while (try q.step()) {
        const blob = dbm.c.sqlite3_column_blob(q.h, 3) orelse continue;
        if (dbm.c.sqlite3_column_bytes(q.h, 3) < ngram.dims * 4) continue;
        var v: [ngram.dims]f32 = undefined;
        @memcpy(std.mem.sliceAsBytes(&v), @as([*]const u8, @ptrCast(blob))[0 .. ngram.dims * 4]);
        try ctx.vecs.append(ctx.gpa, .{ .id = q.int(0), .name = try ctx.gpa.dupe(u8, q.text(1)), .kind = try ctx.gpa.dupe(u8, q.text(2)), .v = v });
    }
}

const Outcome = enum { hit, maybe, none };

fn report(ctx: *Ctx, name: []const u8) !Outcome {
    const out = ctx.out;
    // 1. reviewed verdict
    ctx.q_verdict.reset();
    try ctx.q_verdict.bind(1, name);
    if (try ctx.q_verdict.step()) {
        const v = ctx.q_verdict;
        const tier = v.text(0);
        if (std.mem.eql(u8, tier, "hit")) {
            try out.print("{s:<22} ", .{name});
            try ctx.paint("1;31", "HIT  ");
            try out.print(" {s}: {s}\n", .{ v.text(1), v.text(2) });
            if (v.text(4).len > 0) {
                try out.writeAll("                       alternatives: ");
                try writeJoined(out, v.text(4), ", ");
                try out.writeAll("\n");
            }
            try out.print("                       {s} {s} · ", .{ v.text(6), v.text(5) });
            try writeJoined(out, v.text(3), " · ");
            try out.writeAll("\n");
            return .hit;
        }
        if (ctx.hook) return .none;
        try out.print("{s:<22} ", .{name});
        if (std.mem.eql(u8, tier, "clean")) try ctx.paint("32", "clean") else if (std.mem.eql(u8, tier, "infra")) try ctx.paint("2", "infra") else try out.writeAll(tier);
        if (v.text(2).len > 0) try out.print("  {s}", .{v.text(2)});
        try out.writeAll("\n");
        return .none;
    }

    // 2. the package itself in the graph
    var chains: std.ArrayList([]const u8) = .empty;
    ctx.q_entity.reset();
    try ctx.q_entity.bind(1, name);
    if (try ctx.q_entity.step()) {
        const id = ctx.q_entity.int(0);
        try walk(ctx, id, try ctx.gpa.dupe(u8, name), 0, &chains);
    }
    var label: []const u8 = "";
    // 3. fuzzy: the name and its upstream's name against the graph
    if (chains.items.len == 0) {
        const terms = try searchTerms(ctx, name);
        for (terms) |t| {
            const m = try fuzzy(ctx, t) orelse continue;
            try walk(ctx, m.id, try std.fmt.allocPrint(ctx.gpa, "{s} ≈ {s} ({s}, {d:.0}% similar)", .{ name, m.name, m.kind, m.sim * 100 }), 0, &chains);
            if (chains.items.len > 0) {
                label = "MAYBE";
                break;
            }
        }
    } else label = "LINKED";

    if (chains.items.len == 0) {
        if (!ctx.hook) {
            try out.print("{s:<22} ", .{name});
            try ctx.paint("2", "?    ");
            try out.writeAll(" no verdict, no link to a listed entity\n");
        }
        return .none;
    }
    try out.print("{s:<22} ", .{name});
    try ctx.paint("1;33", label);
    try out.writeAll(if (std.mem.eql(u8, label, "MAYBE")) " no verdict; a similar name links to a listed entity (unverified):\n" else " no verdict, but the graph links it to a listed entity:\n");
    for (chains.items[0..@min(chains.items.len, 3)]) |ch| try out.print("                       {s}\n", .{ch});
    return .maybe;
}

/// Depth-first from `id`: forward relations (packages, maintains, funds,
/// forked_from, depends_on, …) and backwards along known_for (a project →
/// who is known for it), recording a chain at every listed entity.
fn walk(ctx: *Ctx, id: i64, path: []const u8, depth: usize, chains: *std.ArrayList([]const u8)) !void {
    if (chains.items.len >= 3) return;
    // is this entity listed?
    {
        const q = try ctx.db.prepare("SELECT l.name, r.source FROM relation r JOIN entity l ON l.id = r.dst WHERE r.src = ? AND r.rel = 'listed_on'");
        defer q.finalize();
        try q.bind(1, id);
        outer: while (try q.step()) {
            const ch = try std.fmt.allocPrint(ctx.gpa, "{s} — on the {s} list: {s}", .{ path, q.text(0), q.text(1) });
            for (chains.items) |old| if (std.mem.eql(u8, old, ch)) continue :outer;
            try chains.append(ctx.gpa, ch);
        }
    }
    if (depth >= 3) return;
    const Next = struct { id: i64, step: []const u8 };
    var next: std.ArrayList(Next) = .empty;
    {
        const q = try ctx.db.prepare("SELECT r.rel, e.id, e.name, r.detail FROM relation r JOIN entity e ON e.id = r.dst WHERE r.src = ? AND r.rel NOT IN ('listed_on', 'known_for', 'associated')");
        defer q.finalize();
        try q.bind(1, id);
        while (try q.step()) try next.append(ctx.gpa, .{ .id = q.int(1), .step = try std.fmt.allocPrint(ctx.gpa, " →{s}→ {s}", .{ q.text(0), q.text(2) }) });
    }
    {
        const q = try ctx.db.prepare("SELECT e.id, e.name, r.detail FROM relation r JOIN entity e ON e.id = r.src WHERE r.dst = ? AND r.rel = 'known_for'");
        defer q.finalize();
        try q.bind(1, id);
        while (try q.step()) {
            const detail = q.text(2);
            try next.append(ctx.gpa, .{ .id = q.int(0), .step = if (detail.len > 0)
                try std.fmt.allocPrint(ctx.gpa, " ← {s} of: {s}", .{ detail, q.text(1) })
            else
                try std.fmt.allocPrint(ctx.gpa, " ← known for by: {s}", .{q.text(1)}) });
        }
    }
    for (next.items) |n| try walk(ctx, n.id, try std.fmt.allocPrint(ctx.gpa, "{s}{s}", .{ path, n.step }), depth + 1, chains);
}

const Match = struct { id: i64, name: []const u8, kind: []const u8, sim: f64 };

/// Best graph entity whose name is close to `term`: full-text trigram search
/// first (BM25), vector similarity as the fallback; only near-identical names.
fn fuzzy(ctx: *Ctx, term: []const u8) !?Match {
    var vbuf: [2048]u8 = undefined;
    const vec = ngram.toText(&vbuf, ngram.embed(term));
    var best: ?Match = null;
    if (term.len >= 3) {
        const q = ctx.q_fts;
        q.reset();
        try q.bind(1, vec);
        try q.bind(2, try std.fmt.allocPrint(ctx.gpa, "\"{s}\"", .{term}));
        while (q.step() catch false) {
            const sim = q.float(3);
            if (sim >= min_similarity and (best == null or sim > best.?.sim))
                best = .{ .id = q.int(0), .name = try ctx.gpa.dupe(u8, q.text(1)), .kind = try ctx.gpa.dupe(u8, q.text(2)), .sim = sim };
        }
    }
    if (best == null) {
        if (ctx.vecs.items.len == 0) try loadVecs(ctx);
        const tv = ngram.embed(term);
        for (ctx.vecs.items) |e| {
            const sim: f64 = ngram.cosine(tv, e.v);
            if (sim >= min_similarity and (best == null or sim > best.?.sim))
                best = .{ .id = e.id, .name = e.name, .kind = e.kind, .sim = sim };
        }
    }
    return best;
}

/// The package name, it without -git/-bin/… suffixes, and its upstream
/// repository's name (last path segment of pacman's URL field).
fn searchTerms(ctx: *Ctx, name: []const u8) ![][]const u8 {
    var terms: std.ArrayList([]const u8) = .empty;
    try terms.append(ctx.gpa, name);
    for ([_][]const u8{ "-git", "-bin", "-fresh", "-still", "-desktop", "-cli", "-core" }) |suf| {
        if (std.mem.endsWith(u8, name, suf)) try terms.append(ctx.gpa, name[0 .. name.len - suf.len]);
    }
    if (ctx.urls.get(name)) |raw| {
        const url = std.mem.trimEnd(u8, raw, "/");
        const seg = url[(std.mem.lastIndexOfScalar(u8, url, '/') orelse 0) + 1 ..];
        if (seg.len >= 4 and std.mem.indexOfScalar(u8, seg, '.') == null and !std.ascii.eqlIgnoreCase(seg, name))
            try terms.append(ctx.gpa, seg);
    }
    return terms.items;
}

/// Upstream URLs of all packages in two pacman calls (installed ones via
/// -Qi, the rest via -Si) instead of one or two per package.
fn loadUrls(ctx: *Ctx, names: []const []const u8) !void {
    for ([_][]const u8{ "-Qi", "-Si" }) |flag| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(ctx.gpa, &.{ "pacman", flag });
        for (names) |n| if (!ctx.urls.contains(n)) try argv.append(ctx.gpa, n);
        if (argv.items.len == 2) return;
        const r = std.process.run(ctx.gpa, ctx.io, .{ .argv = argv.items }) catch return;
        var current: ?[]const u8 = null;
        var lines = std.mem.tokenizeScalar(u8, r.stdout, '\n');
        while (lines.next()) |line| {
            const c = std.mem.indexOf(u8, line, ": ") orelse continue;
            const key = std.mem.trim(u8, line[0..c], " ");
            const val = std.mem.trim(u8, line[c + 2 ..], " ");
            if (std.mem.eql(u8, key, "Name")) current = val else if (std.mem.eql(u8, key, "URL")) {
                if (current) |n| if (!ctx.urls.contains(n)) try ctx.urls.put(ctx.gpa, n, val);
            }
        }
    }
}

fn writeJoined(out: *Io.Writer, nl_separated: []const u8, sep: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, nl_separated, '\n');
    var first = true;
    while (it.next()) |x| {
        if (!first) try out.writeAll(sep);
        first = false;
        try out.writeAll(x);
    }
}

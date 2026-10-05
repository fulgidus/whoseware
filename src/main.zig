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
//!   whoseware setup | tags | who NAME | search WORDS…
//! Options: --fail-on-hit (exit 1 on any HIT), --about (graph facts).
//! No network: the graph changes with whoseware releases.
//!
//! Entities carry categories (fascism, racism, militarism, …), each with the
//! reason it was assigned; `setup` (offered on the first interactive run)
//! chooses which ones to flag. Everything is on until you choose.
const std = @import("std");
const Io = std.Io;
const ngram = @import("ngram.zig");
const dbm = @import("db.zig");

// build.sh copies VERSION here, so the binary can't disagree with the release.
const version = std.mem.trim(u8, @embedFile("gen/version.txt"), " \n");
const image = @embedFile("gen/entities.db");
const min_similarity = 0.80;

const usage =
    \\usage: whoseware [--fail-on-hit] PACKAGE…
    \\       whoseware [--fail-on-hit] --system      every explicitly installed package
    \\       whoseware --pacman-hook                 package names on stdin; informs, never fails
    \\       whoseware setup                         choose which categories to flag
    \\       whoseware tags                          the categories, and what is on
    \\       whoseware who NAME                      a person, company or project: tags and why, text, links
    \\       whoseware search [--tag T] WORDS…       full-text search over the descriptions (offline)
    \\       whoseware --about                       what the embedded graph contains
    \\
    \\options: --all-categories (ignore your setup for this run)
    \\
;

/// What to flag (written by `whoseware setup`). Without a config file:
/// everything.
const Config = struct {
    all: bool = true,
    cats: []const []const u8 = &.{},
    inferred: bool = true, // count tags inferred from entry text (marked ~)

    fn enabled(c: Config, tag: []const u8) bool {
        if (c.all) return true;
        for (c.cats) |x| if (std.mem.eql(u8, x, tag)) return true;
        return false;
    }

    /// Does a tag list ("bigotry~ fascism") count under this config? An
    /// entity with no tags (uncategorised) always counts.
    fn counts(c: Config, tags: []const u8) bool {
        var any = false;
        var it = std.mem.tokenizeScalar(u8, tags, ' ');
        while (it.next()) |t| {
            any = true;
            const inferred = std.mem.endsWith(u8, t, "~");
            if (c.enabled(std.mem.trimEnd(u8, t, "~")) and (!inferred or c.inferred)) return true;
        }
        return !any;
    }
};

fn loadConfig(gpa: std.mem.Allocator, io: Io, path: []const u8) ?Config {
    const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 10)) catch return null;
    var cfg: Config = .{};
    var cats: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "categories")) {
            if (std.mem.eql(u8, val, "all")) {
                cfg.all = true;
            } else {
                cfg.all = false;
                var it = std.mem.tokenizeAny(u8, val, ", ");
                while (it.next()) |t| cats.append(gpa, t) catch {};
            }
        } else if (std.mem.eql(u8, key, "inferred")) {
            cfg.inferred = !(std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "off") or std.mem.eql(u8, val, "false"));
        }
    }
    cfg.cats = cats.items;
    return cfg;
}

const Ctx = struct {
    cfg: Config = .{},
    config_path: []const u8 = "",
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
    var all_categories = false;
    var want_tag = false;
    var tag_filter: []const u8 = "";
    var names: std.ArrayList([]const u8) = .empty;
    for (argv[1..]) |raw| {
        const a = std.mem.span(raw);
        if (want_tag) {
            tag_filter = a;
            want_tag = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--tag")) {
            want_tag = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try Io.File.stdout().writeStreamingAll(io, usage);
            return;
        } else if (std.mem.eql(u8, a, "--version")) {
            try Io.File.stdout().writeStreamingAll(io, "whoseware " ++ "");
            try Io.File.stdout().writeStreamingAll(io, version);
            try Io.File.stdout().writeStreamingAll(io, "\n");
            return;
        } else if (std.mem.eql(u8, a, "--fail-on-hit")) fail_on_hit = true
        else if (std.mem.eql(u8, a, "--system")) system = true
        else if (std.mem.eql(u8, a, "--pacman-hook")) hook = true
        else if (std.mem.eql(u8, a, "--about")) about = true
        else if (std.mem.eql(u8, a, "--all-categories")) all_categories = true
        else if (a.len > 0 and a[0] == '-') fatal("unknown option {s}\n{s}", .{ a, usage })
        else try names.append(gpa, a);
    }

    var buf: [16 * 1024]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    defer fw.interface.flush() catch {};

    const home = init.environ_map.get("HOME") orelse "/tmp";
    const db = dbm.Db.fromImage(image) catch fatal("can't open the embedded graph", .{});
    var ctx: Ctx = .{
        .gpa = gpa,
        .io = io,
        .db = db,
        .out = &fw.interface,
        .color = !hook and (Io.File.stdout().isTty(io) catch false) and init.environ_map.get("NO_COLOR") == null,
        .hook = hook,
        .q_verdict = try db.prepare("SELECT tier, axis, reason, sources, alternatives, date, status, tags FROM verdict WHERE package = ?"),
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

    ctx.config_path = if (init.environ_map.get("WHOSEWARE_CONFIG")) |p| p else if (init.environ_map.get("XDG_CONFIG_HOME")) |x|
        try std.fmt.allocPrint(gpa, "{s}/whoseware/config", .{x})
    else
        try std.fmt.allocPrint(gpa, "{s}/.config/whoseware/config", .{home});
    const have_config = if (loadConfig(gpa, io, ctx.config_path)) |c| blk: {
        ctx.cfg = c;
        break :blk true;
    } else false;
    if (all_categories) ctx.cfg = .{};

    const cmd: []const u8 = if (names.items.len > 0) names.items[0] else "";
    if (std.mem.eql(u8, cmd, "setup")) return setup(&ctx, false);
    if (std.mem.eql(u8, cmd, "tags")) return tagsCmd(&ctx, have_config);
    if (std.mem.eql(u8, cmd, "who") and names.items.len > 1) return whoCmd(&ctx, try std.mem.join(gpa, " ", names.items[1..]));
    if (std.mem.eql(u8, cmd, "search") and names.items.len > 1) return searchCmd(&ctx, names.items[1..], tag_filter);
    if (about) return aboutGraph(&ctx);

    // First interactive run: let the person choose what to flag. Anywhere
    // else (scripts, the pacman hook, CI) everything is on until they do.
    if (!have_config and !hook and !all_categories and
        (Io.File.stdin().isTty(io) catch false) and (Io.File.stdout().isTty(io) catch false))
    {
        try setup(&ctx, true);
        try ctx.out.writeAll("\n");
        if (loadConfig(gpa, io, ctx.config_path)) |c| ctx.cfg = c;
    }

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
    try ctx.out.writeAll(
        \\
        \\sources (their text and links are embedded; every tag says which sentence it rests on):
        \\  fashware list                          https://git.sr.ht/~rabbits/fashware
        \\  weird little guys of FOSS (Drew DeVault)  https://drewdevault.com/weird-guys/
        \\Neither states a licence. Their text is included here with attribution and links;
        \\if an author objects it is removed in the next release.
        \\
    );
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
            const tags = v.text(7);
            if (!ctx.cfg.counts(tags)) {
                if (!ctx.hook) {
                    try out.print("{s:<22} ", .{name});
                    try ctx.paint("2", "off  ");
                    try out.print(" flagged only under categories you turned off: {s}\n", .{tags});
                }
                return .none;
            }
            try out.print("{s:<22} ", .{name});
            try ctx.paint("1;31", "HIT  ");
            if (tags.len > 0) try out.print(" [{s}]", .{tags});
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
            const m = try fuzzy(ctx, t, min_similarity) orelse continue;
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
    // is this entity listed (and does it count under the chosen categories)?
    const tags = try entityTags(ctx, id);
    if (ctx.cfg.counts(tags)) {
        const q = try ctx.db.prepare("SELECT l.name, r.source FROM relation r JOIN entity l ON l.id = r.dst WHERE r.src = ? AND r.rel = 'listed_on'");
        defer q.finalize();
        try q.bind(1, id);
        outer: while (try q.step()) {
            const ch = if (tags.len > 0)
                try std.fmt.allocPrint(ctx.gpa, "{s} — on the {s} list: {s} [{s}]", .{ path, q.text(0), q.text(1), tags })
            else
                try std.fmt.allocPrint(ctx.gpa, "{s} — on the {s} list: {s}", .{ path, q.text(0), q.text(1) });
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
fn fuzzy(ctx: *Ctx, term: []const u8, min_sim: f64) !?Match {
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
            if (sim >= min_sim and (best == null or sim > best.?.sim))
                best = .{ .id = q.int(0), .name = try ctx.gpa.dupe(u8, q.text(1)), .kind = try ctx.gpa.dupe(u8, q.text(2)), .sim = sim };
        }
    }
    if (best == null) {
        if (ctx.vecs.items.len == 0) try loadVecs(ctx);
        const tv = ngram.embed(term);
        for (ctx.vecs.items) |e| {
            const sim: f64 = ngram.cosine(tv, e.v);
            if (sim >= min_sim and (best == null or sim > best.?.sim))
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

// ------------------------------------------------------------ categories

/// An entity's tags as "bigotry~ fascism": "~" marks tags inferred from the
/// entry's text rather than the list's own definition or checked by hand.
fn entityTags(ctx: *Ctx, id: i64) ![]const u8 {
    const q = try ctx.db.prepare("SELECT tag, max(method IN ('list-default', 'manual')) FROM entity_tag WHERE entity = ? GROUP BY tag ORDER BY tag");
    defer q.finalize();
    try q.bind(1, id);
    var o: std.ArrayList(u8) = .empty;
    while (try q.step()) {
        if (o.items.len > 0) try o.append(ctx.gpa, ' ');
        try o.appendSlice(ctx.gpa, q.text(0));
        if (q.int(1) != 1) try o.append(ctx.gpa, '~');
    }
    return o.items;
}

fn methodLabel(m: []const u8) []const u8 {
    if (std.mem.eql(u8, m, "list-default")) return "the list's own definition";
    if (std.mem.eql(u8, m, "manual")) return "checked by hand";
    if (std.mem.eql(u8, m, "list-text")) return "inferred from the entry's text (~)";
    if (std.mem.eql(u8, m, "link-hint")) return "inferred from a cited source (~)";
    return m;
}

/// Text on one line each, indented.
fn writeIndented(out: *Io.Writer, text: []const u8, indent: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " ").len == 0) continue;
        try out.print("{s}{s}\n", .{ indent, line });
    }
}

/// `whoseware setup`: which categories to flag. Enter accepts everything.
fn setup(ctx: *Ctx, first_run: bool) !void {
    const out = ctx.out;
    if (first_run) try out.writeAll("First run: choose what whoseware should flag. Enter accepts everything; `whoseware setup` changes it later.\n\n");
    var names: std.ArrayList([]const u8) = .empty;
    {
        const q = try ctx.db.prepare("SELECT d.tag, d.title, d.description, (SELECT count(DISTINCT entity) FROM entity_tag WHERE tag = d.tag) FROM tag_def d ORDER BY d.rowid");
        defer q.finalize();
        while (try q.step()) {
            try names.append(ctx.gpa, try ctx.gpa.dupe(u8, q.text(0)));
            const n: u64 = @intCast(q.int(3));
            try out.print("  {d}. {s:<16} {s}: {s}  ({d} {s})\n", .{ names.items.len, q.text(0), q.text(1), q.text(2), n, if (n == 1) "entry" else "entries" });
        }
    }
    try out.writeAll("\nCategories to flag (numbers or names, Enter = all): ");
    try out.flush();
    var rbuf: [1024]u8 = undefined;
    var fr = Io.File.stdin().reader(ctx.io, &rbuf);
    const answer = std.mem.trim(u8, (fr.interface.takeDelimiter('\n') catch null) orelse "", " \t\r");

    var chosen: std.ArrayList([]const u8) = .empty;
    var all = answer.len == 0;
    var it = std.mem.tokenizeAny(u8, answer, ", ");
    while (it.next()) |t| {
        if (std.ascii.eqlIgnoreCase(t, "all")) {
            all = true;
            continue;
        }
        const num = std.fmt.parseInt(usize, t, 10) catch 0;
        var hit: ?[]const u8 = null;
        if (num >= 1 and num <= names.items.len) hit = names.items[num - 1];
        for (names.items) |n| if (std.ascii.eqlIgnoreCase(n, t)) {
            hit = n;
        };
        if (hit) |h| try chosen.append(ctx.gpa, h) else try out.print("  (ignoring \"{s}\": not a category)\n", .{t});
    }
    if (chosen.items.len == 0) all = true;

    try out.writeAll("Count tags inferred from an entry's text (marked ~) as well as the firm ones? [Y/n] ");
    try out.flush();
    const a2 = std.mem.trim(u8, (fr.interface.takeDelimiter('\n') catch null) orelse "", " \t\r");
    const inferred = !(a2.len > 0 and (a2[0] == 'n' or a2[0] == 'N'));

    var cats: std.ArrayList(u8) = .empty;
    if (all) try cats.appendSlice(ctx.gpa, "all") else for (chosen.items, 0..) |c, k| {
        if (k > 0) try cats.append(ctx.gpa, ',');
        try cats.appendSlice(ctx.gpa, c);
    }
    const text = try std.fmt.allocPrint(ctx.gpa, "# whoseware: what to flag. Change it with `whoseware setup`.\ncategories = {s}\ninferred = {s}\n", .{ cats.items, if (inferred) "yes" else "no" });
    if (std.mem.lastIndexOfScalar(u8, ctx.config_path, '/')) |sl| Io.Dir.cwd().createDirPath(ctx.io, ctx.config_path[0..sl]) catch {};
    Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = ctx.config_path, .data = text }) catch |e| fatal("can't write {s}: {s}", .{ ctx.config_path, @errorName(e) });
    try out.print("Saved to {s}: flagging {s}{s}.\n", .{ ctx.config_path, if (all) "everything" else cats.items, if (inferred) "" else ", firm tags only" });
}

/// `whoseware tags`: the categories and whether each is on.
fn tagsCmd(ctx: *Ctx, have_config: bool) !void {
    const out = ctx.out;
    const q = try ctx.db.prepare("SELECT d.tag, d.title, d.description, (SELECT count(DISTINCT entity) FROM entity_tag WHERE tag = d.tag) FROM tag_def d ORDER BY d.rowid");
    defer q.finalize();
    while (try q.step()) {
        const on = ctx.cfg.enabled(q.text(0));
        const n: u64 = @intCast(q.int(3));
        try out.print("  {s} {s:<16} {s}  ({d} {s})\n      {s}\n", .{ if (on) "[x]" else "[ ]", q.text(0), q.text(1), n, if (n == 1) "entry" else "entries", q.text(2) });
    }
    try out.print("\n{s}{s}; tags marked ~ are inferred from the entry's text ({s}).\n", .{
        if (have_config) "setup: " else "no setup yet: everything is on. ",
        ctx.config_path,
        if (ctx.cfg.inferred) "counted" else "not counted",
    });
}

/// `whoseware who NAME`: everything the graph holds about an entity.
fn whoCmd(ctx: *Ctx, name: []const u8) !void {
    const out = ctx.out;
    const found: ?Match = blk: {
        const q = try ctx.db.prepare("SELECT id, name, kind FROM entity WHERE kind IN ('person', 'company', 'project') AND (name = ?1 COLLATE NOCASE OR (aliases <> '' AND lower(aliases) LIKE '%' || lower(?1) || '%')) ORDER BY CASE kind WHEN 'person' THEN 0 WHEN 'company' THEN 1 ELSE 2 END LIMIT 1");
        defer q.finalize();
        try q.bind(1, name);
        if (try q.step()) break :blk Match{ .id = q.int(0), .name = try ctx.gpa.dupe(u8, q.text(1)), .kind = try ctx.gpa.dupe(u8, q.text(2)), .sim = 1 };
        break :blk try fuzzy(ctx, name, 0.6);
    };
    const m = found orelse {
        try out.print("no person, company or project matching \"{s}\" (try: whoseware search {s})\n", .{ name, name });
        return;
    };
    const q = try ctx.db.prepare("SELECT aliases, description, links FROM entity WHERE id = ?");
    defer q.finalize();
    try q.bind(1, m.id);
    _ = try q.step();
    try out.print("{s}  ({s}{s})", .{ m.name, m.kind, if (m.sim < 1) ", closest match" else "" });
    if (q.text(0).len > 0) try out.print("  aka {s}", .{q.text(0)});
    try out.writeAll("\n");

    // categories, each with why
    {
        const t = try ctx.db.prepare("SELECT t.tag, d.title, t.method, t.evidence, t.source FROM entity_tag t JOIN tag_def d ON d.tag = t.tag WHERE t.entity = ? ORDER BY t.tag, t.method");
        defer t.finalize();
        try t.bind(1, m.id);
        var any = false;
        while (try t.step()) {
            any = true;
            const firm = std.mem.eql(u8, t.text(2), "list-default") or std.mem.eql(u8, t.text(2), "manual");
            try out.print("  [{s}{s}] {s}, {s}\n", .{ t.text(0), if (firm) "" else "~", t.text(1), methodLabel(t.text(2)) });
            if (t.text(3).len > 0) try out.print("      \"{s}\"\n", .{t.text(3)});
            if (t.text(4).len > 0) try out.print("      {s}\n", .{t.text(4)});
        }
        if (!any) try out.writeAll("  (no categories recorded)\n");
    }
    // lists, what it's known for, associations, packages
    inline for (.{
        .{ "listed on", "SELECT l.name || ' · ' || r.source || CASE WHEN r.date <> '' THEN ' · added ' || r.date ELSE '' END FROM relation r JOIN entity l ON l.id = r.dst WHERE r.src = ? AND r.rel = 'listed_on'" },
        .{ "known for", "SELECT p.name || CASE WHEN r.detail <> '' THEN ' (' || r.detail || ')' ELSE '' END FROM relation r JOIN entity p ON p.id = r.dst WHERE r.src = ? AND r.rel = 'known_for'" },
        .{ "connected to", "SELECT p.name || ': ' || substr(r.detail, 1, 160) FROM relation r JOIN entity p ON p.id = r.dst WHERE r.src = ? AND r.rel = 'associated'" },
        .{ "packages", "SELECT pk.name FROM relation r JOIN entity pk ON pk.id = r.src WHERE r.dst = ? AND r.rel = 'packages'" },
    }) |pair| {
        const r = try ctx.db.prepare(pair[1]);
        defer r.finalize();
        try r.bind(1, m.id);
        var first = true;
        while (try r.step()) {
            if (first) try out.print("  {s}:\n", .{pair[0]});
            first = false;
            try out.print("      {s}\n", .{r.text(0)});
        }
    }
    if (q.text(1).len > 0) {
        try out.writeAll("  text (from the sources):\n");
        try writeIndented(out, q.text(1), "      ");
    }
    if (q.text(2).len > 0) {
        try out.writeAll("  links:\n");
        try writeIndented(out, q.text(2), "      ");
    }
}

/// `whoseware search WORDS…`: full-text, offline, ranked by BM25 (names
/// weigh more than descriptions); `--tag T` keeps one category.
fn searchCmd(ctx: *Ctx, words: []const []const u8, tag: []const u8) !void {
    const out = ctx.out;
    var qb: std.ArrayList(u8) = .empty;
    for (words) |w| {
        var it = std.mem.tokenizeScalar(u8, w, ' ');
        while (it.next()) |tok| {
            try qb.append(ctx.gpa, '"');
            for (tok) |ch| if (ch != '"') try qb.append(ctx.gpa, ch);
            try qb.appendSlice(ctx.gpa, "\" ");
        }
    }
    const q = try ctx.db.prepare(
        \\SELECT e.id, e.kind, e.name, snippet(entity_text, 2, '[', ']', '…', 18)
        \\FROM entity_text JOIN entity e ON e.id = entity_text.rowid
        \\WHERE entity_text MATCH ?1 AND (e.kind <> 'project' OR e.description <> '') AND (?2 = '' OR EXISTS (SELECT 1 FROM entity_tag t WHERE t.entity = e.id AND t.tag = ?2))
        \\ORDER BY bm25(entity_text, 8.0, 4.0, 1.0) LIMIT 12
    );
    defer q.finalize();
    try q.bind(1, qb.items);
    try q.bind(2, tag);
    var n: usize = 0;
    while (q.step() catch false) {
        n += 1;
        const tags = try entityTags(ctx, q.int(0));
        try out.print("{s}  ({s}){s}{s}{s}\n", .{ q.text(2), q.text(1), if (tags.len > 0) "  [" else "", tags, if (tags.len > 0) "]" else "" });
        const flat = try std.mem.replaceOwned(u8, ctx.gpa, q.text(3), "\n", " ");
        if (flat.len > 0) try out.print("      {s}\n", .{flat});
    }
    if (n == 0) try out.print("nothing matches \"{s}\"{s}\n", .{ std.mem.trim(u8, qb.items, " "), if (tag.len > 0) " in that category" else "" });
}

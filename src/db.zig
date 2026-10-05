//! A thin wrapper over libSQL's C API (vendor/libsql), shared by the
//! database builder and the CLI.
const std = @import("std");
pub const c = @cImport(@cInclude("sqlite3.h"));

pub const Db = struct {
    h: *c.sqlite3,

    pub fn open(path: [*:0]const u8) !Db {
        var h: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path, &h) != c.SQLITE_OK) return error.Open;
        return .{ .h = h.? };
    }

    /// An in-memory database holding a copy of `image` (an SQLite file),
    /// read-only: how the CLI opens the database embedded in its binary.
    pub fn fromImage(image: []const u8) !Db {
        const db = try open(":memory:");
        const mem: [*c]u8 = @ptrCast(c.sqlite3_malloc64(image.len) orelse return error.OutOfMemory);
        @memcpy(mem[0..image.len], image);
        const flags = c.SQLITE_DESERIALIZE_FREEONCLOSE | c.SQLITE_DESERIALIZE_READONLY;
        if (c.sqlite3_deserialize(db.h, "main", mem, @intCast(image.len), @intCast(image.len), flags) != c.SQLITE_OK)
            return error.Deserialize;
        return db;
    }

    pub fn close(db: Db) void {
        _ = c.sqlite3_close(db.h);
    }

    pub fn exec(db: Db, sql: [*:0]const u8) !void {
        var err: [*c]u8 = null;
        if (c.sqlite3_exec(db.h, sql, null, null, &err) != c.SQLITE_OK) {
            std.debug.print("sql error: {s}\n  in: {s}\n", .{ std.mem.span(err), std.mem.span(sql) });
            return error.Sql;
        }
    }

    pub fn prepare(db: Db, sql: [*:0]const u8) !Stmt {
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db.h, sql, -1, &s, null) != c.SQLITE_OK) {
            std.debug.print("sql error: {s}\n  in: {s}\n", .{ std.mem.span(c.sqlite3_errmsg(db.h)), std.mem.span(sql) });
            return error.Sql;
        }
        return .{ .h = s.?, .db = db.h };
    }

    pub fn lastId(db: Db) i64 {
        return c.sqlite3_last_insert_rowid(db.h);
    }
};

pub const Stmt = struct {
    h: *c.sqlite3_stmt,
    db: *c.sqlite3,

    pub fn bind(s: Stmt, i: c_int, v: anytype) !void {
        const T = @TypeOf(v);
        const rc = switch (@typeInfo(T)) {
            .int, .comptime_int => c.sqlite3_bind_int64(s.h, i, @intCast(v)),
            .float, .comptime_float => c.sqlite3_bind_double(s.h, i, v),
            .null => c.sqlite3_bind_null(s.h, i),
            else => blk: {
                const str: []const u8 = v;
                break :blk c.sqlite3_bind_text(s.h, i, str.ptr, @intCast(str.len), c.SQLITE_TRANSIENT);
            },
        };
        if (rc != c.SQLITE_OK) return error.Bind;
    }

    /// true while there's a row
    pub fn step(s: Stmt) !bool {
        return switch (c.sqlite3_step(s.h)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => {
                std.debug.print("sql error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(s.db))});
                return error.Step;
            },
        };
    }

    pub fn reset(s: Stmt) void {
        _ = c.sqlite3_reset(s.h);
        _ = c.sqlite3_clear_bindings(s.h);
    }

    pub fn text(s: Stmt, col: c_int) []const u8 {
        const p = c.sqlite3_column_text(s.h, col) orelse return "";
        return p[0..@intCast(c.sqlite3_column_bytes(s.h, col))];
    }

    pub fn int(s: Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(s.h, col);
    }

    pub fn float(s: Stmt, col: c_int) f64 {
        return c.sqlite3_column_double(s.h, col);
    }

    pub fn finalize(s: Stmt) void {
        _ = c.sqlite3_finalize(s.h);
    }
};

/// Schema of the embedded entity graph.
pub const schema =
    \\CREATE TABLE entity (
    \\  id INTEGER PRIMARY KEY,
    \\  kind TEXT NOT NULL,          -- person, company, project, package, list
    \\  name TEXT NOT NULL,
    \\  aliases TEXT NOT NULL DEFAULT '',
    \\  note TEXT NOT NULL DEFAULT '',
    \\  description TEXT NOT NULL DEFAULT '',  -- the sources' own text, full
    \\  links TEXT NOT NULL DEFAULT '',        -- source URLs, one per line
    \\  emb F32_BLOB(64)             -- hashed trigram vector of the name (ngram.zig)
    \\);
    \\CREATE TABLE tag_def (tag TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT NOT NULL);
    \\CREATE TABLE entity_tag (
    \\  entity INTEGER NOT NULL REFERENCES entity(id),
    \\  tag TEXT NOT NULL,
    \\  evidence TEXT NOT NULL DEFAULT '',  -- why: the sentence, the list's definition, the link
    \\  source TEXT NOT NULL DEFAULT '',
    \\  method TEXT NOT NULL,               -- list-default, list-text, link-hint, manual
    \\  PRIMARY KEY (entity, tag, method)
    \\);
    \\CREATE UNIQUE INDEX entity_kind_name ON entity(kind, name COLLATE NOCASE);
    \\CREATE TABLE relation (
    \\  src INTEGER NOT NULL REFERENCES entity(id),
    \\  rel TEXT NOT NULL,           -- listed_on, known_for, associated, packages, maintains, funds, forked_from, depends_on
    \\  dst INTEGER NOT NULL REFERENCES entity(id),
    \\  detail TEXT NOT NULL DEFAULT '',
    \\  source TEXT NOT NULL DEFAULT '',
    \\  date TEXT NOT NULL DEFAULT ''
    \\);
    \\CREATE INDEX relation_src ON relation(src, rel);
    \\CREATE INDEX relation_dst ON relation(dst, rel);
    \\CREATE TABLE verdict (
    \\  package TEXT PRIMARY KEY,
    \\  tier TEXT NOT NULL, axis TEXT NOT NULL DEFAULT '', reason TEXT NOT NULL DEFAULT '',
    \\  sources TEXT NOT NULL DEFAULT '', alternatives TEXT NOT NULL DEFAULT '',
    \\  date TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT '',
    \\  entities TEXT NOT NULL DEFAULT '',   -- list entities responsible, kind:name per line
    \\  tags TEXT NOT NULL DEFAULT ''        -- space-separated categories
    \\);
    \\CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    \\CREATE VIRTUAL TABLE entity_fts USING fts5(name, aliases, content='entity', content_rowid='id', tokenize='trigram');
    \\CREATE VIRTUAL TABLE entity_text USING fts5(name, aliases, description, tokenize='porter unicode61');
;

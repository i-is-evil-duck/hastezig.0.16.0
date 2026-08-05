const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    SqliteOpenFailed,
    SqliteStepFailed,
    SqliteQueryFailed,
    PasteNotFound,
};

pub const Blob = struct {
    lang: []const u8,
    content: []const u8,
};

pub const Paste = struct {
    id: []const u8,
    created_at: i64,
    blobs: []Blob,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Paste) void {
        for (self.blobs) |b| {
            self.gpa.free(b.lang);
            self.gpa.free(b.content);
        }
        self.gpa.free(self.blobs);
        self.gpa.free(self.id);
        self.* = undefined;
    }
};

pub const Db = struct {
    conn: *c.sqlite3,
    mutex: std.Io.Mutex = .init,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, path_z: [:0]const u8) !Db {
        var raw: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        const rc = c.sqlite3_open_v2(path_z.ptr, &raw, flags, null);
        if (rc != c.SQLITE_OK) {
            if (raw) |r| _ = c.sqlite3_close(r);
            return error.SqliteOpenFailed;
        }
        const conn = raw.?;
        errdefer _ = c.sqlite3_close(conn);

        var db: Db = .{ .conn = conn, .gpa = gpa };
        db.exec("PRAGMA journal_mode=WAL;") catch {};
        db.exec("PRAGMA synchronous=NORMAL;") catch {};
        db.exec(
            \\CREATE TABLE IF NOT EXISTS pastes (
            \\    id         TEXT PRIMARY KEY,
            \\    created_at INTEGER NOT NULL
            \\);
        ) catch |err| {
            return err;
        };
        db.exec(
            \\CREATE TABLE IF NOT EXISTS blobs (
            \\    paste_id   TEXT NOT NULL,
            \\    position   INTEGER NOT NULL,
            \\    lang       TEXT NOT NULL DEFAULT 'plaintext',
            \\    content    BLOB NOT NULL,
            \\    PRIMARY KEY (paste_id, position)
            \\);
        ) catch |err| {
            return err;
        };

        // Migrate the legacy single-content schema (pastes had lang/content
        // columns) into pastes + blobs.
        if (try db.tableHasColumn("pastes", "content")) {
            try db.exec(
                \\BEGIN;
                \\ALTER TABLE pastes RENAME TO pastes_old;
                \\CREATE TABLE pastes (
                \\    id         TEXT PRIMARY KEY,
                \\    created_at INTEGER NOT NULL
                \\);
                \\INSERT INTO pastes (id, created_at)
                \\    SELECT id, created_at FROM pastes_old;
                \\INSERT INTO blobs (paste_id, position, lang, content)
                \\    SELECT id, 0, lang, content FROM pastes_old;
                \\DROP TABLE pastes_old;
                \\COMMIT;
            );
        }
        return db;
    }

    pub fn deinit(self: *Db) void {
        _ = c.sqlite3_close(self.conn);
        self.conn = undefined;
    }

    fn exec(self: *Db, sql: []const u8) !void {
        var err_msg: ?[*:0]u8 = null;
        const rc = c.sqlite3_exec(self.conn, sql.ptr, null, null, @ptrCast(&err_msg));
        if (err_msg) |m| {
            std.debug.print("sqlite: {s}\n", .{m});
            c.sqlite3_free(m);
        }
        if (rc != c.SQLITE_OK) return error.SqliteQueryFailed;
    }

    fn tableHasColumn(
        self: *Db,
        comptime table: []const u8,
        comptime column: []const u8,
    ) !bool {
        var stmt: ?*c.sqlite3_stmt = null;
        defer finalize(stmt);

        var sql_buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(
            &sql_buf,
            "SELECT COUNT(*) FROM pragma_table_info('{s}') WHERE name = '{s}'",
            .{ table, column },
        ) catch return error.SqliteQueryFailed;

        const rc = c.sqlite3_prepare_v2(self.conn, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqliteQueryFailed;
        if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) return error.SqliteStepFailed;
        return c.sqlite3_column_int(stmt.?, 0) != 0;
    }

    /// Insert a paste. Caller guarantees `id` and all `blobs` fields stay
    /// alive until this returns.
    pub fn insert(
        self: *Db,
        io: std.Io,
        id: []const u8,
        blobs: []const Blob,
        created_at: i64,
    ) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.exec("BEGIN;") catch return error.SqliteQueryFailed;
        errdefer self.exec("ROLLBACK;") catch {};

        var pstmt: ?*c.sqlite3_stmt = null;
        defer finalize(pstmt);
        const psql = "INSERT INTO pastes (id, created_at) VALUES (?, ?)";
        if (c.sqlite3_prepare_v2(self.conn, psql.ptr, psql.len, &pstmt, null) != c.SQLITE_OK)
            return error.SqliteQueryFailed;
        if (c.sqlite3_bind_text(pstmt.?, 1, id.ptr, @intCast(id.len), null) != c.SQLITE_OK)
            return error.SqliteQueryFailed;
        if (c.sqlite3_bind_int64(pstmt.?, 2, created_at) != c.SQLITE_OK)
            return error.SqliteQueryFailed;
        if (c.sqlite3_step(pstmt.?) != c.SQLITE_DONE) return error.SqliteStepFailed;

        var bstmt: ?*c.sqlite3_stmt = null;
        defer finalize(bstmt);
        const bsql = "INSERT INTO blobs (paste_id, position, lang, content) VALUES (?, ?, ?, ?)";
        if (c.sqlite3_prepare_v2(self.conn, bsql.ptr, bsql.len, &bstmt, null) != c.SQLITE_OK)
            return error.SqliteQueryFailed;

        for (blobs, 0..) |blob, i| {
            if (c.sqlite3_bind_text(bstmt.?, 1, id.ptr, @intCast(id.len), null) != c.SQLITE_OK)
                return error.SqliteQueryFailed;
            if (c.sqlite3_bind_int(bstmt.?, 2, @intCast(i)) != c.SQLITE_OK)
                return error.SqliteQueryFailed;
            if (c.sqlite3_bind_text(bstmt.?, 3, blob.lang.ptr, @intCast(blob.lang.len), null) != c.SQLITE_OK)
                return error.SqliteQueryFailed;
            if (c.sqlite3_bind_text(bstmt.?, 4, blob.content.ptr, @intCast(blob.content.len), null) != c.SQLITE_OK)
                return error.SqliteQueryFailed;
            if (c.sqlite3_step(bstmt.?) != c.SQLITE_DONE) return error.SqliteStepFailed;
            _ = c.sqlite3_reset(bstmt.?);
        }

        self.exec("COMMIT;") catch return error.SqliteQueryFailed;
    }

    pub fn get(self: *Db, io: std.Io, id: []const u8) !?Paste {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var stmt: ?*c.sqlite3_stmt = null;
        defer finalize(stmt);

        const psql = "SELECT id, created_at FROM pastes WHERE id = ?";
        if (c.sqlite3_prepare_v2(self.conn, psql.ptr, psql.len, &stmt, null) != c.SQLITE_OK)
            return error.SqliteQueryFailed;
        if (c.sqlite3_bind_text(stmt.?, 1, id.ptr, @intCast(id.len), null) != c.SQLITE_OK)
            return error.SqliteQueryFailed;

        switch (c.sqlite3_step(stmt.?)) {
            c.SQLITE_DONE => return null,
            c.SQLITE_ROW => {},
            else => return error.SqliteStepFailed,
        }

        const id_raw = c.sqlite3_column_text(stmt.?, 0) orelse return error.SqliteStepFailed;
        const id_len = c.sqlite3_column_bytes(stmt.?, 0);
        const created_at = c.sqlite3_column_int64(stmt.?, 1);

        const paste_id = self.gpa.dupe(u8, id_raw[0..@intCast(id_len)]) catch |e| return e;
        errdefer self.gpa.free(paste_id);

        var blobs: std.ArrayList(Blob) = .empty;
        errdefer {
            for (blobs.items) |b| {
                self.gpa.free(b.lang);
                self.gpa.free(b.content);
            }
            blobs.deinit(self.gpa);
        }

        var bstmt: ?*c.sqlite3_stmt = null;
        defer finalize(bstmt);
        const bsql = "SELECT lang, content FROM blobs WHERE paste_id = ? ORDER BY position ASC";
        if (c.sqlite3_prepare_v2(self.conn, bsql.ptr, bsql.len, &bstmt, null) != c.SQLITE_OK)
            return error.SqliteQueryFailed;
        if (c.sqlite3_bind_text(bstmt.?, 1, id.ptr, @intCast(id.len), null) != c.SQLITE_OK)
            return error.SqliteQueryFailed;

        while (true) {
            switch (c.sqlite3_step(bstmt.?)) {
                c.SQLITE_ROW => {},
                c.SQLITE_DONE => break,
                else => return error.SqliteStepFailed,
            }
            const lang_raw = c.sqlite3_column_text(bstmt.?, 0) orelse return error.SqliteStepFailed;
            const lang_len = c.sqlite3_column_bytes(bstmt.?, 0);
            const content_raw = c.sqlite3_column_text(bstmt.?, 1) orelse return error.SqliteStepFailed;
            const content_len = c.sqlite3_column_bytes(bstmt.?, 1);

            const lang = self.gpa.dupe(u8, lang_raw[0..@intCast(lang_len)]) catch |e| return e;
            const content = self.gpa.dupe(u8, content_raw[0..@intCast(content_len)]) catch |e| {
                self.gpa.free(lang);
                return e;
            };
            blobs.append(self.gpa, .{ .lang = lang, .content = content }) catch |e| {
                self.gpa.free(lang);
                self.gpa.free(content);
                return e;
            };
        }

        return Paste{
            .id = paste_id,
            .created_at = created_at,
            .blobs = try blobs.toOwnedSlice(self.gpa),
            .gpa = self.gpa,
        };
    }

    pub fn exists(self: *Db, io: std.Io, id: []const u8) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var stmt: ?*c.sqlite3_stmt = null;
        defer finalize(stmt);

        const sql = "SELECT 1 FROM pastes WHERE id = ?";
        const rc = c.sqlite3_prepare_v2(self.conn, sql.ptr, sql.len, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqliteQueryFailed;

        if (c.sqlite3_bind_text(stmt.?, 1, id.ptr, @intCast(id.len), null) != c.SQLITE_OK)
            return error.SqliteQueryFailed;

        return switch (c.sqlite3_step(stmt.?)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.SqliteStepFailed,
        };
    }
};

pub fn generateId(gpa: std.mem.Allocator, io: std.Io) []u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var id: [5]u8 = undefined;
    var random: std.Random.IoSource = .{ .io = io };
    const rnd = random.interface();
    for (&id) |*ch| ch.* = alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)];
    return gpa.dupe(u8, &id) catch @panic("oom");
}

fn finalize(stmt: ?*c.sqlite3_stmt) void {
    if (stmt) |s| _ = c.sqlite3_finalize(s);
}

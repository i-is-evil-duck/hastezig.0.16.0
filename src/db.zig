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

    /// Try to insert a paste, returning `false` if `id` already exists. The
    /// existence check and insert happen atomically within one transaction, so
    /// callers can safely retry with a fresh id on collision. Caller guarantees
    /// `id` and all `blobs` fields stay alive until this returns.
    pub fn tryInsert(
        self: *Db,
        io: std.Io,
        id: []const u8,
        blobs: []const Blob,
        created_at: i64,
    ) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.exec("BEGIN;") catch return error.SqliteQueryFailed;
        errdefer self.exec("ROLLBACK;") catch {};

        var pstmt: ?*c.sqlite3_stmt = null;
        defer finalize(pstmt);
        const psql = "INSERT OR IGNORE INTO pastes (id, created_at) VALUES (?, ?)";
        if (c.sqlite3_prepare_v2(self.conn, psql.ptr, psql.len, &pstmt, null) != c.SQLITE_OK)
            return error.SqliteQueryFailed;
        if (c.sqlite3_bind_text(pstmt.?, 1, id.ptr, @intCast(id.len), null) != c.SQLITE_OK)
            return error.SqliteQueryFailed;
        if (c.sqlite3_bind_int64(pstmt.?, 2, created_at) != c.SQLITE_OK)
            return error.SqliteQueryFailed;
        if (c.sqlite3_step(pstmt.?) != c.SQLITE_DONE) return error.SqliteStepFailed;

        if (c.sqlite3_changes(self.conn) == 0) {
            // The id already exists; roll back and let the caller retry.
            self.exec("ROLLBACK;") catch return error.SqliteQueryFailed;
            return false;
        }

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
        return true;
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

    pub const PasteInfo = struct {
        id: []const u8,
        created_at: i64,
        lang: []const u8,
        blobs: usize,
        size: usize,
        preview: []const u8,
        gpa: std.mem.Allocator,

        pub fn deinit(self: *PasteInfo) void {
            self.gpa.free(self.id);
            self.gpa.free(self.lang);
            self.gpa.free(self.preview);
        }
    };

    pub fn listAll(self: *Db, io: std.Io) ![]PasteInfo {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var infos: std.ArrayList(PasteInfo) = .empty;
        errdefer {
            for (infos.items) |*p| p.deinit();
            infos.deinit(self.gpa);
        }

        var stmt: ?*c.sqlite3_stmt = null;
        defer finalize(stmt);
        const sql =
            \\SELECT p.id, p.created_at,
            \\  (SELECT COUNT(*) FROM blobs b WHERE b.paste_id = p.id),
            \\  (SELECT COALESCE(SUM(LENGTH(b.content)),0) FROM blobs b WHERE b.paste_id = p.id),
            \\  (SELECT b.lang FROM blobs b WHERE b.paste_id = p.id ORDER BY b.position ASC LIMIT 1),
            \\  (SELECT b.content FROM blobs b WHERE b.paste_id = p.id ORDER BY b.position ASC LIMIT 1)
            \\FROM pastes p ORDER BY p.created_at DESC LIMIT 500
        ;
        if (c.sqlite3_prepare_v2(self.conn, sql.ptr, sql.len, &stmt, null) != c.SQLITE_OK)
            return error.SqliteQueryFailed;

        while (true) {
            switch (c.sqlite3_step(stmt.?)) {
                c.SQLITE_ROW => {},
                c.SQLITE_DONE => break,
                else => return error.SqliteStepFailed,
            }
            const id_raw = c.sqlite3_column_text(stmt.?, 0) orelse return error.SqliteStepFailed;
            const id_len = c.sqlite3_column_bytes(stmt.?, 0);
            const created_at = c.sqlite3_column_int64(stmt.?, 1);
            const blob_count: usize = @intCast(c.sqlite3_column_int(stmt.?, 2));
            const size: usize = @intCast(c.sqlite3_column_int(stmt.?, 3));

            const lang_raw = c.sqlite3_column_text(stmt.?, 4);
            const lang_len: usize = if (lang_raw != null) @intCast(c.sqlite3_column_bytes(stmt.?, 4)) else 0;

            const content_raw = c.sqlite3_column_text(stmt.?, 5);
            const content_len: usize = if (content_raw != null) @intCast(c.sqlite3_column_bytes(stmt.?, 5)) else 0;

            const id = self.gpa.dupe(u8, id_raw[0..@intCast(id_len)]) catch |e| return e;
            errdefer self.gpa.free(id);

            const lang = if (lang_raw) |r| self.gpa.dupe(u8, r[0..lang_len]) catch |e| {
                self.gpa.free(id);
                return e;
            } else self.gpa.dupe(u8, "plaintext") catch |e| {
                self.gpa.free(id);
                return e;
            };
            errdefer self.gpa.free(lang);

            const preview_len = @min(content_len, 120);
            const preview = if (content_raw) |r| self.gpa.dupe(u8, r[0..preview_len]) catch |e| {
                self.gpa.free(id);
                self.gpa.free(lang);
                return e;
            } else &[_]u8{};
            errdefer self.gpa.free(preview);

            infos.append(self.gpa, .{
                .id = id,
                .created_at = created_at,
                .lang = lang,
                .blobs = blob_count,
                .size = size,
                .preview = preview,
                .gpa = self.gpa,
            }) catch |e| {
                self.gpa.free(id);
                self.gpa.free(lang);
                self.gpa.free(preview);
                return e;
            };
        }

        return infos.toOwnedSlice(self.gpa);
    }

    pub fn deleteByIds(self: *Db, io: std.Io, ids: []const []const u8) !usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.exec("BEGIN;") catch return error.SqliteQueryFailed;
        errdefer self.exec("ROLLBACK;") catch {};

        var total_deleted: usize = 0;

        for (ids) |id| {
            var bstmt: ?*c.sqlite3_stmt = null;
            defer finalize(bstmt);
            if (c.sqlite3_prepare_v2(self.conn, "DELETE FROM blobs WHERE paste_id = ?".ptr, "DELETE FROM blobs WHERE paste_id = ?".len, &bstmt, null) != c.SQLITE_OK)
                return error.SqliteQueryFailed;
            if (c.sqlite3_bind_text(bstmt.?, 1, id.ptr, @intCast(id.len), null) != c.SQLITE_OK)
                return error.SqliteQueryFailed;
            if (c.sqlite3_step(bstmt.?) != c.SQLITE_DONE) return error.SqliteStepFailed;

            var pstmt: ?*c.sqlite3_stmt = null;
            defer finalize(pstmt);
            if (c.sqlite3_prepare_v2(self.conn, "DELETE FROM pastes WHERE id = ?".ptr, "DELETE FROM pastes WHERE id = ?".len, &pstmt, null) != c.SQLITE_OK)
                return error.SqliteQueryFailed;
            if (c.sqlite3_bind_text(pstmt.?, 1, id.ptr, @intCast(id.len), null) != c.SQLITE_OK)
                return error.SqliteQueryFailed;
            if (c.sqlite3_step(pstmt.?) != c.SQLITE_DONE) return error.SqliteStepFailed;

            total_deleted += @intCast(c.sqlite3_changes(self.conn));
        }

        self.exec("COMMIT;") catch return error.SqliteQueryFailed;
        return total_deleted;
    }

    pub fn deleteOlderThan(self: *Db, io: std.Io, ts: i64) !usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.exec("BEGIN;") catch return error.SqliteQueryFailed;
        errdefer self.exec("ROLLBACK;") catch {};

        {
            var stmt: ?*c.sqlite3_stmt = null;
            defer finalize(stmt);
            if (c.sqlite3_prepare_v2(self.conn, "DELETE FROM blobs WHERE paste_id IN (SELECT id FROM pastes WHERE created_at < ?)".ptr, "DELETE FROM blobs WHERE paste_id IN (SELECT id FROM pastes WHERE created_at < ?)".len, &stmt, null) != c.SQLITE_OK)
                return error.SqliteQueryFailed;
            if (c.sqlite3_bind_int64(stmt.?, 1, ts) != c.SQLITE_OK)
                return error.SqliteQueryFailed;
            if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) return error.SqliteStepFailed;
        }

        {
            var stmt: ?*c.sqlite3_stmt = null;
            defer finalize(stmt);
            if (c.sqlite3_prepare_v2(self.conn, "DELETE FROM pastes WHERE created_at < ?".ptr, "DELETE FROM pastes WHERE created_at < ?".len, &stmt, null) != c.SQLITE_OK)
                return error.SqliteQueryFailed;
            if (c.sqlite3_bind_int64(stmt.?, 1, ts) != c.SQLITE_OK)
                return error.SqliteQueryFailed;
            if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) return error.SqliteStepFailed;
        }

        const total_deleted: usize = @intCast(c.sqlite3_changes(self.conn));
        self.exec("COMMIT;") catch return error.SqliteQueryFailed;
        return total_deleted;
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

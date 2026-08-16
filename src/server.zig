const std = @import("std");

const net = std.Io.net;
const http = std.http;
const db = @import("db.zig");

pub const max_paste_size: usize = 256 * 1024;
pub const max_blobs: usize = 20;

const json_content_type = "application/json";
const text_content_type = "text/plain; charset=utf-8";

const cors_headers = [_]http.Header{
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "content-type" },
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    db: db.Db,
    address: net.IpAddress,
    tcp_server: ?net.Server = null,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        db_path_z: [:0]const u8,
        address: net.IpAddress,
    ) !App {
        return .{
            .gpa = gpa,
            .io = io,
            .db = try db.Db.init(gpa, db_path_z),
            .address = address,
        };
    }

    pub fn deinit(self: *App) void {
        self.db.deinit();
    }

    pub fn listen(self: *App) !void {
        self.tcp_server = try self.address.listen(self.io, .{ .reuse_address = true });
    }

    pub fn serve(self: *App) Io.Cancelable!void {
        const tcp_server = &self.tcp_server.?;
        var group: std.Io.Group = .init;
        defer group.cancel(self.io);
        std.log.info("hastezig listening on http://{f}/", .{tcp_server.socket.address});
        while (true) {
            const stream = tcp_server.accept(self.io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| {
                    std.log.err("accept failed: {s}", .{@errorName(e)});
                    continue;
                },
            };
            group.concurrent(self.io, handleConnection, .{ self, stream }) catch |err| {
                std.log.err("spawn connection handler failed: {s}", .{@errorName(err)});
                var copy = stream;
                copy.close(self.io);
            };
        }
    }
};

const Io = std.Io;

fn handleConnection(self: *App, stream: net.Stream) Io.Cancelable!void {
    var copy = stream;
    defer copy.close(self.io);

    var send_buf: [16384]u8 = undefined;
    var recv_buf: [16384]u8 = undefined;
    var conn_reader = stream.reader(self.io, &recv_buf);
    var conn_writer = stream.writer(self.io, &send_buf);
    var http_server: http.Server = .init(&conn_reader.interface, &conn_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => |e| {
                std.log.debug("receiveHead: {s}", .{@errorName(e)});
                return;
            },
        };
        handleRequest(self, &request) catch |err| {
            std.log.err("request '{s}' failed: {s}", .{ request.head.target, @errorName(err) });
            request.respond("500 internal server error\n", .{
                .status = .internal_server_error,
                .keep_alive = false,
            }) catch {};
            return;
        };
    }
}

fn handleRequest(self: *App, request: *http.Server.Request) !void {
    const full_path = request.head.target;
    const query = std.mem.indexOfScalar(u8, full_path, '?');
    const path = if (query) |q| full_path[0..q] else full_path;

    if (request.head.method == .OPTIONS) return respondOptions(request);

    if (std.mem.eql(u8, path, "/api/paste")) {
        if (request.head.method != .POST) return methodNotAllowed(request);
        return apiCreate(self, request);
    }

    if (std.mem.startsWith(u8, path, "/api/paste/")) {
        const id = path["/api/paste/".len..];
        if (id.len == 0) return notFound(request);
        return apiGet(self, request, id);
    }

    if (std.mem.startsWith(u8, path, "/raw/")) {
        const id = path["/raw/".len..];
        if (id.len == 0) return notFound(request);
        return apiRaw(self, request, id);
    }

    return notFound(request);
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

fn apiCreate(self: *App, request: *http.Server.Request) !void {
    const body = readBody(self.gpa, request, max_paste_size) catch |err| switch (err) {
        error.PayloadTooLarge => return respondJsonError(self, request, .payload_too_large, "content too large"),
        else => return respondJsonError(self, request, .bad_request, "failed to read request body"),
    };
    defer self.gpa.free(body);

    if (body.len == 0)
        return respondJsonError(self, request, .bad_request, "missing body");

    const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch
        return respondJsonError(self, request, .bad_request, "invalid json");
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return respondJsonError(self, request, .bad_request, "expected a json object"),
    };

    var blob_refs: [max_blobs]db.Blob = undefined;
    var blob_count: usize = 0;
    var total_size: usize = 0;

    if (obj.get("blobs")) |blobs_value| {
        if (blobs_value != .array)
            return respondJsonError(self, request, .bad_request, "'blobs' must be an array");
        if (blobs_value.array.items.len == 0)
            return respondJsonError(self, request, .bad_request, "no blobs");
        if (blobs_value.array.items.len > max_blobs)
            return respondJsonError(self, request, .payload_too_large, "too many blobs");

        for (blobs_value.array.items) |item| {
            const blob_obj = switch (item) {
                .object => |o| o,
                else => return respondJsonError(self, request, .bad_request, "each blob must be an object"),
            };
            const content_value = blob_obj.get("content") orelse
                return respondJsonError(self, request, .bad_request, "missing 'content' field");
            if (content_value != .string)
                return respondJsonError(self, request, .bad_request, "'content' must be a string");

            var lang: []const u8 = "plaintext";
            if (blob_obj.get("lang")) |lang_value| {
                if (lang_value == .string) lang = lang_value.string;
            }

            blob_refs[blob_count] = .{ .lang = lang, .content = content_value.string };
            total_size += content_value.string.len;
            blob_count += 1;
        }
    } else {
        // Legacy single-blob payload: {content, lang}
        const content_value = obj.get("content") orelse
            return respondJsonError(self, request, .bad_request, "missing 'content' field");
        if (content_value != .string)
            return respondJsonError(self, request, .bad_request, "'content' must be a string");

        var lang: []const u8 = "plaintext";
        if (obj.get("lang")) |lang_value| {
            if (lang_value == .string) lang = lang_value.string;
        }

        blob_refs[0] = .{ .lang = lang, .content = content_value.string };
        blob_count = 1;
        total_size = content_value.string.len;
    }

    if (total_size > max_paste_size)
        return respondJsonError(self, request, .payload_too_large, "content too large");

    var attempts: usize = 0;
    while (attempts < 10) : (attempts += 1) {
        const id = db.generateId(self.gpa, self.io);
        defer self.gpa.free(id);

        if (try self.db.exists(self.io, id)) continue;
        try self.db.insert(self.io, id, blob_refs[0..blob_count], std.Io.Timestamp.now(self.io, .real).toSeconds());

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        try buf.appendSlice(self.gpa, "{\"id\":");
        try writeJsonString(self.gpa, &buf, id);
        try buf.appendSlice(self.gpa, ",\"url\":\"/");
        try buf.appendSlice(self.gpa, id);
        try buf.appendSlice(self.gpa, "\"}");

        return respondJson(request, .created, buf.items);
    }

    return respondJsonError(self, request, .internal_server_error, "could not allocate an id");
}

fn apiGet(self: *App, request: *http.Server.Request, id: []const u8) !void {
    var paste = try self.db.get(self.io, id) orelse
        return respondJsonError(self, request, .not_found, "paste not found");
    defer paste.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.gpa);
    try buf.appendSlice(self.gpa, "{\"id\":");
    try writeJsonString(self.gpa, &buf, paste.id);
    try buf.appendSlice(self.gpa, ",\"created_at\":");
    try buf.print(self.gpa, "{d}", .{paste.created_at});
    try buf.appendSlice(self.gpa, ",\"blobs\":[");
    for (paste.blobs, 0..) |blob, i| {
        if (i != 0) try buf.append(self.gpa, ',');
        try buf.appendSlice(self.gpa, "{\"lang\":");
        try writeJsonString(self.gpa, &buf, blob.lang);
        try buf.appendSlice(self.gpa, ",\"content\":");
        try writeJsonString(self.gpa, &buf, blob.content);
        try buf.append(self.gpa, '}');
    }
    try buf.appendSlice(self.gpa, "]}");

    return respondJson(request, .ok, buf.items);
}

fn apiRaw(self: *App, request: *http.Server.Request, id: []const u8) !void {
    var paste = try self.db.get(self.io, id) orelse
        return respondJsonError(self, request, .not_found, "paste not found");
    defer paste.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.gpa);
    for (paste.blobs, 0..) |blob, i| {
        if (i != 0) try out.append(self.gpa, '\n');
        try out.appendSlice(self.gpa, blob.content);
    }

    return respondPlain(request, out.items);
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

fn respondOptions(request: *http.Server.Request) !void {
    return request.respond("", .{ .status = .no_content, .extra_headers = &cors_headers });
}

fn respondJson(request: *http.Server.Request, status: http.Status, content: []const u8) !void {
    return request.respond(content, .{ .status = status, .extra_headers = &(
        [_]http.Header{.{ .name = "content-type", .value = json_content_type }} ++ cors_headers
    ) });
}

fn respondPlain(request: *http.Server.Request, content: []const u8) !void {
    return request.respond(content, .{ .extra_headers = &(
        [_]http.Header{.{ .name = "content-type", .value = text_content_type }} ++ cors_headers
    ) });
}

fn respondJsonError(
    self: *App,
    request: *http.Server.Request,
    status: http.Status,
    message: []const u8,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.gpa);
    try out.appendSlice(self.gpa, "{\"error\":");
    try writeJsonString(self.gpa, &out, message);
    try out.append(self.gpa, '}');
    return respondJson(request, status, out.items);
}

fn notFound(request: *http.Server.Request) !void {
    return request.respond("404 not found\n", .{ .status = .not_found, .keep_alive = false, .extra_headers = &cors_headers });
}

fn methodNotAllowed(request: *http.Server.Request) !void {
    return request.respond("405 method not allowed\n", .{ .status = .method_not_allowed, .extra_headers = &cors_headers });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn readBody(gpa: std.mem.Allocator, request: *http.Server.Request, max: usize) ![]u8 {
    var transfer_buf: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&transfer_buf);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        if (list.items.len + n > max) return error.PayloadTooLarge;
        try list.appendSlice(gpa, chunk[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

fn writeJsonString(gpa: std.mem.Allocator, list: *std.ArrayList(u8), s: []const u8) !void {
    try list.append(gpa, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try list.appendSlice(gpa, "\\\""),
            '\\' => try list.appendSlice(gpa, "\\\\"),
            '\n' => try list.appendSlice(gpa, "\\n"),
            '\r' => try list.appendSlice(gpa, "\\r"),
            '\t' => try list.appendSlice(gpa, "\\t"),
            else => if (ch < 0x20) {
                try list.print(gpa, "\\u{x:0>4}", .{ch});
            } else {
                try list.append(gpa, ch);
            },
        }
    }
    try list.append(gpa, '"');
}

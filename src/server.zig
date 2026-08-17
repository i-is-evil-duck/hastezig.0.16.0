const std = @import("std");

const net = std.Io.net;
const http = std.http;
const db = @import("db.zig");

const console_html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <title>hastezig console</title>
    \\  <style>
    \\    * { box-sizing: border-box; margin: 0; padding: 0; }
    \\    body { background: #11111b; color: #cdd6f4; font-family: Helvetica, Arial, sans-serif; font-size: 13px; line-height: 1.5; }
    \\    .wrap { max-width: 960px; margin: 30px auto; padding: 0 20px; }
    \\    h1 { font-size: 1.3rem; margin-bottom: 18px; color: #a6adc8; }
    \\    .login-box { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 20px; }
    \\    .login-box input { background: #313244; border: 1px solid #45475a; color: #cdd6f4; padding: 8px 12px; border-radius: 4px; font: inherit; }
    \\    button { background: #45475a; color: #cdd6f4; border: 1px solid #585b70; padding: 8px 18px; border-radius: 4px; cursor: pointer; font: inherit; }
    \\    button:hover { border-color: #89b4fa; color: #89b4fa; }
    \\    .danger { border-color: #f38ba8; color: #f38ba8; }
    \\    .danger:hover { background: #45475a; }
    \\    .row { display: flex; gap: 8px; align-items: center; margin-bottom: 14px; flex-wrap: wrap; }
    \\    table { width: 100%; border-collapse: collapse; margin-top: 10px; }
    \\    th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid #313244; }
    \\    th { color: #a6adc8; font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; }
    \\    td { font-family: monospace; font-size: 12px; }
    \\    .preview { max-width: 260px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #585b70; }
    \\    .empty { color: #585b70; margin-top: 20px; }
    \\    #login-form, #console { display: none; }
    \\    #console.active { display: block; }
    \\    #login-form.active { display: flex; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <div class="wrap">
    \\    <h1>hastezig console</h1>
    \\
    \\    <form class="login-box active" id="login-form" onsubmit="doLogin(event)">
    \\      <input id="in-user" placeholder="username" autocomplete="username">
    \\      <input id="in-pass" type="password" placeholder="password" autocomplete="current-password">
    \\      <button type="submit">Login</button>
    \\      <span id="login-err" style="color:#f38ba8;margin-left:8px;"></span>
    \\    </form>
    \\
    \\    <div id="console">
    \\      <div class="row">
    \\        <button onclick="loadPastes()">Refresh</button>
    \\        <button class="danger" onclick="pruneSelected()">Prune selected</button>
    \\        <span style="margin-left:auto;"></span>
    \\        <label style="color:#a6adc8;">Older than days:</label>
    \\        <input id="old-days" type="number" min="1" value="30" style="width:70px;background:#313244;border:1px solid #45475a;color:#cdd6f4;padding:6px 8px;border-radius:4px;font:inherit;">
    \\        <button class="danger" onclick="pruneOld()">Prune old</button>
    \\      </div>
    \\      <table>
    \\        <thead>
    \\          <tr>
    \\            <th style="width:30px;"><input type="checkbox" id="sel-all" onchange="toggleAll()"></th>
    \\            <th>ID</th>
    \\            <th>Created</th>
    \\            <th>Lang</th>
    \\            <th>Blobs</th>
    \\            <th>Size</th>
    \\            <th>Preview</th>
    \\          </tr>
    \\        </thead>
    \\        <tbody id="ptbody"></tbody>
    \\      </table>
    \\      <p class="empty" id="empty-msg"></p>
    \\    </div>
    \\  </div>
    \\
    \\  <script>
    \\    var TOKEN = '';
    \\
    \\    function doLogin(e) {
    \\      e.preventDefault();
    \\      var user = document.getElementById('in-user').value;
    \\      var pass = document.getElementById('in-pass').value;
    \\      document.getElementById('login-err').textContent = '';
    \\      fetch('/api/console/login', {
    \\        method: 'POST',
    \\        headers: { 'content-type': 'application/json' },
    \\        body: JSON.stringify({ user: user, pass: pass })
    \\      }).then(function(r) { return r.json(); }).then(function(d) {
    \\        if (d.token) {
    \\          TOKEN = d.token;
    \\          document.getElementById('login-form').classList.remove('active');
    \\          document.getElementById('console').classList.add('active');
    \\          loadPastes();
    \\        } else {
    \\          document.getElementById('login-err').textContent = d.error || 'Login failed';
    \\        }
    \\      }).catch(function() {
    \\        document.getElementById('login-err').textContent = 'Network error';
    \\      });
    \\    }
    \\
    \\    function loadPastes() {
    \\      document.getElementById('sel-all').checked = false;
    \\      fetch('/api/console/pastes', { headers: { 'Authorization': 'Bearer ' + TOKEN } })
    \\        .then(function(r) { return r.json(); }).then(function(d) {
    \\          if (d.error) { alert(d.error); return; }
    \\          var tbody = document.getElementById('ptbody');
    \\          tbody.innerHTML = '';
    \\          document.getElementById('empty-msg').textContent = d.pastes.length === 0 ? 'No pastes.' : '';
    \\          d.pastes.forEach(function(p) {
    \\            var tr = document.createElement('tr');
    \\            var dt = new Date(p.created_at * 1000);
    \\            var ts = dt.getFullYear() + '-' + String(dt.getMonth()+1).padStart(2,'0') + '-' + String(dt.getDate()).padStart(2,'0') + ' ' + String(dt.getHours()).padStart(2,'0') + ':' + String(dt.getMinutes()).padStart(2,'0');
    \\            var sizeStr = p.size < 1024 ? p.size + ' B' : (p.size / 1024).toFixed(1) + ' KB';
    \\            tr.innerHTML =
    \\              '<td><input type="checkbox" class="pid-cb" value="' + p.id + '"></td>' +
    \\              '<td><a href="/' + p.id + '" style="color:#89b4fa;">' + p.id + '</a></td>' +
    \\              '<td>' + ts + '</td>' +
    \\              '<td>' + p.lang + '</td>' +
    \\              '<td>' + p.blobs + '</td>' +
    \\              '<td>' + sizeStr + '</td>' +
    \\              '<td class="preview">' + p.preview.replace(/</g, '&lt;') + '</td>';
    \\            tbody.appendChild(tr);
    \\          });
    \\        }).catch(function() { alert('Failed to load pastes'); });
    \\    }
    \\
    \\    function toggleAll() {
    \\      var c = document.getElementById('sel-all').checked;
    \\      document.querySelectorAll('.pid-cb').forEach(function(cb) { cb.checked = c; });
    \\    }
    \\
    \\    function getSelected() {
    \\      var ids = [];
    \\      document.querySelectorAll('.pid-cb:checked').forEach(function(cb) { ids.push(cb.value); });
    \\      return ids;
    \\    }
    \\
    \\    function pruneSelected() {
    \\      var ids = getSelected();
    \\      if (ids.length === 0) { alert('No pastes selected.'); return; }
    \\      if (!confirm('Delete ' + ids.length + ' paste(s)?')) return;
    \\      fetch('/api/console/prune', {
    \\        method: 'POST',
    \\        headers: { 'content-type': 'application/json', 'Authorization': 'Bearer ' + TOKEN },
    \\        body: JSON.stringify({ ids: ids })
    \\      }).then(function(r) { return r.json(); }).then(function(d) {
    \\        alert('Deleted ' + d.deleted + ' paste(s).');
    \\        loadPastes();
    \\      }).catch(function() { alert('Prune failed'); });
    \\    }
    \\
    \\    function pruneOld() {
    \\      var days = parseInt(document.getElementById('old-days').value, 10);
    \\      if (!days || days < 1) { alert('Enter a valid number of days.'); return; }
    \\      if (!confirm('Delete all pastes older than ' + days + ' days?')) return;
    \\      var ts = Math.floor(Date.now() / 1000) - (days * 86400);
    \\      fetch('/api/console/prune', {
    \\        method: 'POST',
    \\        headers: { 'content-type': 'application/json', 'Authorization': 'Bearer ' + TOKEN },
    \\        body: JSON.stringify({ older_than: ts })
    \\      }).then(function(r) { return r.json(); }).then(function(d) {
    \\        alert('Deleted ' + d.deleted + ' paste(s).');
    \\        loadPastes();
    \\      }).catch(function() { alert('Prune failed'); });
    \\    }
    \\  </script>
    \\</body>
    \\</html>
;

pub const max_paste_size: usize = 256 * 1024;
pub const max_blobs: usize = 20;
pub const max_lang_len: usize = 64;
pub const max_sessions: usize = 32;

const json_content_type = "application/json";
const text_content_type = "text/plain; charset=utf-8";
const html_content_type = "text/html; charset=utf-8";

const cors_headers = [_]http.Header{
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "content-type, authorization" },
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    db: db.Db,
    address: net.IpAddress,
    tcp_server: ?net.Server = null,
    admin_user: []const u8,
    admin_pass: []const u8,
    sessions: [max_sessions][32]u8 = undefined,
    session_count: usize = 0,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        db_path_z: [:0]const u8,
        address: net.IpAddress,
        admin_user: []const u8,
        admin_pass: []const u8,
    ) !App {
        return .{
            .gpa = gpa,
            .io = io,
            .db = try db.Db.init(gpa, db_path_z),
            .address = address,
            .admin_user = admin_user,
            .admin_pass = admin_pass,
        };
    }

    pub fn deinit(self: *App) void {
        if (self.tcp_server) |*tcp_server| tcp_server.deinit(self.io);
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
        const close_connection = handleRequest(self, &request) catch |err| {
            std.log.err("request '{s}' failed: {s}", .{ request.head.target, @errorName(err) });
            request.respond("500 internal server error\n", .{
                .status = .internal_server_error,
                .keep_alive = false,
            }) catch {};
            return;
        };
        // Some responses negotiate a non-persistent connection (e.g. 404/405
        // or a client-sent "connection: close"); close it instead of waiting.
        if (close_connection or !request.head.keep_alive) return;
    }
}

/// Returns whether the response negotiated a non-persistent connection and the
/// connection should be closed.
fn handleRequest(self: *App, request: *http.Server.Request) !bool {
    const full_path = request.head.target;
    const query = std.mem.indexOfScalar(u8, full_path, '?');
    const path = if (query) |q| full_path[0..q] else full_path;

    if (request.head.method == .OPTIONS) return respondOptions(request);

    if (std.mem.eql(u8, path, "/api/paste")) {
        if (request.head.method != .POST) return methodNotAllowed(request, "POST");
        return apiCreate(self, request);
    }

    if (std.mem.eql(u8, path, "/console")) {
        if (request.head.method != .GET) return methodNotAllowed(request, "GET");
        return respondHtml(request, console_html);
    }

    if (std.mem.eql(u8, path, "/api/console/login")) {
        if (request.head.method != .POST) return methodNotAllowed(request, "POST");
        return apiConsoleLogin(self, request);
    }

    if (std.mem.eql(u8, path, "/api/console/pastes")) {
        if (request.head.method != .GET) return methodNotAllowed(request, "GET");
        return apiConsolePastes(self, request);
    }

    if (std.mem.eql(u8, path, "/api/console/prune")) {
        if (request.head.method != .POST) return methodNotAllowed(request, "POST");
        return apiConsolePrune(self, request);
    }

    if (std.mem.startsWith(u8, path, "/api/paste/")) {
        const id = path["/api/paste/".len..];
        if (id.len == 0) return notFound(request);
        if (request.head.method != .GET) return methodNotAllowed(request, "GET");
        return apiGet(self, request, id);
    }

    if (std.mem.startsWith(u8, path, "/raw/")) {
        const id = path["/raw/".len..];
        if (id.len == 0) return notFound(request);
        if (request.head.method != .GET) return methodNotAllowed(request, "GET");
        return apiRaw(self, request, id);
    }

    if (std.mem.startsWith(u8, path, "/api/")) {
        return respondJsonError(self, request, .not_found, "not found");
    }

    return notFound(request);
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

fn apiCreate(self: *App, request: *http.Server.Request) !bool {
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
            if (lang.len > max_lang_len) lang = lang[0..max_lang_len];

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
        if (lang.len > max_lang_len) lang = lang[0..max_lang_len];

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

        if (!try self.db.tryInsert(self.io, id, blob_refs[0..blob_count], std.Io.Timestamp.now(self.io, .real).toSeconds()))
            continue;

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

fn apiGet(self: *App, request: *http.Server.Request, id: []const u8) !bool {
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

fn apiRaw(self: *App, request: *http.Server.Request, id: []const u8) !bool {
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
// Admin Console
// ---------------------------------------------------------------------------

fn isAuthed(self: *App, request: *http.Server.Request) bool {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            const val = std.mem.trim(u8, h.value, " \t");
            if (std.mem.startsWith(u8, val, "Bearer ") and val.len > 7) {
                const token = val[7..];
                for (self.sessions[0..self.session_count]) |s| {
                    if (std.mem.eql(u8, &s, token)) return true;
                }
            }
        }
    }
    return false;
}

fn generateToken(self: *App) [32]u8 {
    var token: [32]u8 = undefined;
    const alphabet = "0123456789abcdef";
    var random: std.Random.IoSource = .{ .io = self.io };
    const rnd = random.interface();
    for (&token) |*ch| ch.* = alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)];
    return token;
}

fn apiConsoleLogin(self: *App, request: *http.Server.Request) !bool {
    const body = readBody(self.gpa, request, 4096) catch
        return respondJsonError(self, request, .bad_request, "failed to read body");
    defer self.gpa.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch
        return respondJsonError(self, request, .bad_request, "invalid json");
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return respondJsonError(self, request, .bad_request, "expected object"),
    };

    const user_val = obj.get("user") orelse return respondJsonError(self, request, .bad_request, "missing user");
    const pass_val = obj.get("pass") orelse return respondJsonError(self, request, .bad_request, "missing pass");
    if (user_val != .string or pass_val != .string)
        return respondJsonError(self, request, .bad_request, "user and pass must be strings");

    if (!std.mem.eql(u8, user_val.string, self.admin_user) or !std.mem.eql(u8, pass_val.string, self.admin_pass))
        return respondJsonError(self, request, .unauthorized, "invalid credentials");

    const token = generateToken(self);
    if (self.session_count < max_sessions) {
        self.sessions[self.session_count] = token;
        self.session_count += 1;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.gpa);
    try buf.appendSlice(self.gpa, "{\"token\":\"");
    try buf.appendSlice(self.gpa, &token);
    try buf.appendSlice(self.gpa, "\"}");
    return respondJson(request, .ok, buf.items);
}

fn apiConsolePastes(self: *App, request: *http.Server.Request) !bool {
    if (!isAuthed(self, request))
        return respondJsonError(self, request, .unauthorized, "unauthorized");

    const infos = try self.db.listAll(self.io);
    defer {
        for (infos) |*p| p.deinit();
        self.gpa.free(infos);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.gpa);
    try buf.appendSlice(self.gpa, "{\"pastes\":[");

    for (infos, 0..) |info, i| {
        if (i != 0) try buf.append(self.gpa, ',');
        try buf.appendSlice(self.gpa, "{\"id\":");
        try writeJsonString(self.gpa, &buf, info.id);
        try buf.appendSlice(self.gpa, ",\"created_at\":");
        try buf.print(self.gpa, "{d}", .{info.created_at});
        try buf.appendSlice(self.gpa, ",\"lang\":");
        try writeJsonString(self.gpa, &buf, info.lang);
        try buf.appendSlice(self.gpa, ",\"blobs\":");
        try buf.print(self.gpa, "{d}", .{info.blobs});
        try buf.appendSlice(self.gpa, ",\"size\":");
        try buf.print(self.gpa, "{d}", .{info.size});
        try buf.appendSlice(self.gpa, ",\"preview\":");
        try writeJsonString(self.gpa, &buf, info.preview);
        try buf.append(self.gpa, '}');
    }
    try buf.appendSlice(self.gpa, "]}");
    return respondJson(request, .ok, buf.items);
}

fn apiConsolePrune(self: *App, request: *http.Server.Request) !bool {
    if (!isAuthed(self, request))
        return respondJsonError(self, request, .unauthorized, "unauthorized");

    const body = readBody(self.gpa, request, 65536) catch
        return respondJsonError(self, request, .bad_request, "failed to read body");
    defer self.gpa.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch
        return respondJsonError(self, request, .bad_request, "invalid json");
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return respondJsonError(self, request, .bad_request, "expected object"),
    };

    var total_deleted: usize = 0;

    if (obj.get("ids")) |ids_val| {
        if (ids_val != .array)
            return respondJsonError(self, request, .bad_request, "'ids' must be an array");
        if (ids_val.array.items.len == 0)
            return respondJsonError(self, request, .bad_request, "no ids provided");
        if (ids_val.array.items.len > 500)
            return respondJsonError(self, request, .payload_too_large, "too many ids");

        var id_bufs: [500][]const u8 = undefined;
        for (ids_val.array.items, 0..) |item, i| {
            if (item != .string)
                return respondJsonError(self, request, .bad_request, "each id must be a string");
            id_bufs[i] = item.string;
        }
        total_deleted += try self.db.deleteByIds(self.io, id_bufs[0..ids_val.array.items.len]);
    }

    if (obj.get("older_than")) |ot_val| {
        if (ot_val != .integer)
            return respondJsonError(self, request, .bad_request, "'older_than' must be an integer (unix seconds)");
        total_deleted += try self.db.deleteOlderThan(self.io, ot_val.integer);
    }

    if (total_deleted == 0 and obj.get("ids") == null and obj.get("older_than") == null)
        return respondJsonError(self, request, .bad_request, "provide 'ids' array and/or 'older_than' timestamp");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.gpa);
    try buf.appendSlice(self.gpa, "{\"deleted\":");
    try buf.print(self.gpa, "{d}", .{total_deleted});
    try buf.append(self.gpa, '}');
    return respondJson(request, .ok, buf.items);
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

fn respondOptions(request: *http.Server.Request) !bool {
    try request.respond("", .{ .status = .no_content, .extra_headers = &cors_headers });
    return false;
}

fn respondJson(request: *http.Server.Request, status: http.Status, content: []const u8) !bool {
    try request.respond(content, .{ .status = status, .extra_headers = &(
        [_]http.Header{.{ .name = "content-type", .value = json_content_type }} ++ cors_headers
    ) });
    return false;
}

fn respondPlain(request: *http.Server.Request, content: []const u8) !bool {
    try request.respond(content, .{ .extra_headers = &(
        [_]http.Header{.{ .name = "content-type", .value = text_content_type }} ++ cors_headers
    ) });
    return false;
}

fn respondHtml(request: *http.Server.Request, content: []const u8) !bool {
    try request.respond(content, .{ .extra_headers = &(
        [_]http.Header{.{ .name = "content-type", .value = html_content_type }} ++ cors_headers
    ) });
    return false;
}

fn respondJsonError(
    self: *App,
    request: *http.Server.Request,
    status: http.Status,
    message: []const u8,
) !bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.gpa);
    try out.appendSlice(self.gpa, "{\"error\":");
    try writeJsonString(self.gpa, &out, message);
    try out.append(self.gpa, '}');
    return respondJson(request, status, out.items);
}

fn notFound(request: *http.Server.Request) !bool {
    try request.respond("404 not found\n", .{ .status = .not_found, .keep_alive = false, .extra_headers = &cors_headers });
    return true;
}

fn methodNotAllowed(request: *http.Server.Request, allow: []const u8) !bool {
    const headers = [_]http.Header{
        .{ .name = "allow", .value = allow },
        .{ .name = "access-control-allow-origin", .value = "*" },
        .{ .name = "access-control-allow-methods", .value = "GET, POST, OPTIONS" },
        .{ .name = "access-control-allow-headers", .value = "content-type" },
    };
    try request.respond("405 method not allowed\n", .{ .status = .method_not_allowed, .extra_headers = &headers });
    return true;
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
        if (list.items.len + n > max) {
            // Drain the rest of the body so the connection state is left clean
            // and can be reused for the next request.
            _ = reader.discardRemaining() catch return error.PayloadTooLarge;
            return error.PayloadTooLarge;
        }
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

const std = @import("std");

const net = std.Io.net;
const server = @import("server.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const host: []const u8 = if (args.len > 1) args[1] else "0.0.0.0";
    const port: u16 = if (args.len > 2) blk: {
        break :blk std.fmt.parseInt(u16, args[2], 10) catch 960;
    } else 960;
    const db_path: []const u8 = if (args.len > 3) args[3] else "hastezig.db";

    const environ = init.environ_map;
    const admin_user = environ.get("ADMIN_USER") orelse "admin";
    const admin_pass = environ.get("ADMIN_PASS") orelse "admin";

    if (std.mem.eql(u8, admin_user, "admin") and std.mem.eql(u8, admin_pass, "admin"))
        std.log.warn("console using default credentials (ADMIN_USER=admin ADMIN_PASS=admin)", .{});

    const db_path_z = try gpa.dupeZ(u8, db_path);
    defer gpa.free(db_path_z);

    const address = try net.IpAddress.parse(host, port);

    var app = try server.App.init(gpa, io, db_path_z, address, admin_user, admin_pass);
    defer app.deinit();

    try app.listen();
    try app.serve();
}

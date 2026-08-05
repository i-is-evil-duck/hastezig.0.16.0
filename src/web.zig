const std = @import("std");

pub const index_html = @embedFile("web/index.html");
pub const view_html = @embedFile("web/view.html");
pub const app_js = @embedFile("web/app.js");
pub const style_css = @embedFile("web/style.css");
pub const highlight_js = @embedFile("web/vendor/highlight.min.js");
pub const zig_js = @embedFile("web/vendor/zig.min.js");

pub const StaticFile = struct {
    path: []const u8,
    content_type: []const u8,
    data: []const u8,
};

pub const static_files = [_]StaticFile{
    .{ .path = "app.js", .content_type = "text/javascript", .data = app_js },
    .{ .path = "style.css", .content_type = "text/css", .data = style_css },
    .{ .path = "vendor/highlight.min.js", .content_type = "text/javascript", .data = highlight_js },
    .{ .path = "vendor/zig.min.js", .content_type = "text/javascript", .data = zig_js },
};

pub fn findStatic(path: []const u8) ?*const StaticFile {
    for (&static_files) |*file| {
        if (std.mem.eql(u8, file.path, path)) return file;
    }
    return null;
}

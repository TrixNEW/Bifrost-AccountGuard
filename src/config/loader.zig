const std = @import("std");
const bifrost = @import("bifrost_plugin");
const Config = @import("config.zig").Config;
const parser = @import("parser.zig");
const library = @import("../platform/library.zig");

const config_name = "AccountGuard.toml";
const max_file_bytes = 1 << 20;

pub fn load(host: bifrost.Host, gpa: std.mem.Allocator) !Config {
    const io = std.Io.Threaded.global_single_threaded.io();
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory = library.directory(&directory_buffer) orelse {
        host.log(.err, "can't tell where the plugin is installed, so can't find {s}", .{config_name});
        return error.Failed;
    };
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}{c}{s}", .{ directory, std.fs.path.sep, config_name }) catch return error.Failed;

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            host.log(.info, "no {s} beside the plugin, using the defaults", .{config_name});
            return parseConfig(host, gpa, path, "");
        },
        else => {
            host.log(.err, "can't read {s}: {t}", .{ path, err });
            return error.Failed;
        },
    };
    defer gpa.free(source);
    return parseConfig(host, gpa, path, source);
}

fn parseConfig(host: bifrost.Host, gpa: std.mem.Allocator, path: []const u8, source: []const u8) !Config {
    var diagnostic: parser.Diagnostic = .{};
    return parser.parse(gpa, source, &diagnostic) catch |err| {
        if (err == error.InvalidConfig) host.log(.err, "{s}: {s}", .{ path, diagnostic.text });
        return err;
    };
}

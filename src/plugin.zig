const std = @import("std");
const bifrost = @import("bifrost_plugin");
const config_mod = @import("config.zig");
const library = @import("library.zig");
const Guard = @import("guard.zig").Guard;

pub const manifest = @embedFile("plugin.toml");
pub const capabilities: bifrost.abi.Capabilities = .{ .events = true, .admission = true };

comptime {
    bifrost.exportPlugin(@This());
}

const gpa = std.heap.smp_allocator;
const config_name = "AccountGuard.toml";
const io = std.Io.Threaded.global_single_threaded.io();

// callbacks carry no user pointer, and there's one instance per process
var guard: Guard = undefined;

pub fn init(host: bifrost.Host) !void {
    if (!Guard.supported(host)) {
        host.log(.err, "needs Bifrost API revision 9 or later, which provides player_account", .{});
        return error.Unsupported;
    }
    const config = try load(host);
    guard = .{ .host = host, .config = config };
    try host.on(.player_authenticated, onAuthenticated);
}

pub fn deinit() void {
    guard.summary();
    guard.config.deinit(gpa);
}

fn onAuthenticated(event: *const bifrost.Event, decision: ?*bifrost.TransferDecision) void {
    guard.admit(event, decision, std.Io.Clock.real.now(io).toSeconds());
}

fn load(host: bifrost.Host) !config_mod.Config {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = library.directory(&directory_buffer) orelse {
        host.log(.err, "can't tell where the plugin is installed, so can't find {s}", .{config_name});
        return error.Failed;
    };
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}{c}{s}", .{ directory, std.fs.path.sep, config_name }) catch return error.Failed;

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(config_mod.max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            host.log(.info, "no {s} beside the plugin, using the defaults", .{config_name});
            return parseConfig(host, path, "");
        },
        else => {
            host.log(.err, "can't read {s}: {t}", .{ path, err });
            return error.Failed;
        },
    };
    defer gpa.free(source);
    return parseConfig(host, path, source);
}

fn parseConfig(host: bifrost.Host, path: []const u8, source: []const u8) !config_mod.Config {
    var diagnostic: config_mod.Diagnostic = .{};
    return config_mod.parse(gpa, source, &diagnostic) catch |err| {
        if (err == error.InvalidConfig) host.log(.err, "{s}: {s}", .{ path, diagnostic.text });
        return err;
    };
}

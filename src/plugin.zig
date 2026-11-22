const std = @import("std");
const bifrost = @import("bifrost_plugin");
const admission = @import("admission.zig");
const Config = @import("utils/config.zig").Config;
const abi = bifrost.abi;

pub const capabilities: abi.Capabilities = .{ .events = true, .admission = true };

comptime {
    @export(&entry, .{ .name = abi.entrypoint });
    @export(bifrost.manifest(@embedFile("plugin.toml")), .{ .name = abi.manifest_entrypoint });
}

const gpa = std.heap.smp_allocator;
const io = std.Io.Threaded.global_single_threaded.io();
var host: bifrost.Host = undefined;
var config: Config = undefined;

fn entry(raw: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    const status = bifrost.entry(@This())(raw, plugin);
    if (status == .ok and config.min_age_s == 0) plugin.capabilities = .{};
    return status;
}

pub fn init(server: bifrost.Host) !void {
    if (!server.raw.has(.player_account) or !server.raw.has(.disconnect)) {
        server.log(.err, "requires Bifrost API revision 9 or later", .{});
        return error.Unsupported;
    }
    config = try Config.load(server, gpa);
    errdefer config.deinit(gpa);
    host = server;
    if (config.min_age_s != 0) try host.on(.player_authenticated, onAuthenticated);
}

pub fn deinit() void {
    config.deinit(gpa);
}

fn onAuthenticated(event: *const bifrost.Event, decision: ?*bifrost.TransferDecision) void {
    admission.admit(host, &config, event.player, decision, std.Io.Clock.real.now(io).toSeconds());
}

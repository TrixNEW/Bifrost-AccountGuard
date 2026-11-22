const std = @import("std");
const bifrost = @import("bifrost_plugin");
const admission = @import("admission.zig");
const loader = @import("config/loader.zig");

const manifest = @embedFile("plugin.toml");
pub const capabilities: bifrost.abi.Capabilities = .{ .events = true, .admission = true };

comptime {
    @export(&entry, .{ .name = bifrost.abi.entrypoint });
    @export(bifrost.manifest(manifest), .{ .name = bifrost.abi.manifest_entrypoint });
}

const gpa = std.heap.smp_allocator;
const io = std.Io.Threaded.global_single_threaded.io();
var guard: admission.Guard = undefined;

fn entry(host: *const bifrost.abi.Host, plugin: *bifrost.abi.Plugin) callconv(.c) bifrost.abi.Status {
    const status = bifrost.entry(@This())(host, plugin);
    if (status == .ok and guard.config.min_age_s == 0) plugin.capabilities = .{};
    return status;
}

pub fn init(host: bifrost.Host) !void {
    if (!admission.supported(host)) {
        host.log(.err, "requires Bifrost API revision 9 or later", .{});
        return error.Unsupported;
    }
    const config = try loader.load(host, gpa);
    errdefer config.deinit(gpa);
    if (config.min_age_s != 0) try host.on(.player_authenticated, onAuthenticated);
    guard = .{ .host = host, .config = config };
}

pub fn deinit() void {
    guard.config.deinit(gpa);
}

fn onAuthenticated(event: *const bifrost.Event, decision: ?*bifrost.TransferDecision) void {
    guard.admit(event.player, decision, std.Io.Clock.real.now(io).toSeconds());
}

const std = @import("std");
const config = @import("config.zig");

test {
    _ = config;
    _ = @import("policy.zig");
    _ = @import("guard.zig");
}

test "the shipped example stays loadable and means what the docs say" {
    var diagnostic: config.Diagnostic = .{};
    var example = try config.parse(std.testing.allocator, @embedFile("example_config"), &diagnostic);
    defer example.deinit(std.testing.allocator);
    try std.testing.expectEqual(30 * config.seconds_per_day, example.min_age_s);
    try std.testing.expectEqual(config.Missing.deny, example.missing);
    try std.testing.expectEqual(@as(usize, 0), example.exempt_xuids.len);
    try std.testing.expect(std.mem.indexOf(u8, example.kick, "30 days") != null);
}

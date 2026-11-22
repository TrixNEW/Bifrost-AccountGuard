const std = @import("std");
const testing = std.testing;
const Config = @import("../src/utils/config.zig").Config;
const day = std.time.s_per_day;

fn parse(gpa: std.mem.Allocator, source: []const u8) !Config {
    var line: usize = undefined;
    return Config.parse(gpa, source, &line);
}

test "an empty file and the shipped example use the defaults" {
    for ([_][]const u8{ "", @embedFile("example_config") }) |source| {
        const config = try parse(testing.allocator, source);
        defer config.deinit(testing.allocator);
        try testing.expectEqual(30 * day, config.min_age_s);
        try testing.expectEqual(.deny, config.missing);
        try testing.expectEqual(0, config.exempt_xuids.len);
        try testing.expect(std.mem.indexOf(u8, config.kick, "30 days") != null);
    }
}

test "every setting is read with CRLF, comments, escapes and a trailing comma" {
    const config = try parse(testing.allocator, "kick_message = \"Wait {days} days, \\\"friend\\\" # {days}\"\r\n" ++
        "min_age_days = 14# comment\r\nmissing_date = \"allow\"\r\nexempt_xuids = [\"9\", \"2\", \"2\",]\r\n");
    defer config.deinit(testing.allocator);
    try testing.expectEqual(14 * day, config.min_age_s);
    try testing.expectEqual(.allow, config.missing);
    try testing.expectEqualStrings("Wait 14 days, \"friend\" # {days}", config.kick);
    try testing.expectEqualSlices(u64, &.{ 2, 9 }, config.exempt_xuids);
}

test "invalid settings fail closed" {
    const long: [513]u8 = @splat('x');
    for ([_][]const u8{
        "min_age = 3",
        "min_age_days = 30\nmin_age_days = 0",
        "min_age_days = 30 min_age_days = 0",
        "min_age_days = 0 [unexpected]",
        "min_age_days = -1",
        "min_age_days = 0x0",
        "min_age_days = 36501",
        "min_age_days = \"30\"",
        "min_age_days = 3.5",
        "min_age_days",
        "kick_message = \"\"",
        "kick_message = \"open",
        "kick_message = \"bad \\n escape\"",
        "kick_message = \"a\" extra",
        "kick_message = \"\xff\"",
        "kick_message = \"" ++ long ++ "\"",
        "missing_date = \"maybe\"",
        "missing_date = allow",
        "exempt_xuids = \"1\"",
        "exempt_xuids = [1]",
        "exempt_xuids = [\"Steve\"]",
        "exempt_xuids = [\"0\"]",
        "exempt_xuids = [\"+5\"]",
        "exempt_xuids = [\"1_2\"]",
        "exempt_xuids = [\"18446744073709551616\"]",
        "exempt_xuids = [\"1\" \"2\"]",
        "exempt_xuids = [\"1\",",
        "exempt_xuids = [[\"1\"]]",
        "exempt_xuids = { value = \"1\" }",
        "exempt_xuids = []\n[exempt_xuids.child]",
    }) |source| {
        if (parse(testing.allocator, source)) |config| {
            defer config.deinit(testing.allocator);
            std.debug.print("accepted invalid config: {s}\n", .{source});
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expect(err != error.OutOfMemory);
        }
    }
}

test "allocation failures never leak" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const config = try parse(gpa, "exempt_xuids = [\"2\", \"2\"]\nkick_message = \"Wait {days}\"\nmin_age_days = 9");
            config.deinit(gpa);
        }
    }.run, .{});
}

test "the exemption limit allows a trailing comma and rejects larger lists before allocating" {
    const prefix = "exempt_xuids = [";
    const item = "\"1\",";
    const limit = 65536;
    const source = try testing.allocator.alloc(u8, prefix.len + (limit + 1) * item.len + 1);
    defer testing.allocator.free(source);
    @memcpy(source[0..prefix.len], prefix);
    var offset: usize = prefix.len;
    for (0..limit + 1) |_| {
        @memcpy(source[offset..][0..item.len], item);
        offset += item.len;
    }
    source[offset] = ']';
    var no_memory = std.heap.FixedBufferAllocator.init(&.{});
    try testing.expectError(error.InvalidExemptXuids, parse(no_memory.allocator(), source));

    const end = offset - item.len;
    source[end] = ']';
    const config = try parse(testing.allocator, source[0 .. end + 1]);
    defer config.deinit(testing.allocator);
    try testing.expectEqualSlices(u64, &.{1}, config.exempt_xuids);
}

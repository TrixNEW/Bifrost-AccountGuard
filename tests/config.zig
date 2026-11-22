const std = @import("std");
const settings = @import("../src/config/config.zig");
const parser = @import("../src/config/parser.zig");
const Config = settings.Config;
const Missing = settings.Missing;
const Diagnostic = parser.Diagnostic;
const parse = parser.parse;
const max_kick_bytes = parser.max_kick_bytes;
const seconds_per_day = std.time.s_per_day;
const Allocator = std.mem.Allocator;

fn parseOk(source: []const u8) !Config {
    var diagnostic: Diagnostic = .{};
    return parse(std.testing.allocator, source, &diagnostic);
}

test "an empty file means the defaults" {
    const config = try parseOk("");
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(30 * seconds_per_day, config.min_age_s);
    try std.testing.expectEqual(Missing.deny, config.missing);
    try std.testing.expectEqual(@as(usize, 0), config.exempt_xuids.len);
    try std.testing.expect(std.mem.indexOf(u8, config.kick, "30 days") != null);
}

test "every setting is read, with comments, escapes and sorted unique XUIDs" {
    const config = try parseOk(
        \\# comment
        \\min_age_days = 14 # trailing
        \\kick_message = "Wait {days} days, \"friend\" # not a comment"
        \\missing_date = "allow"
        \\exempt_xuids = [ "2535400000000002", "2535400000000001", "2535400000000001" ]
        \\
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(14 * seconds_per_day, config.min_age_s);
    try std.testing.expectEqual(Missing.allow, config.missing);
    try std.testing.expectEqualStrings("Wait 14 days, \"friend\" # not a comment", config.kick);
    try std.testing.expectEqualSlices(u64, &.{ 2535400000000001, 2535400000000002 }, config.exempt_xuids);
    try std.testing.expect(config.exempt(2535400000000001) and config.exempt(2535400000000002));
    try std.testing.expect(!config.exempt(3) and !config.exempt(0));
}

test "windows line endings and a trailing comma are fine" {
    const config = try parseOk("min_age_days = 7\r\nexempt_xuids = [\"5\",]\r\n");
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(7 * seconds_per_day, config.min_age_s);
    try std.testing.expectEqualSlices(u64, &.{5}, config.exempt_xuids);
}

test "anything unknown, repeated or out of range is refused" {
    const bad = [_][]const u8{
        "min_age = 3\n",
        "min_age_days = 30\nmin_age_days = 30\n",
        "min_age_days = -1\n",
        "min_age_days = 36501\n",
        "min_age_days = \"30\"\n",
        "min_age_days = 3.5\n",
        "min_age_days\n",
        "kick_message = \"\"\n",
        "kick_message = Welcome\n",
        "kick_message = \"open\n",
        "kick_message = \"a\" extra\n",
        "kick_message = \"bad \\n escape\"\n",
        "missing_date = \"maybe\"\n",
        "missing_date = allow\n",
        "exempt_xuids = \"2535400000000001\"\n",
        "exempt_xuids = [2535400000000001]\n",
        "exempt_xuids = [\"Steve\"]\n",
        "exempt_xuids = [\"0\"]\n",
        "exempt_xuids = [\"-5\"]\n",
        "exempt_xuids = [\"123456789012345678901\"]\n",
        "exempt_xuids = [\"1\" \"2\"]\n",
        "exempt_xuids = [\"1\",\n",
    };
    for (bad) |source| try std.testing.expectError(error.InvalidConfig, parseOk(source));
}

test "the kick message length is bounded" {
    var body: [max_kick_bytes + 1]u8 = undefined;
    @memset(&body, 'x');
    var buffer: [max_kick_bytes + 32]u8 = undefined;
    const fits = try std.fmt.bufPrint(&buffer, "kick_message = \"{s}\"\n", .{body[0..max_kick_bytes]});
    const config = try parseOk(fits);
    config.deinit(std.testing.allocator);
    const over = try std.fmt.bufPrint(&buffer, "kick_message = \"{s}\"\n", .{&body});
    try std.testing.expectError(error.InvalidConfig, parseOk(over));
}

test "a refusal says which line is wrong" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "min_age_days = 3\nmissing_date = \"maybe\"\n", &diagnostic));
    try std.testing.expectEqualStrings("line 2: missing_date must be \"deny\" or \"allow\"", diagnostic.text);
}

test "allocation failures never leak" {
    const source = "min_age_days = 9\nkick_message = \"Wait {days}\"\nexempt_xuids = [\"2\", \"1\"]\n";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: Allocator, text: []const u8) !void {
            var diagnostic: Diagnostic = .{};
            const config = try parse(gpa, text, &diagnostic);
            config.deinit(gpa);
        }
    }.run, .{source});
}
test "the shipped example stays loadable and means what the docs say" {
    var diagnostic: Diagnostic = .{};
    const example = try parse(std.testing.allocator, @embedFile("example_config"), &diagnostic);
    defer example.deinit(std.testing.allocator);
    try std.testing.expectEqual(30 * seconds_per_day, example.min_age_s);
    try std.testing.expectEqual(Missing.deny, example.missing);
    try std.testing.expectEqual(@as(usize, 0), example.exempt_xuids.len);
    try std.testing.expect(std.mem.indexOf(u8, example.kick, "30 days") != null);
}

test "invalid UTF-8 in a kick message fails at load" {
    try std.testing.expectError(error.InvalidConfig, parseOk("kick_message = \"\xff\""));
}

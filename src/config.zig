const std = @import("std");

const Allocator = std.mem.Allocator;

pub const seconds_per_day: i64 = std.time.s_per_day;
pub const max_min_age_days = 36500;
pub const max_kick_bytes = 512;
pub const max_exempt = 65536;
pub const max_file_bytes = 1 << 20;
pub const default_kick = "Your account is too new to play here. Please come back when it is {days} days old.";

pub const Missing = enum { deny, allow };

const Key = enum { min_age_days, kick_message, missing_date, exempt_xuids };

pub const Config = struct {
    min_age_s: i64,
    missing: Missing,
    // sorted, no duplicates
    exempt_xuids: []const u64,
    // {days} already filled in
    kick: []const u8,

    pub fn deinit(self: *Config, gpa: Allocator) void {
        gpa.free(self.exempt_xuids);
        gpa.free(self.kick);
        self.* = undefined;
    }

    pub fn exempt(self: *const Config, xuid: u64) bool {
        return xuid != 0 and std.sort.binarySearch(u64, self.exempt_xuids, xuid, order) != null;
    }

    fn order(xuid: u64, item: u64) std.math.Order {
        return std.math.order(xuid, item);
    }
};

pub const Diagnostic = struct {
    buffer: [192]u8 = undefined,
    text: []const u8 = "",

    fn fail(self: *Diagnostic, line: usize, comptime format: []const u8, args: anytype) error{InvalidConfig} {
        self.text = std.fmt.bufPrint(&self.buffer, "line {d}: " ++ format, .{line} ++ args) catch "invalid setting";
        return error.InvalidConfig;
    }
};

// same rule Bifrost uses for operators
pub fn parseXuid(text: []const u8) ?u64 {
    if (text.len == 0 or text.len > 20) return null;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    const xuid = std.fmt.parseInt(u64, text, 10) catch return null;
    return if (xuid == 0) null else xuid;
}

// unknown keys and bad values fail the load, so a typo can't loosen the check
pub fn parse(gpa: Allocator, source: []const u8, diagnostic: *Diagnostic) (error{ InvalidConfig, OutOfMemory })!Config {
    var days: i64 = 30;
    var missing: Missing = .deny;
    var template: []const u8 = default_kick;
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(gpa);
    var item: std.ArrayList(u8) = .empty;
    defer item.deinit(gpa);
    var exempt: std.ArrayList(u64) = .empty;
    defer exempt.deinit(gpa);
    var seen: std.EnumSet(Key) = .empty;

    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        line_number += 1;
        const line = trim(stripComment(raw));
        if (line.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return diagnostic.fail(line_number, "expected key = value", .{});
        const name = trim(line[0..equals]);
        const value = trim(line[equals + 1 ..]);
        const key = std.meta.stringToEnum(Key, name) orelse return diagnostic.fail(line_number, "unknown key \"{s}\"", .{name});
        if (seen.contains(key)) return diagnostic.fail(line_number, "\"{s}\" is set twice", .{name});
        seen.insert(key);

        switch (key) {
            .min_age_days => {
                days = std.fmt.parseInt(i64, value, 10) catch return diagnostic.fail(line_number, "min_age_days must be a whole number", .{});
                if (days < 0 or days > max_min_age_days) return diagnostic.fail(line_number, "min_age_days must be 0 to {d}", .{max_min_age_days});
            },
            .kick_message => {
                const rest = readString(gpa, &message, value) catch |err| return stringFailure(diagnostic, line_number, err);
                if (rest.len != 0) return diagnostic.fail(line_number, "unexpected text after the string", .{});
                if (message.items.len == 0 or message.items.len > max_kick_bytes) return diagnostic.fail(line_number, "kick_message must be 1 to {d} bytes", .{max_kick_bytes});
                template = message.items;
            },
            .missing_date => {
                const rest = readString(gpa, &item, value) catch |err| return stringFailure(diagnostic, line_number, err);
                if (rest.len != 0) return diagnostic.fail(line_number, "unexpected text after the string", .{});
                missing = std.meta.stringToEnum(Missing, item.items) orelse return diagnostic.fail(line_number, "missing_date must be \"deny\" or \"allow\"", .{});
            },
            .exempt_xuids => {
                if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return diagnostic.fail(line_number, "expected a list of strings on one line", .{});
                var rest = trim(value[1 .. value.len - 1]);
                while (rest.len != 0) {
                    rest = readString(gpa, &item, rest) catch |err| return stringFailure(diagnostic, line_number, err);
                    const xuid = parseXuid(item.items) orelse return diagnostic.fail(line_number, "\"{s}\" is not a XUID; list digits only, never names", .{item.items});
                    if (exempt.items.len == max_exempt) return diagnostic.fail(line_number, "at most {d} exempt XUIDs", .{max_exempt});
                    try exempt.append(gpa, xuid);
                    rest = trim(rest);
                    if (rest.len == 0) break;
                    if (rest[0] != ',') return diagnostic.fail(line_number, "expected a comma between list items", .{});
                    rest = trim(rest[1..]);
                }
            },
        }
    }

    std.mem.sort(u64, exempt.items, {}, std.sort.asc(u64));
    var unique: usize = 0;
    for (exempt.items) |xuid| {
        if (unique != 0 and exempt.items[unique - 1] == xuid) continue;
        exempt.items[unique] = xuid;
        unique += 1;
    }
    const xuids = try gpa.dupe(u64, exempt.items[0..unique]);
    errdefer gpa.free(xuids);
    const kick = if (std.mem.indexOf(u8, template, "{days}")) |at|
        try std.fmt.allocPrint(gpa, "{s}{d}{s}", .{ template[0..at], days, template[at + "{days}".len ..] })
    else
        try gpa.dupe(u8, template);
    return .{ .min_age_s = days * seconds_per_day, .missing = missing, .exempt_xuids = xuids, .kick = kick };
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r");
}

fn stripComment(line: []const u8) []const u8 {
    var quoted = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '\\' => if (quoted) {
                i += 1;
            },
            '"' => quoted = !quoted,
            '#' => if (!quoted) return line[0..i],
            else => {},
        }
    }
    return line;
}

const StringError = error{ NotAString, Unclosed, BadEscape, OutOfMemory };

fn stringFailure(diagnostic: *Diagnostic, line: usize, err: StringError) error{ InvalidConfig, OutOfMemory } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotAString => diagnostic.fail(line, "expected a \"string\"", .{}),
        error.Unclosed => diagnostic.fail(line, "string is not closed", .{}),
        error.BadEscape => diagnostic.fail(line, "only \\\" and \\\\ escapes are supported", .{}),
    };
}

fn readString(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) StringError![]const u8 {
    out.clearRetainingCapacity();
    if (text.len == 0 or text[0] != '"') return error.NotAString;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '"' => return text[i + 1 ..],
            '\\' => {
                i += 1;
                if (i == text.len or (text[i] != '"' and text[i] != '\\')) return error.BadEscape;
                try out.append(gpa, text[i]);
            },
            else => |byte| try out.append(gpa, byte),
        }
    }
    return error.Unclosed;
}

fn parseOk(source: []const u8) !Config {
    var diagnostic: Diagnostic = .{};
    return parse(std.testing.allocator, source, &diagnostic);
}

test "an empty file means the defaults" {
    var config = try parseOk("");
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(30 * seconds_per_day, config.min_age_s);
    try std.testing.expectEqual(Missing.deny, config.missing);
    try std.testing.expectEqual(@as(usize, 0), config.exempt_xuids.len);
    try std.testing.expect(std.mem.indexOf(u8, config.kick, "30 days") != null);
}

test "every setting is read, with comments, escapes and sorted unique XUIDs" {
    var config = try parseOk(
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
    var config = try parseOk("min_age_days = 7\r\nexempt_xuids = [\"5\",]\r\n");
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
    var config = try parseOk(fits);
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
            var config = try parse(gpa, text, &diagnostic);
            config.deinit(gpa);
        }
    }.run, .{source});
}

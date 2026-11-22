const std = @import("std");
const config = @import("config.zig");
const parseXuid = @import("../account/identity.zig").parseXuid;
const Allocator = std.mem.Allocator;
const Config = config.Config;
const Missing = config.Missing;
pub const max_min_age_days = 36500;
pub const max_kick_bytes = 512;
pub const max_exempt = 65536;
pub const default_kick = "Your account is too new to play here. Please come back when it is {days} days old.";

const Key = enum { min_age_days, kick_message, missing_date, exempt_xuids };

pub const Diagnostic = struct {
    buffer: [192]u8 = undefined,
    text: []const u8 = "",

    fn fail(self: *Diagnostic, line: usize, comptime format: []const u8, args: anytype) error{InvalidConfig} {
        self.text = std.fmt.bufPrint(&self.buffer, "line {d}: " ++ format, .{line} ++ args) catch "invalid setting";
        return error.InvalidConfig;
    }
};

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
                if (!std.unicode.utf8ValidateSlice(message.items)) return diagnostic.fail(line_number, "kick_message must be valid UTF-8", .{});
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
    exempt.shrinkRetainingCapacity(unique);
    const xuids = try exempt.toOwnedSlice(gpa);
    errdefer gpa.free(xuids);
    const kick = if (std.mem.indexOf(u8, template, "{days}")) |at|
        try std.fmt.allocPrint(gpa, "{s}{d}{s}", .{ template[0..at], days, template[at + "{days}".len ..] })
    else
        try gpa.dupe(u8, template);
    return .{ .min_age_s = days * std.time.s_per_day, .missing = missing, .exempt_xuids = xuids, .kick = kick };
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

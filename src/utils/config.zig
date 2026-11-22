const std = @import("std");
const builtin = @import("builtin");
const bifrost = @import("bifrost_plugin");
const toml = @import("toml");
const Allocator = std.mem.Allocator;

const file_name = "AccountGuard.toml";
const default_kick = "Your account is too new to play here. Please come back when it is {days} days old.";
const max_exempt = 65536;
const Key = enum { min_age_days, kick_message, missing_date, exempt_xuids };

pub const Config = struct {
    min_age_s: i64,
    missing: enum { deny, allow } = .deny,
    exempt_xuids: []const u64 = &.{},
    kick: []const u8 = "",

    pub fn load(host: bifrost.Host, gpa: Allocator) !Config {
        const io = std.Io.Threaded.global_single_threaded.io();
        var library_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const directory = pluginDirectory(&library_buffer) orelse {
            host.log(.err, "can't locate {s} beside the plugin", .{file_name});
            return error.PluginDirectoryUnavailable;
        };
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}{c}{s}", .{ directory, std.fs.path.sep, file_name });
        const source: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => missing: {
                host.log(.info, "no {s} beside the plugin, using the defaults", .{file_name});
                break :missing null;
            },
            else => {
                host.log(.err, "can't read {s}: {t}", .{ path, err });
                return err;
            },
        };
        defer if (source) |bytes| gpa.free(bytes);
        var line: usize = 0;
        return parse(gpa, source orelse "", &line) catch |err| {
            host.log(.err, "{s}:{d}: {t}", .{ path, line, err });
            return err;
        };
    }

    pub fn deinit(self: Config, gpa: Allocator) void {
        gpa.free(self.exempt_xuids);
        gpa.free(self.kick);
    }

    pub fn parse(gpa: Allocator, source: []const u8, line_number: *usize) !Config {
        var config: Config = .{ .min_age_s = undefined };
        errdefer config.deinit(gpa);
        var days: i64 = 30;
        var kick_buffer: [512]u8 = undefined;
        var template: []const u8 = default_kick;
        var seen: std.EnumSet(Key) = .empty;
        var parser = toml.Parser(toml.Table).init(gpa);
        defer parser.deinit();
        var lines = std.mem.splitScalar(u8, source, '\n');
        line_number.* = 0;
        while (lines.next()) |raw| {
            line_number.* += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidAssignment;
            const name = std.mem.trim(u8, line[0..equals], " \t");
            const key = std.meta.stringToEnum(Key, name) orelse return error.UnknownKey;
            if (seen.contains(key)) return error.DuplicateKey;
            seen.insert(key);

            const value_start = std.mem.trimStart(u8, line[equals + 1 ..], " \t");
            const text = value_start[0..try valueEnd(value_start)];
            const parsed = try parser.parseString(line[0 .. line.len - value_start.len + text.len]);
            defer parsed.deinit();
            const value = parsed.value.get(name) orelse return error.InvalidAssignment;
            switch (key) {
                .min_age_days => {
                    if (value != .integer or value.integer < 0 or value.integer > 36500 or
                        std.mem.indexOfAny(u8, text, "bBoOxX") != null) return error.InvalidMinAgeDays;
                    days = value.integer;
                },
                .missing_date => {
                    if (value != .string) return error.InvalidMissingDate;
                    config.missing = std.meta.stringToEnum(@TypeOf(config.missing), value.string) orelse return error.InvalidMissingDate;
                },
                .kick_message => {
                    if (value != .string or value.string.len == 0 or value.string.len > kick_buffer.len or
                        !std.unicode.utf8ValidateSlice(value.string)) return error.InvalidKickMessage;
                    @memcpy(kick_buffer[0..value.string.len], value.string);
                    template = kick_buffer[0..value.string.len];
                },
                .exempt_xuids => {
                    if (value != .array or value.array.items.len > max_exempt) return error.InvalidExemptXuids;
                    const xuids = try gpa.alloc(u64, value.array.items.len);
                    config.exempt_xuids = xuids;
                    for (value.array.items, xuids) |item, *xuid| {
                        if (item != .string) return error.InvalidExemptXuids;
                        xuid.* = parseXuid(item.string) orelse return error.InvalidExemptXuids;
                    }
                    std.mem.sort(u64, xuids, {}, std.sort.asc(u64));
                    var unique: usize = 0;
                    for (xuids) |xuid| {
                        if (unique != 0 and xuids[unique - 1] == xuid) continue;
                        xuids[unique] = xuid;
                        unique += 1;
                    }
                    if (unique != xuids.len) config.exempt_xuids = try gpa.realloc(xuids, unique);
                },
            }
        }

        config.kick = if (std.mem.indexOf(u8, template, "{days}")) |at|
            try std.fmt.allocPrint(gpa, "{s}{d}{s}", .{ template[0..at], days, template[at + "{days}".len ..] })
        else
            try gpa.dupe(u8, template);
        config.min_age_s = days * std.time.s_per_day;
        return config;
    }
};

// Keep one flat assignment per line. zig-toml overwrites duplicate keys and parses nested values recursively.
fn valueEnd(value: []const u8) !usize {
    const array = value.len != 0 and value[0] == '[';
    var commas: usize = 0;
    var quoted = false;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (quoted) {
            switch (value[i]) {
                '\\' => {
                    i += 1;
                    if (i == value.len or (value[i] != '\\' and value[i] != '"')) return error.InvalidStringEscape;
                },
                '"' => quoted = false,
                else => {},
            }
            continue;
        }
        switch (value[i]) {
            '#' => return i,
            '=', '{', '}', '\'' => return error.InvalidAssignment,
            '[' => if (i != 0) return error.InvalidAssignment,
            ',' => if (array) {
                commas += 1;
                if (commas == max_exempt and
                    !std.mem.startsWith(u8, std.mem.trimStart(u8, value[i + 1 ..], " \t\r"), "]"))
                    return error.InvalidExemptXuids;
            },
            '"' => {
                if (std.mem.startsWith(u8, value[i..], "\"\"\"")) return error.InvalidAssignment;
                quoted = true;
            },
            else => {},
        }
    }
    if (quoted) return error.InvalidAssignment;
    return value.len;
}

pub fn parseXuid(text: []const u8) ?u64 {
    if (text.len == 0 or text.len > 20) return null;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    const xuid = std.fmt.parseInt(u64, text, 10) catch return null;
    return if (xuid == 0) null else xuid;
}

fn pluginDirectory(buffer: []u8) ?[]const u8 {
    const address: *const anyopaque = @ptrCast(&pluginDirectory);
    if (builtin.os.tag == .windows) {
        var module: ?std.os.windows.HMODULE = null;
        const from_address_unchanged_refcount = 0x4 | 0x2;
        if (GetModuleHandleExW(from_address_unchanged_refcount, address, &module) == 0) return null;
        var wide: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
        const len = GetModuleFileNameW(module, &wide, wide.len);
        if (len == 0 or len >= wide.len) return null;
        if (std.unicode.calcWtf8Len(wide[0..len]) > buffer.len) return null;
        return std.fs.path.dirname(buffer[0..std.unicode.wtf16LeToWtf8(buffer, wide[0..len])]);
    }
    var info: DlInfo = undefined;
    if (dladdr(address, &info) == 0) return null;
    return std.fs.path.dirname(std.mem.span(info.file orelse return null));
}

extern "kernel32" fn GetModuleHandleExW(flags: u32, address: *const anyopaque, module: *?std.os.windows.HMODULE) callconv(.winapi) c_int;
extern "kernel32" fn GetModuleFileNameW(module: ?std.os.windows.HMODULE, buffer: [*]u16, size: u32) callconv(.winapi) u32;

const DlInfo = extern struct {
    file: ?[*:0]const u8,
    base: ?*anyopaque,
    symbol: ?[*:0]const u8,
    address: ?*anyopaque,
};
extern "c" fn dladdr(address: *const anyopaque, info: *DlInfo) c_int;

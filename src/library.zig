const std = @import("std");
const builtin = @import("builtin");

pub fn directory(buffer: []u8) ?[]const u8 {
    const path = switch (builtin.os.tag) {
        .windows => windowsPath(buffer),
        else => posixPath(buffer),
    } orelse return null;
    return std.fs.path.dirname(path);
}

const windows = struct {
    const from_address = 0x4;
    const unchanged_refcount = 0x2;

    extern "kernel32" fn GetModuleHandleExW(flags: u32, address: ?*const anyopaque, module: *?std.os.windows.HMODULE) callconv(.winapi) c_int;
    extern "kernel32" fn GetModuleFileNameW(module: ?std.os.windows.HMODULE, buffer: [*]u16, size: u32) callconv(.winapi) u32;
};

fn windowsPath(buffer: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) unreachable;
    var module: ?std.os.windows.HMODULE = null;
    if (windows.GetModuleHandleExW(windows.from_address | windows.unchanged_refcount, @ptrCast(&directory), &module) == 0) return null;
    var wide: [std.fs.max_path_bytes]u16 = undefined;
    const len = windows.GetModuleFileNameW(module, &wide, wide.len);
    if (len == 0 or len >= wide.len) return null;
    const bytes = std.unicode.wtf16LeToWtf8(buffer, wide[0..len]);
    return buffer[0..bytes];
}

const DlInfo = extern struct {
    file: ?[*:0]const u8,
    base: ?*anyopaque,
    symbol: ?[*:0]const u8,
    address: ?*anyopaque,
};

extern "c" fn dladdr(address: *const anyopaque, info: *DlInfo) c_int;

fn posixPath(buffer: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) unreachable;
    var info: DlInfo = undefined;
    if (dladdr(@ptrCast(&directory), &info) == 0) return null;
    const file = std.mem.span(info.file orelse return null);
    if (file.len > buffer.len) return null;
    @memcpy(buffer[0..file.len], file);
    return buffer[0..file.len];
}

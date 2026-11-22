const std = @import("std");
const abi = @import("bifrost_plugin").abi;

pub fn verifiedXuid(info: *const abi.PlayerInfo) ?u64 {
    if (info.state.authentication != .authenticated or info.online != 1) return null;
    if (info.xuid_len > info.xuid.len or info.struct_size < @offsetOf(abi.PlayerInfo, "xuid") + info.xuid_len) return null;
    return parseXuid(info.xuid[0..info.xuid_len]);
}

pub fn parseXuid(text: []const u8) ?u64 {
    if (text.len == 0 or text.len > 20) return null;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    const xuid = std.fmt.parseInt(u64, text, 10) catch return null;
    return if (xuid == 0) null else xuid;
}

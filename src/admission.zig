const std = @import("std");
const bifrost = @import("bifrost_plugin");
const settings = @import("utils/config.zig");
const abi = bifrost.abi;

pub fn admit(host: bifrost.Host, config: *const settings.Config, player: bifrost.Player, decision: ?*bifrost.TransferDecision, now: i64) void {
    const out = decision orelse return;
    if (out.action != .proceed or config.min_age_s == 0 or allows(host, config, player, now)) return;
    out.action = if (host.disconnect(player, config.kick, null, null)) .hold_login else |_| .cancel;
}

fn allows(host: bifrost.Host, config: *const settings.Config, player: bifrost.Player, now: i64) bool {
    if (config.exempt_xuids.len != 0) {
        const info = host.playerInfo(player) catch return false;
        const xuid_offset = @offsetOf(abi.PlayerInfo, "xuid");
        if (info.struct_size >= xuid_offset and
            info.state.authentication == .authenticated and info.online == 1 and
            info.xuid_len <= info.xuid.len and
            info.struct_size - xuid_offset >= info.xuid_len)
        {
            if (settings.parseXuid(info.xuid[0..info.xuid_len])) |xuid| {
                if (std.sort.binarySearch(u64, config.exempt_xuids, xuid, orderXuid) != null) return true;
            }
        }
    }

    const account = host.playerAccount(player) catch return false;
    if (account.struct_size < @offsetOf(abi.PlayerAccount, "playfab_created_s") + @sizeOf(i64) or
        account.available & abi.account_playfab_created == 0 or
        account.playfab_created_s <= 0 or account.playfab_created_s > now +| 300)
        return config.missing == .allow;
    return now -| account.playfab_created_s >= config.min_age_s;
}

fn orderXuid(xuid: u64, candidate: u64) std.math.Order {
    return std.math.order(xuid, candidate);
}

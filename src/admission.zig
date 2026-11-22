const bifrost = @import("bifrost_plugin");
const Config = @import("config/config.zig").Config;
const age = @import("account/age.zig");
const identity = @import("account/identity.zig");

pub fn supported(host: bifrost.Host) bool {
    return host.raw.has(.player_account) and host.raw.has(.disconnect);
}

pub const Guard = struct {
    host: bifrost.Host,
    config: Config,

    pub fn admit(self: *const Guard, player: bifrost.Player, decision: ?*bifrost.TransferDecision, now: i64) void {
        const out = decision orelse return;
        if (out.action != .proceed or self.config.min_age_s == 0 or self.allows(player, now)) return;
        out.action = if (self.host.disconnect(player, self.config.kick, null, null)) .hold_login else |_| .cancel;
    }

    fn allows(self: *const Guard, player: bifrost.Player, now: i64) bool {
        if (self.config.exempt_xuids.len != 0) {
            const info = self.host.playerInfo(player) catch return false;
            if (identity.verifiedXuid(&info)) |xuid| {
                if (self.config.exempt(xuid)) return true;
            }
        }
        const account = self.host.playerAccount(player) catch return false;
        return age.allows(self.config.min_age_s, self.config.missing, age.verifiedCreation(account), now);
    }
};

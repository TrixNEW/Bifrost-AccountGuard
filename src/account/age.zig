const abi = @import("bifrost_plugin").abi;
const Missing = @import("../config/config.zig").Missing;

pub const future_slack_s = 300;

pub fn verifiedCreation(account: abi.PlayerAccount) ?i64 {
    const needed = @offsetOf(abi.PlayerAccount, "playfab_created_s") + @sizeOf(i64);
    if (account.struct_size < needed or account.available & abi.account_playfab_created == 0) return null;
    return if (account.playfab_created_s > 0) account.playfab_created_s else null;
}

pub fn allows(min_age_s: i64, missing: Missing, created: ?i64, now: i64) bool {
    const date = created orelse return missing == .allow;
    if (date <= 0 or date > now +| future_slack_s) return missing == .allow;
    return now -| date >= min_age_s;
}

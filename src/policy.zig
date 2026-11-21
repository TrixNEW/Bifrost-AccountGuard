const std = @import("std");
const bifrost = @import("bifrost_plugin");
const config_mod = @import("config.zig");

const abi = bifrost.abi;
const Config = config_mod.Config;

// clocks drift a little, so a date slightly ahead still means a brand new account
pub const future_slack_s = 300;

pub const Verdict = enum {
    allowed,
    exempt,
    too_new,
    missing_date,
    unavailable,

    pub fn admits(self: Verdict) bool {
        return self == .allowed or self == .exempt;
    }
};

pub fn verifiedCreation(account: abi.PlayerAccount) ?i64 {
    const needed = @offsetOf(abi.PlayerAccount, "playfab_created_s") + @sizeOf(i64);
    if (account.struct_size < needed or account.available & abi.account_playfab_created == 0) return null;
    return if (account.playfab_created_s > 0) account.playfab_created_s else null;
}

// zero means unverified, which never matches an exemption
pub fn verifiedXuid(info: abi.PlayerInfo) u64 {
    if (info.state.authentication != .authenticated or info.online == 0) return 0;
    return config_mod.parseXuid(info.xuid[0..@min(info.xuid_len, info.xuid.len)]) orelse 0;
}

// a far-future date counts as missing, never as old
pub fn judge(config: *const Config, xuid: u64, created: ?i64, now: i64) Verdict {
    if (config.min_age_s == 0) return .allowed;
    if (config.exempt(xuid)) return .exempt;
    const date = created orelse return missing(config);
    if (date > now + future_slack_s) return missing(config);
    return if (now - date >= config.min_age_s) .allowed else .too_new;
}

fn missing(config: *const Config) Verdict {
    return if (config.missing == .allow) .allowed else .missing_date;
}

const day = config_mod.seconds_per_day;
const test_now: i64 = 1_700_000_000;

fn testConfig(days: i64, policy: config_mod.Missing, exempt: []const u64) Config {
    return .{ .min_age_s = days * day, .missing = policy, .exempt_xuids = exempt, .kick = "" };
}

test "the age threshold is inclusive to the second" {
    const config = testConfig(30, .deny, &.{});
    try std.testing.expectEqual(Verdict.allowed, judge(&config, 0, test_now - 30 * day, test_now));
    try std.testing.expectEqual(Verdict.too_new, judge(&config, 0, test_now - 30 * day + 1, test_now));
    try std.testing.expectEqual(Verdict.allowed, judge(&config, 0, test_now - 400 * day, test_now));
    try std.testing.expectEqual(Verdict.too_new, judge(&config, 0, test_now, test_now));
    try std.testing.expectEqual(Verdict.allowed, judge(&testConfig(7, .deny, &.{}), 0, test_now - 8 * day, test_now));
    try std.testing.expectEqual(Verdict.too_new, judge(&testConfig(7, .deny, &.{}), 0, test_now - 6 * day, test_now));
}

test "zero days turns the check off" {
    const config = testConfig(0, .deny, &.{});
    try std.testing.expectEqual(Verdict.allowed, judge(&config, 0, null, test_now));
    try std.testing.expectEqual(Verdict.allowed, judge(&config, 0, test_now, test_now));
}

test "missing and future dates follow the policy and never read as old" {
    const deny = testConfig(30, .deny, &.{});
    try std.testing.expectEqual(Verdict.missing_date, judge(&deny, 0, null, test_now));
    try std.testing.expectEqual(Verdict.missing_date, judge(&deny, 0, test_now + future_slack_s + 1, test_now));
    try std.testing.expectEqual(Verdict.too_new, judge(&deny, 0, test_now + future_slack_s, test_now));
    try std.testing.expectEqual(Verdict.too_new, judge(&deny, 0, test_now + 1, test_now));

    const allow = testConfig(30, .allow, &.{});
    try std.testing.expectEqual(Verdict.allowed, judge(&allow, 0, null, test_now));
    try std.testing.expectEqual(Verdict.allowed, judge(&allow, 0, test_now + future_slack_s + 1, test_now));
    try std.testing.expectEqual(Verdict.too_new, judge(&allow, 0, test_now - day, test_now));
}

test "exempt XUIDs skip the check and zero never matches" {
    const config = testConfig(30, .deny, &.{ 2535400000000001, 2535400000000003 });
    try std.testing.expectEqual(Verdict.exempt, judge(&config, 2535400000000001, test_now - day, test_now));
    try std.testing.expectEqual(Verdict.exempt, judge(&config, 2535400000000003, null, test_now));
    try std.testing.expectEqual(Verdict.too_new, judge(&config, 2535400000000002, test_now - day, test_now));
    try std.testing.expectEqual(Verdict.too_new, judge(&config, 0, test_now - day, test_now));
}

test "only a complete, positive, flagged date is trusted" {
    var account: abi.PlayerAccount = .{ .available = abi.account_playfab_created, .playfab_created_s = test_now - 40 * day };
    try std.testing.expectEqual(@as(?i64, test_now - 40 * day), verifiedCreation(account));

    var cleared = account;
    cleared.available = 0;
    try std.testing.expectEqual(@as(?i64, null), verifiedCreation(cleared));
    var short = account;
    short.struct_size = 8;
    try std.testing.expectEqual(@as(?i64, null), verifiedCreation(short));
    account.playfab_created_s = 0;
    try std.testing.expectEqual(@as(?i64, null), verifiedCreation(account));
    account.playfab_created_s = -1;
    try std.testing.expectEqual(@as(?i64, null), verifiedCreation(account));
}

test "a XUID counts only from a verified online identity" {
    var info: abi.PlayerInfo = .{};
    info.state.authentication = .authenticated;
    info.online = 1;
    @memcpy(info.xuid[0..16], "2535400000000001");
    info.xuid_len = 16;
    try std.testing.expectEqual(@as(u64, 2535400000000001), verifiedXuid(info));

    var offline = info;
    offline.online = 0;
    try std.testing.expectEqual(@as(u64, 0), verifiedXuid(offline));
    var pending = info;
    pending.state.authentication = .pending;
    try std.testing.expectEqual(@as(u64, 0), verifiedXuid(pending));
    var empty = info;
    empty.xuid_len = 0;
    try std.testing.expectEqual(@as(u64, 0), verifiedXuid(empty));
    var named = info;
    @memcpy(named.xuid[0..5], "Steve");
    named.xuid_len = 5;
    try std.testing.expectEqual(@as(u64, 0), verifiedXuid(named));
    var oversized = info;
    oversized.xuid_len = 1000;
    try std.testing.expectEqual(@as(u64, 0), verifiedXuid(oversized));
}

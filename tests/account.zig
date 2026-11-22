const std = @import("std");
const abi = @import("bifrost_plugin").abi;
const age = @import("../src/account/age.zig");
const identity = @import("../src/account/identity.zig");
const day = std.time.s_per_day;
const test_now: i64 = 1_700_000_000;

test "the age threshold is inclusive to the second" {
    try std.testing.expectEqual(true, age.allows(30 * day, .deny, test_now - 30 * day, test_now));
    try std.testing.expectEqual(false, age.allows(30 * day, .deny, test_now - 30 * day + 1, test_now));
    try std.testing.expectEqual(true, age.allows(30 * day, .deny, test_now - 400 * day, test_now));
    try std.testing.expectEqual(false, age.allows(30 * day, .deny, test_now, test_now));
    try std.testing.expectEqual(true, age.allows(7 * day, .deny, test_now - 8 * day, test_now));
    try std.testing.expectEqual(false, age.allows(7 * day, .deny, test_now - 6 * day, test_now));
}

test "missing and future dates follow the policy and never read as old" {
    try std.testing.expectEqual(false, age.allows(30 * day, .deny, null, test_now));
    try std.testing.expectEqual(false, age.allows(30 * day, .deny, test_now + age.future_slack_s + 1, test_now));
    try std.testing.expectEqual(false, age.allows(30 * day, .deny, test_now + age.future_slack_s, test_now));
    try std.testing.expectEqual(false, age.allows(30 * day, .deny, test_now + 1, test_now));

    try std.testing.expectEqual(true, age.allows(30 * day, .allow, null, test_now));
    try std.testing.expectEqual(true, age.allows(30 * day, .allow, test_now + age.future_slack_s + 1, test_now));
    try std.testing.expectEqual(false, age.allows(30 * day, .allow, test_now - day, test_now));
}

test "only a complete, positive, flagged date is trusted" {
    var account: abi.PlayerAccount = .{ .available = abi.account_playfab_created, .playfab_created_s = test_now - 40 * day };
    try std.testing.expectEqual(@as(?i64, test_now - 40 * day), age.verifiedCreation(account));

    var cleared = account;
    cleared.available = 0;
    try std.testing.expectEqual(@as(?i64, null), age.verifiedCreation(cleared));
    var short = account;
    short.struct_size = 8;
    try std.testing.expectEqual(@as(?i64, null), age.verifiedCreation(short));
    account.playfab_created_s = 0;
    try std.testing.expectEqual(@as(?i64, null), age.verifiedCreation(account));
    account.playfab_created_s = -1;
    try std.testing.expectEqual(@as(?i64, null), age.verifiedCreation(account));
}

test "a XUID counts only from a verified online identity" {
    var info: abi.PlayerInfo = .{};
    info.state.authentication = .authenticated;
    info.online = 1;
    @memcpy(info.xuid[0..16], "2535400000000001");
    info.xuid_len = 16;
    try std.testing.expectEqual(@as(?u64, 2535400000000001), identity.verifiedXuid(&info));

    var offline = info;
    offline.online = 0;
    try std.testing.expectEqual(@as(?u64, null), identity.verifiedXuid(&offline));
    var pending = info;
    pending.state.authentication = .pending;
    try std.testing.expectEqual(@as(?u64, null), identity.verifiedXuid(&pending));
    var empty = info;
    empty.xuid_len = 0;
    try std.testing.expectEqual(@as(?u64, null), identity.verifiedXuid(&empty));
    var named = info;
    @memcpy(named.xuid[0..5], "Steve");
    named.xuid_len = 5;
    try std.testing.expectEqual(@as(?u64, null), identity.verifiedXuid(&named));
    var oversized = info;
    oversized.xuid_len = 1000;
    try std.testing.expectEqual(@as(?u64, null), identity.verifiedXuid(&oversized));
    var short = info;
    short.struct_size = @offsetOf(abi.PlayerInfo, "xuid") + info.xuid_len - 1;
    try std.testing.expectEqual(@as(?u64, null), identity.verifiedXuid(&short));
}

test "age comparison handles extreme clocks and dates" {
    try std.testing.expect(age.allows(day, .deny, 1, std.math.maxInt(i64)));
    try std.testing.expect(!age.allows(day, .deny, std.math.maxInt(i64), std.math.maxInt(i64)));
    try std.testing.expect(!age.allows(day, .deny, std.math.maxInt(i64), std.math.minInt(i64)));
}

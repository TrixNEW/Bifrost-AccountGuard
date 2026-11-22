const std = @import("std");
const abi = @import("bifrost_plugin").abi;
const admission = @import("../src/admission.zig");
const config_mod = @import("../src/config/config.zig");
const Config = config_mod.Config;
const Fake = @import("mocks/host.zig").Fake;

fn login(fake: *Fake, config: Config, owner: bool) abi.TransferAction {
    const guard: admission.Guard = .{ .host = fake.host(), .config = config };
    var decision: abi.TransferDecision = .{};
    guard.admit(.{ .id = 1 }, if (owner) &decision else null, Fake.now);
    return decision.action;
}

fn testConfig(days: i64, missing: config_mod.Missing, exempt: []const u64) Config {
    return .{ .min_age_s = days * std.time.s_per_day, .missing = missing, .exempt_xuids = exempt, .kick = "Come back in 30 days" };
}

test "an old enough account goes straight on to a backend" {
    var fake: Fake = undefined;
    fake.init();
    try std.testing.expectEqual(abi.TransferAction.proceed, login(&fake, testConfig(30, .deny, &.{}), true));
    try std.testing.expectEqual(@as(u32, 0), fake.disconnects);
    try std.testing.expectEqual(@as(u32, 0), fake.info_calls);
    try std.testing.expectEqual(@as(u32, 1), fake.account_calls);
}

test "a new account is held off the backend and told why in the configured words" {
    var fake: Fake = undefined;
    fake.init();
    fake.created(Fake.now - 2 * Fake.day);
    try std.testing.expectEqual(abi.TransferAction.hold_login, login(&fake, testConfig(30, .deny, &.{}), true));
    try std.testing.expectEqual(@as(u32, 1), fake.disconnects);
    try std.testing.expectEqualStrings("Come back in 30 days", fake.reason_buffer[0..fake.reason_len]);
}

test "a disconnect that can't be queued still refuses, by cancelling" {
    var fake: Fake = undefined;
    fake.init();
    fake.created(Fake.now - Fake.day);
    fake.disconnect_status = .busy;
    try std.testing.expectEqual(abi.TransferAction.cancel, login(&fake, testConfig(30, .deny, &.{}), true));
    try std.testing.expectEqual(@as(u32, 1), fake.disconnects);
}

test "no date follows missing_date, and a far-future date counts as none" {
    var fake: Fake = undefined;
    fake.init();
    fake.account = .{};
    try std.testing.expectEqual(abi.TransferAction.hold_login, login(&fake, testConfig(30, .deny, &.{}), true));
    try std.testing.expectEqual(abi.TransferAction.proceed, login(&fake, testConfig(30, .allow, &.{}), true));

    fake.created(Fake.now + 10 * Fake.day);
    try std.testing.expectEqual(abi.TransferAction.hold_login, login(&fake, testConfig(30, .deny, &.{}), true));
    try std.testing.expectEqual(abi.TransferAction.proceed, login(&fake, testConfig(30, .allow, &.{}), true));
}

test "failing to learn anything about the player refuses, even where a missing date is allowed" {
    const allow = testConfig(30, .allow, &.{});
    var fake: Fake = undefined;
    fake.init();
    fake.info_status = .stale_handle;
    try std.testing.expectEqual(abi.TransferAction.hold_login, login(&fake, testConfig(30, .allow, &.{Fake.vip}), true));
    fake.init();
    fake.account_status = .failed;
    try std.testing.expectEqual(abi.TransferAction.hold_login, login(&fake, allow, true));
}

test "exemptions apply only to a verified XUID" {
    const config = testConfig(30, .deny, &.{Fake.vip});
    var fake: Fake = undefined;
    fake.init();
    fake.created(Fake.now - Fake.day);
    fake.account_status = .failed;
    try std.testing.expectEqual(abi.TransferAction.proceed, login(&fake, config, true));
    try std.testing.expectEqual(@as(u32, 1), fake.info_calls);
    try std.testing.expectEqual(@as(u32, 0), fake.account_calls);
    fake.account_status = .ok;

    fake.verified(Fake.vip, false, .authenticated);
    try std.testing.expectEqual(abi.TransferAction.hold_login, login(&fake, config, true));
    fake.verified(Fake.vip, true, .pending);
    try std.testing.expectEqual(abi.TransferAction.hold_login, login(&fake, config, true));
    fake.verified(Fake.vip, true, .authenticated);
    fake.info.xuid_len = 0;
    try std.testing.expectEqual(abi.TransferAction.hold_login, login(&fake, config, true));
    fake.verified(Fake.vip, true, .authenticated);
    @memcpy(fake.info.xuid[0..5], "Steve");
    fake.info.xuid_len = 5;
    try std.testing.expectEqual(abi.TransferAction.hold_login, login(&fake, config, true));
}

test "turned off, nothing is asked of the host and nobody is refused" {
    var fake: Fake = undefined;
    fake.init();
    fake.info_status = .failed;
    try std.testing.expectEqual(abi.TransferAction.proceed, login(&fake, testConfig(0, .deny, &.{}), true));
    try std.testing.expectEqual(@as(u32, 0), fake.info_calls);
    try std.testing.expectEqual(@as(u32, 0), fake.account_calls);
}

test "without a decision pointer there is nothing to refuse" {
    var fake: Fake = undefined;
    fake.init();
    fake.created(Fake.now - Fake.day);
    try std.testing.expectEqual(abi.TransferAction.proceed, login(&fake, testConfig(30, .deny, &.{}), false));
    try std.testing.expectEqual(@as(u32, 0), fake.disconnects);
    try std.testing.expectEqual(@as(u32, 0), fake.account_calls);
}

test "a host that predates player_account is refused up front" {
    var fake: Fake = undefined;
    fake.init();
    try std.testing.expect(admission.supported(fake.host()));
    fake.raw.struct_size = @offsetOf(abi.Host, "player_account");
    try std.testing.expect(!admission.supported(fake.host()));
}

test "an existing admission action is preserved" {
    var fake: Fake = undefined;
    fake.init();
    fake.account_status = .failed;
    const guard: admission.Guard = .{ .host = fake.host(), .config = testConfig(30, .deny, &.{}) };
    var decision: abi.TransferDecision = .{ .action = .cancel };
    guard.admit(.{ .id = 1 }, &decision, Fake.now);
    try std.testing.expectEqual(abi.TransferAction.cancel, decision.action);
    try std.testing.expectEqual(@as(u32, 0), fake.account_calls);
    try std.testing.expectEqual(@as(u32, 0), fake.disconnects);
}

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const abi = @import("bifrost_plugin").abi;
const admission = @import("../src/admission.zig");
const Config = @import("../src/utils/config.zig").Config;
const Fake = @import("mocks/host.zig").Fake;

const minimum = 30 * Fake.day;
const config: Config = .{ .min_age_s = minimum, .kick = "Come back in 30 days" };
const player: abi.Player = .{ .id = 1 };

fn login(fake: *Fake, settings: Config) abi.TransferAction {
    var decision: abi.TransferDecision = .{};
    admission.admit(fake.host(), &settings, player, &decision, Fake.now);
    return decision.action;
}

test "the age limit is inclusive and refusals hold or cancel admission" {
    var fake: Fake = undefined;
    fake.init();
    fake.created(Fake.now - minimum);
    try expectEqual(.proceed, login(&fake, config));
    try expectEqual(0, fake.info_calls);
    try expectEqual(1, fake.account_calls);
    try expectEqual(0, fake.disconnects);

    fake.created(Fake.now - minimum + 1);
    try expectEqual(.hold_login, login(&fake, config));
    try std.testing.expectEqualStrings(config.kick, fake.reason_buffer[0..fake.reason_len]);
    fake.disconnect_status = .busy;
    try expectEqual(.cancel, login(&fake, config));
    try expectEqual(2, fake.disconnects);
}

test "only usable dates count and the future tolerance is inclusive" {
    var fake: Fake = undefined;
    fake.init();
    const allow: Config = .{ .min_age_s = minimum, .missing = .allow };
    const old = Fake.now - minimum;
    for ([_]abi.PlayerAccount{
        .{ .playfab_created_s = old },
        .{ .playfab_created_s = old, .available = abi.account_playfab_created, .struct_size = 8 },
        .{ .playfab_created_s = 0, .available = abi.account_playfab_created },
        .{ .playfab_created_s = -1, .available = abi.account_playfab_created },
        .{ .playfab_created_s = Fake.now + 301, .available = abi.account_playfab_created },
    }) |account| {
        fake.account = account;
        try expectEqual(.hold_login, login(&fake, config));
        try expectEqual(.proceed, login(&fake, allow));
    }
    fake.created(Fake.now + 300);
    try expectEqual(.hold_login, login(&fake, allow));
    fake.account_status = .failed;
    try expectEqual(.hold_login, login(&fake, allow));
}

test "only an authenticated online identity with a complete XUID skips the age lookup" {
    var fake: Fake = undefined;
    fake.init();
    const exempt: Config = .{ .min_age_s = minimum, .missing = .allow, .exempt_xuids = &.{ 1, Fake.vip, Fake.vip + 1 } };
    fake.created(Fake.now);
    try expectEqual(.proceed, login(&fake, exempt));
    try expectEqual(1, fake.info_calls);
    try expectEqual(0, fake.account_calls);

    const verified = fake.info;
    fake.info.online = 0;
    try expectEqual(.hold_login, login(&fake, exempt));
    fake.info = verified;
    fake.info.state.authentication = .pending;
    try expectEqual(.hold_login, login(&fake, exempt));
    fake.info = verified;
    fake.info.struct_size = @offsetOf(abi.PlayerInfo, "xuid") + verified.xuid_len - 1;
    try expectEqual(.hold_login, login(&fake, exempt));
    fake.info = verified;
    fake.info.xuid_len = 1000;
    try expectEqual(.hold_login, login(&fake, exempt));

    try expectEqual(4, fake.account_calls);
    fake.info_status = .stale_handle;
    try expectEqual(.hold_login, login(&fake, exempt));
    try expectEqual(4, fake.account_calls);
}

test "disabled or previously decided admissions make no host calls" {
    var fake: Fake = undefined;
    fake.init();
    try expectEqual(.proceed, login(&fake, .{ .min_age_s = 0 }));
    var decision: abi.TransferDecision = .{ .action = .cancel };
    admission.admit(fake.host(), &config, player, &decision, Fake.now);
    try expectEqual(.cancel, decision.action);
    admission.admit(fake.host(), &config, player, null, Fake.now);
    try expectEqual(0, fake.info_calls);
    try expectEqual(0, fake.account_calls);
    try expectEqual(0, fake.disconnects);
}

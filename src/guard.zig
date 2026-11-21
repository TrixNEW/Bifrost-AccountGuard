const std = @import("std");
const bifrost = @import("bifrost_plugin");
const config_mod = @import("config.zig");
const policy = @import("policy.zig");

const abi = bifrost.abi;
const Config = config_mod.Config;
const Verdict = policy.Verdict;

pub const Guard = struct {
    host: bifrost.Host,
    config: Config,
    checked: std.atomic.Value(u64) = .init(0),
    refused: std.atomic.Value(u64) = .init(0),

    pub fn supported(host: bifrost.Host) bool {
        return host.raw.has(.player_account) and host.raw.has(.disconnect);
    }

    pub fn check(self: *Guard, player: bifrost.Player, now: i64) Verdict {
        if (self.config.min_age_s == 0) return .allowed;
        // no answer means no admit, even with missing_date = "allow"
        const info = self.host.playerInfo(player) catch return self.unavailable();
        const account = self.host.playerAccount(player) catch return self.unavailable();
        const created = policy.verifiedCreation(account);
        const verdict = policy.judge(&self.config, policy.verifiedXuid(info), created, now);
        if (!verdict.admits()) {
            const name = info.name[0..@min(info.name_len, info.name.len)];
            if (created) |date| {
                self.host.log(.info, "refused {s}: account is {d} day(s) old", .{ name, @divFloor(@max(now - date, 0), config_mod.seconds_per_day) });
            } else {
                self.host.log(.info, "refused {s}: account age unknown", .{name});
            }
        }
        return verdict;
    }

    // hold_login keeps the backend out while the disconnect carries our message. cancel also refuses,
    // but Bifrost shows its own text then, so it's only the fallback.
    pub fn admit(self: *Guard, event: *const bifrost.Event, decision: ?*bifrost.TransferDecision, now: i64) void {
        const out = decision orelse return;
        _ = self.checked.fetchAdd(1, .monotonic);
        if (self.check(event.player, now).admits()) return;
        _ = self.refused.fetchAdd(1, .monotonic);
        out.action = if (self.host.disconnect(event.player, self.config.kick, null, null)) .hold_login else |_| .cancel;
    }

    pub fn summary(self: *Guard) void {
        self.host.log(.info, "refused {d} account(s) of {d} checked", .{ self.refused.load(.monotonic), self.checked.load(.monotonic) });
    }

    fn unavailable(self: *Guard) Verdict {
        self.host.log(.warn, "refused a player it couldn't look up", .{});
        return .unavailable;
    }
};

const Fake = struct {
    info: abi.PlayerInfo = .{},
    account: abi.PlayerAccount = .{},
    info_status: abi.Status = .ok,
    account_status: abi.Status = .ok,
    disconnect_status: abi.Status = .ok,
    disconnects: u32 = 0,
    reason_buffer: [128]u8 = undefined,
    reason_len: usize = 0,
    raw: abi.Host = undefined,

    const now: i64 = 1_700_000_000;
    const day = config_mod.seconds_per_day;
    const vip: u64 = 2535400000000001;

    fn init(self: *Fake) void {
        self.* = .{};
        self.raw.struct_size = @sizeOf(abi.Host);
        self.raw.context = self;
        self.raw.log = log;
        self.raw.player_info = playerInfo;
        self.raw.player_account = playerAccount;
        self.raw.disconnect = disconnect;
        self.verified(vip, true, .authenticated);
        self.created(now - 90 * day);
    }

    fn host(self: *Fake) bifrost.Host {
        return .{ .raw = &self.raw };
    }

    fn from(context: *anyopaque) *Fake {
        return @ptrCast(@alignCast(context));
    }

    fn log(_: *anyopaque, _: abi.LogLevel, _: abi.Str) callconv(.c) void {}

    fn playerInfo(context: *anyopaque, _: abi.Player, out: ?*abi.PlayerInfo, _: usize) callconv(.c) abi.Status {
        const self = from(context);
        out.?.* = self.info;
        return self.info_status;
    }

    fn playerAccount(context: *anyopaque, _: abi.Player, out: ?*abi.PlayerAccount, _: usize) callconv(.c) abi.Status {
        const self = from(context);
        out.?.* = self.account;
        return self.account_status;
    }

    fn disconnect(context: *anyopaque, _: abi.Player, reason: abi.Str, _: ?abi.TaskDoneFn, _: ?*anyopaque) callconv(.c) abi.Status {
        const self = from(context);
        self.disconnects += 1;
        self.reason_len = @min(reason.slice().len, self.reason_buffer.len);
        @memcpy(self.reason_buffer[0..self.reason_len], reason.slice()[0..self.reason_len]);
        return self.disconnect_status;
    }

    fn verified(self: *Fake, xuid: u64, online: bool, state: abi.AuthenticationState) void {
        self.info = .{};
        self.info.state.authentication = state;
        self.info.online = @intFromBool(online);
        const text = std.fmt.bufPrint(&self.info.xuid, "{d}", .{xuid}) catch unreachable;
        self.info.xuid_len = @intCast(text.len);
        @memcpy(self.info.name[0..5], "Steve");
        self.info.name_len = 5;
    }

    fn created(self: *Fake, seconds: i64) void {
        self.account = .{ .available = abi.account_playfab_created, .playfab_created_s = seconds };
    }

    fn login(self: *Fake, config: Config, owner: bool) !abi.TransferAction {
        var guard: Guard = .{ .host = self.host(), .config = config };
        var decision: abi.TransferDecision = .{};
        const event: abi.Event = .{ .kind = .player_authenticated, .player = .{ .id = 1 } };
        guard.admit(&event, if (owner) &decision else null, now);
        return decision.action;
    }
};

fn testConfig(days: i64, missing: config_mod.Missing, exempt: []const u64) Config {
    return .{ .min_age_s = days * config_mod.seconds_per_day, .missing = missing, .exempt_xuids = exempt, .kick = "Come back in 30 days" };
}

test "an old enough account goes straight on to a backend" {
    var fake: Fake = undefined;
    fake.init();
    try std.testing.expectEqual(abi.TransferAction.proceed, try fake.login(testConfig(30, .deny, &.{}), true));
    try std.testing.expectEqual(@as(u32, 0), fake.disconnects);
}

test "a new account is held off the backend and told why in the configured words" {
    var fake: Fake = undefined;
    fake.init();
    fake.created(Fake.now - 2 * Fake.day);
    try std.testing.expectEqual(abi.TransferAction.hold_login, try fake.login(testConfig(30, .deny, &.{}), true));
    try std.testing.expectEqual(@as(u32, 1), fake.disconnects);
    try std.testing.expectEqualStrings("Come back in 30 days", fake.reason_buffer[0..fake.reason_len]);
}

test "a disconnect that can't be queued still refuses, by cancelling" {
    var fake: Fake = undefined;
    fake.init();
    fake.created(Fake.now - Fake.day);
    fake.disconnect_status = .busy;
    try std.testing.expectEqual(abi.TransferAction.cancel, try fake.login(testConfig(30, .deny, &.{}), true));
    try std.testing.expectEqual(@as(u32, 1), fake.disconnects);
}

test "no date follows missing_date, and a far-future date counts as none" {
    var fake: Fake = undefined;
    fake.init();
    fake.account = .{};
    try std.testing.expectEqual(abi.TransferAction.hold_login, try fake.login(testConfig(30, .deny, &.{}), true));
    try std.testing.expectEqual(abi.TransferAction.proceed, try fake.login(testConfig(30, .allow, &.{}), true));

    fake.created(Fake.now + 10 * Fake.day);
    try std.testing.expectEqual(abi.TransferAction.hold_login, try fake.login(testConfig(30, .deny, &.{}), true));
    try std.testing.expectEqual(abi.TransferAction.proceed, try fake.login(testConfig(30, .allow, &.{}), true));
}

test "failing to learn anything about the player refuses, even where a missing date is allowed" {
    const allow = testConfig(30, .allow, &.{});
    var fake: Fake = undefined;
    fake.init();
    fake.info_status = .stale_handle;
    try std.testing.expectEqual(abi.TransferAction.hold_login, try fake.login(allow, true));
    fake.init();
    fake.account_status = .failed;
    try std.testing.expectEqual(abi.TransferAction.hold_login, try fake.login(allow, true));
}

test "exemptions apply only to a verified XUID" {
    const config = testConfig(30, .deny, &.{Fake.vip});
    var fake: Fake = undefined;
    fake.init();
    fake.created(Fake.now - Fake.day);
    try std.testing.expectEqual(abi.TransferAction.proceed, try fake.login(config, true));

    fake.verified(Fake.vip, false, .authenticated);
    try std.testing.expectEqual(abi.TransferAction.hold_login, try fake.login(config, true));
    fake.verified(Fake.vip, true, .pending);
    try std.testing.expectEqual(abi.TransferAction.hold_login, try fake.login(config, true));
    fake.verified(Fake.vip, true, .authenticated);
    fake.info.xuid_len = 0;
    try std.testing.expectEqual(abi.TransferAction.hold_login, try fake.login(config, true));
    fake.verified(Fake.vip, true, .authenticated);
    @memcpy(fake.info.xuid[0..5], "Steve");
    fake.info.xuid_len = 5;
    try std.testing.expectEqual(abi.TransferAction.hold_login, try fake.login(config, true));
}

test "turned off, nothing is asked of the host and nobody is refused" {
    var fake: Fake = undefined;
    fake.init();
    fake.info_status = .failed;
    try std.testing.expectEqual(abi.TransferAction.proceed, try fake.login(testConfig(0, .deny, &.{}), true));
}

test "without a decision pointer there is nothing to refuse" {
    var fake: Fake = undefined;
    fake.init();
    fake.created(Fake.now - Fake.day);
    try std.testing.expectEqual(abi.TransferAction.proceed, try fake.login(testConfig(30, .deny, &.{}), false));
    try std.testing.expectEqual(@as(u32, 0), fake.disconnects);
}

test "a host that predates player_account is refused up front" {
    var fake: Fake = undefined;
    fake.init();
    try std.testing.expect(Guard.supported(fake.host()));
    fake.raw.struct_size = @offsetOf(abi.Host, "player_account");
    try std.testing.expect(!Guard.supported(fake.host()));
}

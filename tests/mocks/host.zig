const std = @import("std");
const bifrost = @import("bifrost_plugin");
const abi = bifrost.abi;

pub const Fake = struct {
    info: abi.PlayerInfo = .{},
    account: abi.PlayerAccount = .{},
    info_status: abi.Status = .ok,
    account_status: abi.Status = .ok,
    disconnect_status: abi.Status = .ok,
    info_calls: u32 = 0,
    account_calls: u32 = 0,
    disconnects: u32 = 0,
    reason_buffer: [128]u8 = undefined,
    reason_len: usize = 0,
    raw: abi.Host = undefined,

    pub const now: i64 = 1_700_000_000;
    pub const day = std.time.s_per_day;
    pub const vip: u64 = 2535400000000001;

    pub fn init(self: *Fake) void {
        self.* = .{};
        self.raw.struct_size = @sizeOf(abi.Host);
        self.raw.context = self;
        self.raw.log = log;
        self.raw.player_info = playerInfo;
        self.raw.player_account = playerAccount;
        self.raw.disconnect = disconnect;
        self.info.state.authentication = .authenticated;
        self.info.online = 1;
        const xuid = std.fmt.comptimePrint("{d}", .{vip});
        @memcpy(self.info.xuid[0..xuid.len], xuid);
        self.info.xuid_len = xuid.len;
    }

    pub fn host(self: *Fake) bifrost.Host {
        return .{ .raw = &self.raw };
    }

    fn from(context: *anyopaque) *Fake {
        return @ptrCast(@alignCast(context));
    }

    fn log(_: *anyopaque, _: abi.LogLevel, _: abi.Str) callconv(.c) void {}

    fn playerInfo(context: *anyopaque, _: abi.Player, out: ?*abi.PlayerInfo, _: usize) callconv(.c) abi.Status {
        const self = from(context);
        self.info_calls += 1;
        out.?.* = self.info;
        return self.info_status;
    }

    fn playerAccount(context: *anyopaque, _: abi.Player, out: ?*abi.PlayerAccount, _: usize) callconv(.c) abi.Status {
        const self = from(context);
        self.account_calls += 1;
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

    pub fn created(self: *Fake, seconds: i64) void {
        self.account = .{ .available = abi.account_playfab_created, .playfab_created_s = seconds };
    }
};

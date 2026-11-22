const std = @import("std");
pub const Missing = enum { deny, allow };
pub const Config = struct {
    min_age_s: i64,
    missing: Missing,
    exempt_xuids: []const u64,
    kick: []const u8,

    pub fn deinit(self: Config, gpa: std.mem.Allocator) void {
        gpa.free(self.exempt_xuids);
        gpa.free(self.kick);
    }

    pub fn exempt(self: *const Config, xuid: u64) bool {
        return xuid != 0 and std.sort.binarySearch(u64, self.exempt_xuids, xuid, order) != null;
    }

    fn order(xuid: u64, item: u64) std.math.Order {
        return std.math.order(xuid, item);
    }
};

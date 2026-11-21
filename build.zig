const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk = b.dependency("bifrost", .{ .target = target, .optimize = optimize }).module("bifrost_plugin");
    const imports: []const std.Build.Module.Import = &.{.{ .name = "bifrost_plugin", .module = sdk }};

    const plugin = b.addLibrary(.{
        .name = "AccountGuard",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/plugin.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
            // dladdr finds the library's own directory on Linux and macOS
            .link_libc = target.result.os.tag != .windows,
        }),
    });
    plugin.root_module.addAnonymousImport("plugin.toml", .{ .root_source_file = b.path("plugin.toml") });
    const file = b.fmt("AccountGuard{s}", .{target.result.dynamicLibSuffix()});
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(plugin.getEmittedBin(), .{ .custom = "plugins" }, file).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("config/AccountGuard.toml"), .{ .custom = "plugins" }, "AccountGuard.toml").step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    tests.root_module.addAnonymousImport("example_config", .{ .root_source_file = b.path("config/AccountGuard.toml") });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}

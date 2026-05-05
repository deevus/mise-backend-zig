const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module_opts: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    };
    const exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(module_opts),
    });
    b.installArtifact(exe);
}

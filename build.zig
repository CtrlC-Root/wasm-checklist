const std = @import("std");

pub fn build(b: *std.Build) void {
    // optimization
    const optimize = b.standardOptimizeOption(.{});

    // local target
    const local_target = b.standardTargetOptions(.{});

    // server executable
    const server_executable = b.addExecutable(.{
        .name = "server",
        .root_source_file = b.path("pkg/server/main.zig"),
        .target = local_target,
        .optimize = optimize,
    });

    // XXX
    b.installArtifact(server_executable);
}

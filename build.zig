const std = @import("std");

pub fn build(b: *std.Build) void {
    // optimization
    const optimize = b.standardOptimizeOption(.{});

    // local target
    const local_target = b.standardTargetOptions(.{});

    // webassembly target
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{
            .atomics,
            .bulk_memory,
            // .extended_const, not supported by Safari
            .multivalue,
            .mutable_globals,
            .nontrapping_fptoint,
            .reference_types,
            //.relaxed_simd, not supported by Firefox or Safari
            .sign_ext,
            // observed to cause Error occured during wast conversion :
            // Unknown operator: 0xfd058 in Firefox 117
            //.simd128,
            // .tail_call, not supported by Safari
        }),
    });

    // local server executable
    const server_executable = b.addExecutable(.{
        .name = "server",
        .root_source_file = b.path("pkg/server/main.zig"),
        .target = local_target,
        .optimize = optimize,
    });

    b.installArtifact(server_executable);

    // webassembly client executable
    const client_executable = b.addExecutable(.{
        .name = "client",
        .root_source_file = b.path("pkg/client/main.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    client_executable.entry = .disabled; // no default entry point
    client_executable.rdynamic = true; // expose exported functions
    b.installArtifact(client_executable);

    // web distribution
    // TODO: detect static files instead of hard-coding them here
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("pkg/web/index.html"), "web/index.html").step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("pkg/web/index.js"), "web/index.js").step);
    b.getInstallStep().dependOn(&b.addInstallFile(client_executable.getEmittedBin(), "web/client.wasm").step);
}

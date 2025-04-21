const std = @import("std");

// XXX: once the PR below is merged and included in a stable release we should
// be able to pull in build.zig.zon and use the package version defined there
// https://github.com/ziglang/zig/pull/22907
// const build_data = @import("build.zig.zon");

pub fn fossilVersion(allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"fossil", "describe", "--dirty"},
        // .cwd = "TODO",
        // .cwd_dir = ???,
    });

    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .Exited => |status| std.debug.assert(status == 0),
        .Signal, .Stopped, .Unknown => return error.FossilBroke, // XXX: improve this
    }

    return try allocator.dupe(u8, std.mem.trim(u8, result.stdout, &std.ascii.whitespace));
}

pub fn build(b: *std.Build) void {
    // shared build options
    const build_options = b.addOptions();

    const package_version = std.SemanticVersion.parse("0.1.0") catch unreachable; // XXX: see above for build_data note
    build_options.addOption(std.SemanticVersion, "package_version", package_version);

    // const fossil_describe_command = b.addSystemCommand(&.{"fossil", "describe", "--dirty"});
    // const fossil_describe_output = fossil_describe_command.captureStdOut();

    const fossil_version = fossilVersion(b.allocator) catch unreachable; // XXX: handle this
    build_options.addOption([]const u8, "fossil_version", fossil_version);

    const build_version = std.fmt.allocPrint(b.allocator, "{}-{s}", .{ package_version, fossil_version }) catch unreachable;
    build_options.addOption([]const u8, "version", build_version);

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
    const server_root_source_file = b.path("pkg/server/main.zig");
    const server_executable = b.addExecutable(.{
        .name = "server",
        .root_source_file = server_root_source_file,
        .target = local_target,
        .optimize = optimize,
        .link_libc = true,
    });

    server_executable.root_module.addOptions("build", build_options);
    server_executable.linkSystemLibrary("sqlite3");
    b.installArtifact(server_executable);

    // server unit tests
    const server_unit_tests = b.addTest(.{
        .root_source_file = server_root_source_file,
        .target = local_target,
        .optimize = optimize,
        .link_libc = true,
    });

    server_unit_tests.root_module.addOptions("build", build_options);
    server_unit_tests.linkSystemLibrary("sqlite3");
    const run_server_unit_tests = b.addRunArtifact(server_unit_tests);

    // XXX
    const run_server_executable = b.addRunArtifact(server_executable);
    run_server_executable.step.dependOn(b.getInstallStep());

    // if (b.args) |args| {
    //     run_server_executable.addArgs(args);
    // }

    // target to run server
    const run_server_step = b.step("run-server", "run data store service");
    run_server_step.dependOn(&run_server_executable.step);

    // application webassembly executable
    const wasm_zts_dependency = b.dependency("zts", .{
        .target = wasm_target,
        .optimize = optimize,
    });

    const application_root_source_file = b.path("pkg/application/main.zig");
    const application_executable = b.addExecutable(.{
        .name = "application",
        .root_source_file = application_root_source_file,
        .target = wasm_target,
        .optimize = optimize,
    });

    application_executable.root_module.addOptions("build", build_options);
    application_executable.root_module.addImport("zts", wasm_zts_dependency.module("zts"));

    application_executable.entry = .disabled; // no default entry point
    application_executable.rdynamic = true; // expose exported functions
    b.installArtifact(application_executable);

    // application unit tests
    const application_unit_tests = b.addTest(.{
        .root_source_file = application_root_source_file,
        .target = local_target,
        .optimize = optimize,
    });

    application_unit_tests.root_module.addOptions("build", build_options);
    application_unit_tests.root_module.addImport("zts", wasm_zts_dependency.module("zts"));

    const run_application_unit_tests = b.addRunArtifact(application_unit_tests);

    // web distribution
    // TODO: detect static files instead of hard-coding them here
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("pkg/web/index.html"), "web/index.html").step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("pkg/web/application.js"), "web/application.js").step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("pkg/web/index.js"), "web/index.js").step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("pkg/web/worker.js"), "web/worker.js").step);
    b.getInstallStep().dependOn(&b.addInstallFile(application_executable.getEmittedBin(), "web/application.wasm").step);

    // target to run tests
    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_server_unit_tests.step);
    test_step.dependOn(&run_application_unit_tests.step);
}

const builtin = @import("builtin");
const std = @import("std");

const models = @import("models.zig");
const store = @import("store.zig");

var signal_interrupt: std.Thread.ResetEvent = .{};
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn signal_handle(signal: c_int) callconv(.C) void {
    switch (signal) {
        std.posix.SIG.INT => signal_interrupt.set(),
        else => {
            std.debug.print("unhandled signal: {}\n", .{signal});
        },
    }
}

fn processModelRequest(
    comptime Model: type,
    request_allocator: std.mem.Allocator,
    model_allocator: std.mem.Allocator,
    model_store: *store.modelMemoryStore(Model),
    request: *std.http.Server.Request,
) !void {
    const model_prefix = try std.fmt.allocPrint(request_allocator, "/{s}", .{Model.name});
    defer request_allocator.free(model_prefix);

    std.debug.assert(std.mem.startsWith(u8, request.head.target, model_prefix));
    const target_without_prefix = std.mem.trimLeft(u8, request.head.target[model_prefix.len..], "/"); // XXX

    // collection request
    if (target_without_prefix.len == 0) {
        switch (request.head.method) {
            // TODO: get all instances
            .GET => {
                try request.respond("TODO retrieve collection", .{});
            },
            // create a new instance
            .POST => {
                // XXX: make this a runtime error
                std.debug.assert(std.mem.eql(u8, request.head.content_type.?, "application/json"));

                // parse request body as model data
                const request_reader = try request.reader();
                var json_reader = std.json.reader(request_allocator, request_reader);
                defer json_reader.deinit();

                const data_parsed = try std.json.parseFromTokenSource(
                    Model.Data,
                    request_allocator,
                    &json_reader,
                    .{},
                );

                defer data_parsed.deinit();

                // create an instance of the model
                const instance_id = try model_store.create(model_allocator, &data_parsed.value);
                std.debug.print("{s}: created instance: {d}\n", .{Model.name, instance_id});

                // inform the client of the new instance
                const response = try std.fmt.allocPrint(request_allocator, "{d}", .{ instance_id });
                defer request_allocator.free(response);

                try request.respond(response, .{
                    .status = std.http.Status.created,
                });
            },
            else => {
                try request.respond("Method Not Allowed", .{
                    .status = std.http.Status.method_not_allowed,
                });
            }
        }
    // instance request
    } else {
        const instance_id = try std.fmt.parseInt(Model.Id, target_without_prefix, 10);
        switch (request.head.method) {
            // get instance
            .GET => {
                if (model_store.retrieve(instance_id)) |data| {
                    std.debug.print("{s}: retrieved instance: {d}\n", .{Model.name, instance_id});
                    const response = try std.json.stringifyAlloc(request_allocator, data, .{});
                    defer request_allocator.free(response);

                    try request.respond(response, .{
                        .extra_headers = &.{
                            .{ .name = "Content-Type", .value = "application/json" },
                        },
                    });
                } else {
                    std.debug.print("{s}: instance not found: {d}\n", .{Model.name, instance_id});
                    try request.respond("Not Found", .{
                        .status = std.http.Status.not_found,
                    });
                }
            },
            // update instance
            .PUT => {
                // XXX: make this a runtime error
                std.debug.assert(std.mem.eql(u8, request.head.content_type.?, "application/json"));

                // parse request body as model data
                const request_reader = try request.reader();
                var json_reader = std.json.reader(request_allocator, request_reader);
                defer json_reader.deinit();

                const data_parsed = try std.json.parseFromTokenSource(
                    Model.Data,
                    request_allocator,
                    &json_reader,
                    .{},
                );

                defer data_parsed.deinit();

                // update the instance
                const updated_instance_id = try model_store.update(model_allocator, instance_id, &data_parsed.value);
                if (updated_instance_id) |_| {
                    std.debug.print("{s}: instance updated: {d}\n", .{Model.name, instance_id});
                    try request.respond("", .{
                        .status = std.http.Status.no_content,
                    });
                } else {
                    std.debug.print("{s}: instance not found: {d}\n", .{Model.name, instance_id});
                    try request.respond("Not Found", .{
                        .status = std.http.Status.not_found,
                    });
                }
            },
            // delete instance
            .DELETE => {
                if (model_store.destroy(model_allocator, instance_id)) |_| {
                    std.debug.print("{s}: destroyed instance: {d}\n", .{Model.name, instance_id});
                    try request.respond("", .{
                        .status = std.http.Status.no_content,
                    });
                } else {
                    std.debug.print("{s}: instance not found: {d}\n", .{Model.name, instance_id});
                    try request.respond("Not Found", .{
                        .status = std.http.Status.not_found,
                    });
                }
            },
            else => {
                try request.respond("Method Not Allowed", .{
                    .status = std.http.Status.method_not_allowed,
                });
            }
        }
    }
}

fn processRequest(
    allocator: std.mem.Allocator,
    data: *store.MemoryDataStore,
    request: *std.http.Server.Request,
) !void {
    // TODO: compile time generate code for each model? or processModelRequest() can raise error for not matching?
    if (std.mem.startsWith(u8, request.head.target, "/user/") or std.mem.eql(u8, request.head.target, "/user")) {
        try processModelRequest(models.User, allocator, data.allocator, &data.users, request);
    }
    else if (std.mem.startsWith(u8, request.head.target, "/checklist/") or std.mem.eql(u8, request.head.target, "/checklist")) {
        try processModelRequest(models.Checklist, allocator, data.allocator, &data.checklists, request);
    }
    else {
        try request.respond("Not Found", .{
            .status = std.http.Status.not_found,
        });
    }
}

fn processClient(
    allocator: std.mem.Allocator,
    data: *store.MemoryDataStore,
    connection: *std.net.Server.Connection,
) !void {
    var buffer: [65535]u8 = undefined; // XXX: allocate fixed buffer
    var client = std.http.Server.init(connection.*, &buffer);

    while (client.state == .ready) {
        // stop running if we receive an interrupt signal
        if (signal_interrupt.isSet()) {
            break;
        }

        var request = client.receiveHead() catch |err| switch (err) {
            std.http.Server.ReceiveHeadError.HttpConnectionClosing => break,
            else => return err,
        };

        // XXX: use an arena allocator?
        processRequest(allocator, data, &request) catch {
            // XXX: include error message
            try request.respond("uh oh", .{
                .status = std.http.Status.internal_server_error,
            });
        };
    }
}

pub fn main() !void {
    // create an allocator
    // https://ziglang.org/download/0.14.0/release-notes.html#SmpAllocator
    const allocator, const allocator_is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };

    defer if (allocator_is_debug) {
        const result = debug_allocator.deinit();
        std.debug.assert(result == .ok);
    };

    // initialize data store
    var data: store.MemoryDataStore = .{};
    data.init(allocator);

    defer data.deinit();

    // install signal handlers
    const signal_action = std.posix.Sigaction{
        .handler = .{ .handler = signal_handle },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &signal_action, null);

    // create the server socket and listen for incoming connections
    const listen_address = try std.net.Address.parseIp("127.0.0.1", 8080);
    var server = try std.net.Address.listen(listen_address, .{
        .reuse_address = true,
        .force_nonblocking = true,
    });

    defer server.deinit();

    // server processing loop
    signal_interrupt.reset();
    while (true) {
        // stop running if we receive an interrupt signal
        if (signal_interrupt.isSet()) {
            break;
        }

        // accept and process a client connection
        // XXX: make this non-blocking
        var client_connection = server.accept() catch |err| switch (err) {
            std.posix.AcceptError.WouldBlock => {
                std.time.sleep(1000 * 250);
                continue;
            },
            else => return err,
        };

        try processClient(allocator, &data, &client_connection);
    }

    // XXX: adjust exit status based on signal?
}

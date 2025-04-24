// better way: https://matklad.github.io/2025/03/19/comptime-zig-orm.html

// Zig
const builtin = @import("builtin");
const std = @import("std");

// first-party
const model = @import("model.zig");
const store = @import("store.zig");

// testing related import processing
test {
    // note: this only sees public declarations so the only way to include
    // tests that are not otherwise reachable by following those is to
    // explicitly use the related struct which contains it
    std.testing.refAllDeclsRecursive(@This());
}

// Signal handler sets this thread event to notify main thread the process has
// received an interrupt signal and it should quit cleanly.
var signal_interrupt: std.Thread.ResetEvent = .{};

// Debug allocator for debug builds.
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

// Handle signals.
pub fn signal_handle(signal: c_int) callconv(.C) void {
    switch (signal) {
        std.posix.SIG.INT => signal_interrupt.set(),
        else => {
            std.debug.print("unhandled signal: {}\n", .{signal});
        },
    }
}

// XXX
fn processModelRequest(
    comptime Model: type,
    allocator: std.mem.Allocator,
    datastore: *store.DataStore,
    request: *std.http.Server.Request,
) !void {
    const model_prefix = std.fmt.comptimePrint("/{s}", .{Model.name});
    std.debug.assert(std.mem.startsWith(u8, request.head.target, model_prefix));
    const target_without_prefix = std.mem.trimLeft(u8, request.head.target[model_prefix.len..], "/"); // XXX

    // collection request
    if (target_without_prefix.len == 0) {
        switch (request.head.method) {
            // get all instances
            .GET => {
                const instances = try datastore.retrieveAll(Model, allocator);
                defer {
                    for (instances) |instance| {
                        instance.deinit(allocator);
                    }

                    allocator.free(instances);
                }

                const instances_data: []*const Model.Data = try allocator.alloc(*const Model.Data, instances.len);
                defer allocator.free(instances_data);

                for (0..instances.len) |index| {
                    instances_data[index] = &instances[index].data;
                }

                const response = try std.json.stringifyAlloc(allocator, instances_data, .{});
                defer allocator.free(response);

                try request.respond(response, .{
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "application/json" },
                        // CORS
                        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                        .{ .name = "Access-Control-Allow-Methods", .value = "*" },
                        .{ .name = "Access-Control-Allow-Headers", .value = "*" },
                    },
                });
            },
            // create a new instance
            .POST => {
                // XXX: make this a runtime error
                std.debug.assert(std.mem.eql(u8, request.head.content_type.?, "application/json"));

                // parse request body as model data
                const request_reader = try request.reader();
                const partial_data = try Model.parseJsonPartialData(allocator, request_reader);
                defer Model.deinitPartialData(&partial_data, allocator);

                // create an instance of the model
                const instance_id = try datastore.create(Model, allocator, &partial_data);
                std.debug.print("{s}: created instance: {d}\n", .{ Model.name, instance_id });

                // inform the client of the new instance
                const response = try std.fmt.allocPrint(allocator, "{d}", .{instance_id});
                defer allocator.free(response);

                try request.respond(response, .{
                    .status = std.http.Status.created,
                    .extra_headers = &.{
                        // CORS
                        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                        .{ .name = "Access-Control-Allow-Methods", .value = "*" },
                        .{ .name = "Access-Control-Allow-Headers", .value = "*" },
                    },
                });
            },
            else => {
                try request.respond("Method Not Allowed", .{
                    .status = std.http.Status.method_not_allowed,
                });
            },
        }
        // instance request
    } else {
        const instance_id = try std.fmt.parseInt(Model.IdFieldValue, target_without_prefix, 10);
        switch (request.head.method) {
            // get instance
            .GET => {
                const instance = datastore.retrieve(Model, allocator, instance_id) catch |err| switch (err) {
                    error.InstanceNotFound => {
                        std.debug.print("{s}: instance not found: {d}\n", .{ Model.name, instance_id });
                        try request.respond("Not Found", .{
                            .status = std.http.Status.not_found,
                        });

                        return;
                    },
                    else => return err,
                };

                defer instance.deinit(allocator);

                std.debug.print("{s}: retrieved instance: {d}\n", .{ Model.name, instance_id });
                const response = try std.json.stringifyAlloc(allocator, instance.data, .{});
                defer allocator.free(response);

                try request.respond(response, .{
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "application/json" },
                        // CORS
                        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                        .{ .name = "Access-Control-Allow-Methods", .value = "*" },
                        .{ .name = "Access-Control-Allow-Headers", .value = "*" },
                    },
                });
            },
            // update instance
            .PATCH => {
                // XXX: make this a runtime error
                std.debug.assert(std.mem.eql(u8, request.head.content_type.?, "application/json"));

                // parse request body as model data
                const request_reader = try request.reader();
                const partial_data = try Model.parseJsonPartialData(allocator, request_reader);
                defer Model.deinitPartialData(&partial_data, allocator);

                // update the instance
                datastore.update(Model, allocator, instance_id, &partial_data) catch |err| switch (err) {
                    error.ExecuteStatement => {
                        std.debug.print("{s}: instance not found: {d}\n", .{ Model.name, instance_id });
                        try request.respond("Not Found", .{
                            .status = std.http.Status.not_found,
                        });

                        return;
                    },
                    else => return err,
                };

                std.debug.print("{s}: instance updated: {d}\n", .{ Model.name, instance_id });
                try request.respond("", .{
                    .status = std.http.Status.no_content,
                    .extra_headers = &.{
                        // CORS
                        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                        .{ .name = "Access-Control-Allow-Methods", .value = "*" },
                        .{ .name = "Access-Control-Allow-Headers", .value = "*" },
                    },
                });
            },
            // delete instance
            .DELETE => {
                datastore.delete(Model, allocator, instance_id) catch |err| switch (err) {
                    error.ExecuteStatement => {
                        std.debug.print("{s}: instance not found: {d}\n", .{ Model.name, instance_id });
                        try request.respond("Not Found", .{
                            .status = std.http.Status.not_found,
                        });

                        return;
                    },
                    else => return err,
                };

                std.debug.print("{s}: destroyed instance: {d}\n", .{ Model.name, instance_id });
                try request.respond("", .{
                    .status = std.http.Status.no_content,
                    .extra_headers = &.{
                        // CORS
                        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                        .{ .name = "Access-Control-Allow-Methods", .value = "*" },
                        .{ .name = "Access-Control-Allow-Headers", .value = "*" },
                    },
                });
            },
            else => {
                try request.respond("Method Not Allowed", .{
                    .status = std.http.Status.method_not_allowed,
                });
            },
        }
    }
}

// XXX
fn processRequest(
    allocator: std.mem.Allocator,
    datastore: *store.DataStore,
    request: *std.http.Server.Request,
) !void {
    // options pre-flight requests
    if (request.head.method == .OPTIONS) {
        try request.respond("", .{
            .extra_headers = &.{
                // CORS
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                .{ .name = "Access-Control-Allow-Methods", .value = "*" },
                .{ .name = "Access-Control-Allow-Headers", .value = "*" },
            },
        });

        return;
    }

    // model endpoints
    const model_types: [3]type = .{ model.User, model.Checklist, model.Item };
    inline for (model_types) |model_type| {
        const leaf_url = std.fmt.comptimePrint("/{s}", .{model_type.name});
        const prefix_url = std.fmt.comptimePrint("/{s}/", .{model_type.name});

        if (std.mem.startsWith(u8, request.head.target, prefix_url) or std.mem.eql(u8, request.head.target, leaf_url)) {
            try processModelRequest(model_type, allocator, datastore, request);
        }
    } else {
        try request.respond("Not Found", .{
            .status = std.http.Status.not_found,
        });
    }
}

// XXX
fn processClient(
    allocator: std.mem.Allocator,
    datastore: *store.DataStore,
    connection: *std.net.Server.Connection,
) !void {
    var buffer: [65535]u8 = undefined; // XXX: allocate fixed buffer
    var client = std.http.Server.init(connection.*, &buffer);

    while (client.state == .ready) {
        // stop running if we receive an interrupt signal
        if (signal_interrupt.isSet()) {
            break;
        }

        // TODO: make this non-blocking
        var request = client.receiveHead() catch |err| switch (err) {
            std.http.Server.ReceiveHeadError.HttpConnectionClosing => break,
            else => return err,
        };

        std.debug.print("{s}: {s}\n", .{ @tagName(request.head.method), request.head.target });

        // XXX: use an arena allocator?
        processRequest(allocator, datastore, &request) catch {
            // XXX: include error message
            try request.respond("uh oh", .{
                .status = std.http.Status.internal_server_error,
            });
        };

        // TODO: close connection after processing one request so we don't get
        // blocked waiting for the next client.receiveHead() if the client is
        // keeping the connection alive but not sending more requests
        connection.stream.close();
        break;
    }
}

// Application entry point.
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

    // initialize the data store
    var datastore: store.DataStore = .{};
    try datastore.init("./data.db");
    defer datastore.deinit();

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
    std.debug.print("Listening for connections on {}\n", .{listen_address});
    signal_interrupt.reset();
    while (true) {
        // stop running if we receive an interrupt signal
        if (signal_interrupt.isSet()) {
            break;
        }

        // accept and process a client connection
        var client_connection = server.accept() catch |err| switch (err) {
            std.posix.AcceptError.WouldBlock => {
                std.time.sleep(1000 * 250);
                continue;
            },
            else => return err,
        };

        try processClient(allocator, &datastore, &client_connection);
    }

    // XXX: adjust exit status based on signal?
}

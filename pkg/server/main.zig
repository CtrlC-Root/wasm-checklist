// Zig
const builtin = @import("builtin");
const std = @import("std");

// first-party
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
fn processClient(
    allocator: std.mem.Allocator,
    datastore: *store.DataStore,
    connection: *std.net.Server.Connection,
) !void {
    _ = allocator; // PLACEHOLDER
    _ = datastore; // PLACEHOLDER

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

        // TODO: placeholder
        try request.respond("todo", .{
            .status = std.http.Status.ok,
        });

        // XXX: use an arena allocator?
        // processRequest(allocator, data, &request) catch {
        //     // XXX: include error message
        //     try request.respond("uh oh", .{
        //         .status = std.http.Status.internal_server_error,
        //     });
        // };

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
    try datastore.init("./checklist.db");
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

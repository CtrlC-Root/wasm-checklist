const std = @import("std");

var signal_interrupt: std.Thread.ResetEvent = .{};

pub fn signal_handle(signal: c_int) callconv(.C) void {
    switch (signal) {
        std.posix.SIG.INT => signal_interrupt.set(),
        else => {
            std.debug.print("unhandled signal: {}\n", .{signal});
        },
    }
}

fn process_client(connection: std.net.Server.Connection) !void {
    var buffer: [65535]u8 = undefined;
    var client = std.http.Server.init(connection, &buffer);

    while (client.state == .ready) {
        // stop running if we receive an interrupt signal
        if (signal_interrupt.isSet()) {
            break;
        }

        // XXX: make this non-blocking
        var request = client.receiveHead() catch |err| switch (err) {
            std.http.Server.ReceiveHeadError.HttpConnectionClosing => break,
            else => return err,
        };

        _ = try request.reader();
        try request.respond("Hello, world!", .{});
    }
}

pub fn main() !void {
    // install signal handlers
    const signal_action = std.posix.Sigaction{
        .handler = .{ .handler = signal_handle },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &signal_action, null);

    // create the server socket and listen for incoming connections
    const listen_address = try std.net.Address.parseIp("127.0.0.1", 8080);
    var server = try std.net.Address.listen(listen_address, .{ .reuse_address = true });
    defer server.deinit();

    // server processing loop
    signal_interrupt.reset();
    while (true) {
        // stop running if we receive an interrupt signal
        if (signal_interrupt.isSet()) {
            break;
        }

        // accept and process a client connection
        const client_connection = try server.accept();
        try process_client(client_connection);
    }

    // XXX: adjust exit status based on signal?
}

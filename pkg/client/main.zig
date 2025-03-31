// zig
const builtin = @import("builtin");
const std = @import("std");

// first-party
const build = @import("build");
const memory = @import("memory.zig");
const http = @import("http.zig");

const PackedByteSlice = memory.PackedByteSlice;

// testing related import processing
test {
    std.testing.refAllDecls(@This());
}

// Client state.
const Client = struct {
    const Self = @This();

    allocator: std.mem.Allocator = undefined,
};

// Global client state singleton.
var client: Client = undefined;

// Initialize internal client state.
export fn initialize() void {
    const allocator: std.mem.Allocator = allocator: {
        // XXX: use something different for WASI operating system?
        if (builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64) {
            // https://ziglang.org/documentation/0.14.0/std/#std.heap.wasm_allocator
            break :allocator std.heap.wasm_allocator;
        }

        // https://ziglang.org/download/0.14.0/release-notes.html#SmpAllocator
        break :allocator switch (builtin.mode) {
            // TODO: use std.heap.DebugAllocator(.{}).allocator() for Debug and ReleaseSafe
            // https://ziglang.org/documentation/0.14.0/std/#std.heap.debug_allocator.DebugAllocator
            .Debug, .ReleaseSafe => std.heap.smp_allocator,

            // https://ziglang.org/documentation/0.14.0/std/#std.heap.smp_allocator
            .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
        };
    };

    client = .{
        .allocator = allocator,
    };
}

// Finalize internal client state.
export fn finalize() void {
    // TODO: debug allocator deinit() if necessary
}

// Allocate memory.
export fn allocateBytes(size: usize) PackedByteSlice {
    const data = client.allocator.alloc(u8, size) catch @panic("out of memory");
    return PackedByteSlice.init(data);
}

// Free memory.
export fn freeBytes(slice: PackedByteSlice) void {
    std.debug.assert(slice.ptr != 0 or slice.len != 0); // XXX: can slice.ptr ever be zero?
    client.allocator.free(slice.native());
}

// XXX: internal invoke
fn invokeInternal(trace_id: u32, request: http.Request) !http.Response {
    var arena = std.heap.ArenaAllocator.init(client.allocator);
    defer arena.deinit();
    const request_allocator = arena.allocator();

    // create a response builder
    var response_builder: http.ResponseBuilder = undefined;
    response_builder.init(request_allocator);
    // defer response_builder.deinit();

    // XXX: set response trace id header
    // TODO: retrieve the trace id from the incoming request instead
    const trace_id_value = try std.fmt.allocPrint(request_allocator, "{d}", .{ trace_id });
    // defer request_allocator.free(trace_id_value);
    try response_builder.setHeader("X-Trace-Id", trace_id_value);

    // parse the request uri and resolve the raw request path
    const request_uri = try std.Uri.parse(request.url);
    const request_path = try request_uri.path.toRawMaybeAlloc(request_allocator);

    // client version
    if (std.mem.eql(u8, request_path, "/app/version")) {
        response_builder.setStatus(.ok);
        try response_builder.setHeader("Content-Type", "text/plain");
        try response_builder.setContent(build.version);

        return try response_builder.toOwned(client.allocator);
    }

    // generic fallthrough for unknown routes
    response_builder.setStatus(.not_found);
    return try response_builder.toOwned(client.allocator);
}

// XXX: client error details
const ClientError = struct {
    const Self = @This();

    id: []const u8,
};

// XXX: can we discover these from invokeInternal() function signature?
const InvokeArguments = struct {
    traceId: u32, // XXX: note JS variable naming convention here
    httpRequest: http.Request,
};

// XXX: can we discover these from invokeInternal() function signature?
const InvokeResult = union(enum) {
    @"error": ClientError,
    httpResponse: http.Response,
};

// Public interface invoke wrapper.
export fn invoke(data: PackedByteSlice) PackedByteSlice {
    return invoke: {
        // deserialize arguments
        const arguments_parsed = std.json.parseFromSlice(
            InvokeArguments,
            client.allocator,
            data.native(),
            .{},
        ) catch |err| break :invoke err;
        defer arguments_parsed.deinit();

        // process request into response
        const response: http.Response = invokeInternal(
            arguments_parsed.value.traceId,
            arguments_parsed.value.httpRequest,
        ) catch |err| break :invoke err;
        defer response.deinit(client.allocator);

        // serialize http response
        const response_bytes = std.json.stringifyAlloc(
            client.allocator,
            InvokeResult{ .httpResponse = response },
            .{},
        ) catch |err| break :invoke err;
        errdefer client.allocator.free(response_bytes);

        // return response data
        break :invoke PackedByteSlice.init(response_bytes);
    } catch |err| {
        // TODO: handle out of memory before we try and allocate more memory

        // XXX: there is probably a better way to identify the error
        // const err_type = @TypeOf(err);
        // const err_type_info = @typeInfo(err_type);
        // @compileLog(@typeInfo(@TypeOf(specific_error)));
        // @compileLog(@typeName(@TypeOf(err)));
        const client_error: ClientError = .{
            .id = @errorName(err),
        };

        // serialize client error
        const client_error_bytes = std.json.stringifyAlloc(
            client.allocator,
            InvokeResult{ .@"error" = client_error },
            .{},
        ) catch @panic("failed to serialize ClientError value");
        return PackedByteSlice.init(client_error_bytes);
    };
}

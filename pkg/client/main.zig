const builtin = @import("builtin");
const std = @import("std");
const zts = @import("zts");

const http = @import("http.zig");

test {
    std.testing.refAllDecls(@This());
}

// Packed slice representation.
fn PackedSlice(comptime T: type) type {
    const PackedInt = @Type(.{
        .int = .{
            .bits = @typeInfo(usize).int.bits * 2,
            .signedness = @typeInfo(usize).int.signedness,
        },
    });

    return packed struct(PackedInt) {
        const Self = @This();

        ptr: usize,
        len: usize,

        const empty: Self = .{ .ptr = 0, .len = 0 };

        fn init(data: []const T) Self {
            return .{
                .ptr = @intFromPtr(data.ptr),
                .len = data.len,
            };
        }

        fn native(self: Self) []const T {
            return @as([*]T, @ptrFromInt(self.ptr))[0..self.len];
        }
    };
}

// Packed byte slice.
const PackedByteSlice = PackedSlice(u8);

// XXX
const ClientError = struct {
    const Self = @This();

    id: []const u8,
};

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
export fn allocBytes(size: usize) PackedByteSlice {
    const data = client.allocator.alloc(u8, size) catch @panic("out of memory");
    return PackedByteSlice.init(data);
}

// Free memory.
export fn freeBytes(slice: PackedByteSlice) void {
    std.debug.assert(slice.ptr != 0 or slice.len != 0); // XXX: can slice.ptr ever be zero?
    client.allocator.free(slice.native());
}

// XXX
fn invokeInternal(trace_id: u32, request: http.Request) !http.Response {
    // TODO
    _ = trace_id;
    _ = request;

    return error.NotImplemented;
}

// XXX
const InvokeArguments = struct {
    traceId: u32, // XXX: note JS variable naming convention here
    httpRequest: http.Request,
};

const InvokeResult = union(enum) {
    @"error": ClientError,
    httpResponse: http.Response,
};

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
        // TODO: defer response.deinit(client.allocator);

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

// SAMPLE PAGE TEMPLATE TEST
export fn sample_page() PackedByteSlice {
    const template = @embedFile("templates/dashboard.html");

    var buffer: std.ArrayListUnmanaged(u8) = .{};

    const writer = buffer.writer(client.allocator);
    const output = output: {
        zts.writeHeader(template, writer) catch |err| break :output err;
        zts.print(template, "checklist-list-start", .{}, writer) catch |err| break :output err;
        zts.print(template, "checklist-list-end", .{}, writer) catch |err| break :output err;
        zts.print(template, "footer", .{}, writer) catch |err| break :output err;

        break :output buffer.toOwnedSlice(client.allocator);
    } catch {
        buffer.deinit(client.allocator);
        return .empty;
    };

    return PackedByteSlice.init(output);
}

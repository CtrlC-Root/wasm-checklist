const builtin = @import("builtin");
const std = @import("std");

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

// Allocate memory.
export fn allocBytes(size: usize) PackedByteSlice {
    const data = client.allocator.alloc(u8, size) catch @panic("out of memory");
    return PackedByteSlice.init(data);
}

// Free memory.
export fn freeBytes(slice: PackedByteSlice) void {
    std.debug.assert(slice.ptr != 0 or slice.len != 0);
    client.allocator.free(slice.native());
}

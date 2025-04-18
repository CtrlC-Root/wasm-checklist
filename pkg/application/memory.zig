const std = @import("std");

// Packed slice representation.
pub fn PackedSlice(comptime T: type) type {
    const packed_int_type = @Type(.{
        .int = .{
            .bits = @typeInfo(usize).int.bits * 2,
            .signedness = @typeInfo(usize).int.signedness,
        },
    });

    return packed struct(packed_int_type) {
        const Self = @This();
        const PackedValue = packed_int_type;

        ptr: usize,
        len: usize,

        pub const empty: Self = .{ .ptr = 0, .len = 0 };

        pub fn init(data: []const T) Self {
            return .{
                .ptr = @intFromPtr(data.ptr),
                .len = data.len,
            };
        }

        pub fn native(self: Self) []const T {
            return @as([*]T, @ptrFromInt(self.ptr))[0..self.len];
        }
    };
}

// Packed byte slice.
pub const PackedByteSlice = PackedSlice(u8);

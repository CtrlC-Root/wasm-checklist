const std = @import("std");

pub fn model(comptime modelName: []const u8, comptime ModelData: type) type {
    return struct {
        const Self = @This();
        pub const Id = u32;
        pub const Data = ModelData;
        pub const name = modelName;

        id: Self.Id = undefined,
        data: *Self.Data = undefined,

        pub fn init(self: *Self, allocator: std.mem.Allocator, id: Self.Id, data: *const Self.Data) !void {
            const data_owned = try allocator.create(Self.Data);
            errdefer allocator.destroy(data_owned);

            data_owned.* = data.*;
            self.* = .{
                .id = id,
                .data = data_owned,
            };
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self.data);
        }
    };
}

pub const User = model("user", struct {
    display_name: []u8 = undefined,
});

pub const Checklist = model("checklist", struct {
    owner_user_id: User.Id = undefined,
    title: []u8 = undefined,
});

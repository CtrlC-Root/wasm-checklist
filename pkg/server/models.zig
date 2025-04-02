const std = @import("std");

const Timestamp = i64; // std.time.timestamp() return value

pub fn Model(comptime modelName: []const u8, comptime ModelData: type) type {
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

            try data_owned.init(allocator, data);
            errdefer data_owned.deinit();

            self.* = .{
                .id = id,
                .data = data_owned,
            };
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            self.data.deinit(allocator);
            allocator.destroy(self.data);
        }
    };
}

pub const User = Model("user", struct {
    const Self = @This();

    display_name: []const u8 = undefined,

    pub fn init(self: *Self, allocator: std.mem.Allocator, existing: *const Self) !void {
        const display_name = try allocator.dupe(u8, existing.display_name);
        errdefer allocator.free(display_name);

        self.* = .{
            .display_name = display_name,
        };
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.display_name);
    }
});

pub const Checklist = Model("checklist", struct {
    const Self = @This();

    title: []const u8 = undefined,

    created_by_user_id: User.Id = undefined,
    created_on_timestamp: Timestamp = undefined,

    pub fn init(self: *Self, allocator: std.mem.Allocator, existing: *const Self) !void {
        const title = try allocator.dupe(u8, existing.title);
        errdefer allocator.free(title);

        self.* = .{
            .title = title,
            .created_by_user_id = existing.created_by_user_id,
            .created_on_timestamp = existing.created_on_timestamp,
        };
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
    }
});

test "basic model usage" {
    var user: User = undefined;
    try user.init(std.testing.allocator, 0, &.{
        .display_name = "John Doe",
    });

    defer user.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, user.id);
    try std.testing.expectEqualSlices(u8, "John Doe", user.data.display_name);
}

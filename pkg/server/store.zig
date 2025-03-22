const std = @import("std");
const models = @import("models.zig");

pub fn modelMemoryStore(comptime Model: type) type {
    return struct {
        const Self = @This();
        const Instance = Model;
        const Collection = std.AutoHashMapUnmanaged(Model.Id, Model);

        next_id: Instance.Id = undefined,
        instances: Collection = undefined,

        pub fn init(self: *Self) void {
            self.* = .{
                .next_id = 0,
                .instances = .empty,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var instance_iterator = self.instances.valueIterator();
            while (instance_iterator.next()) |instance| {
                instance.deinit(allocator);
            }

            self.instances.deinit(allocator);
        }

        pub fn create(self: *Self, allocator: std.mem.Allocator, data: *const Model.Data) !Self.Instance.Id {
            var instance: Self.Instance = .{};
            try instance.init(allocator, self.next_id, data);
            errdefer instance.deinit(allocator);

            try self.instances.putNoClobber(allocator, instance.id, instance);
            self.next_id = self.next_id + 1;

            return instance.id;
        }

        pub fn retrieve(self: *Self, id: Self.Instance.Id) ?*const Model.Data {
            return if (self.instances.getPtr(id)) |instance| instance.data else null;
        }

        pub fn update(self: *Self, allocator: std.mem.Allocator, id: Self.Instance.Id, data: *const Model.Data) !?Self.Instance.Id {
            const instance = self.instances.getPtr(id) orelse return null;

            const existing_data = instance.data;
            instance.data = try allocator.create(Model.Data);
            instance.data.* = data.*;
            allocator.destroy(existing_data);

            return instance.id;
        }

        pub fn destroy(self: *Self, allocator: std.mem.Allocator, id: Self.Instance.Id) ?Self.Instance.Id {
            if (self.instances.fetchRemove(id)) |entry| {
                entry.value.deinit(allocator);
                return entry.key;
            } else {
                return null;
            }
        }
    };
}

pub const MemoryDataStore = struct {
    const Self = @This();
    const UserStore = modelMemoryStore(models.User);
    const ChecklistStore = modelMemoryStore(models.Checklist);

    allocator: std.mem.Allocator = undefined,
    users: UserStore = undefined,
    checklists: ChecklistStore = undefined,

    pub fn init(self: *Self, allocator: std.mem.Allocator) void {
        self.*.allocator = allocator;
        self.users.init();
        self.checklists.init();
    }

    pub fn deinit(self: *Self) void {
        self.users.deinit(self.allocator);
        self.checklists.deinit(self.allocator);
    }
};

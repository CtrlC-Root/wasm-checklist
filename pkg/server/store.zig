const std = @import("std");
const model = @import("model.zig");

pub fn ModelStore(comptime InnerModel: type) type {
    return struct {
        const Self = @This();
        const Model = InnerModel;
        const InstanceHashMap = std.AutoHashMapUnmanaged(Self.Model.Id, Self.Model);

        currentId: Model.Id = 0,
        instances: Self.InstanceHashMap = .empty,

        pub const empty: Self = .{};

        pub fn create(
            self: *Self,
            allocator: std.mem.Allocator,
            data: *const Self.Model.Data,
        ) !Self.Model.Id {
            // determine the next available instance id
            const initialId = self.currentId;
            while (self.instances.contains(self.currentId)) {
                self.currentId += 1;
                if (self.currentId == initialId) {
                    return error.InstanceIdsExhausted;
                }
            }

            var instance: Self.Model = undefined;
            try instance.init(allocator, self.currentId, data);
            errdefer instance.deinit(allocator);

            try self.instances.putNoClobber(allocator, instance.id, instance);
            return instance.id;
        }

        pub fn retrieve(
            self: Self,
            id: Self.Model.Id,
        ) !*Self.Model {
            const entry = self.instances.getEntry(id) orelse return error.InvalidInstanceId;
            return entry.value_ptr;
        }

        pub fn delete(
            self: *Self,
            allocator: std.mem.Allocator,
            id: Self.Model.Id,
        ) !void {
            const pair = self.instances.fetchRemove(id) orelse return error.InvalidInstanceId;
            pair.value.deinit(allocator);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var instance_iterator = self.instances.iterator();
            while (instance_iterator.next()) |entry| {
                entry.value_ptr.*.deinit(allocator);
            }

            self.instances.deinit(allocator);
        }
    };
}

pub const UserStore = ModelStore(model.User);
pub const ChecklistStore = ModelStore(model.Checklist);

test "checklist memory store usage" {
    var checklist_store: ChecklistStore = .empty;
    defer checklist_store.deinit(std.testing.allocator);

    // TODO
}

// XXX
pub const DataStore = struct {
    const Self = @This();

    pub const CreateData = union(enum) {
        user: *const model.User.Data,
        checklist: *const model.Checklist.Data,
    };

    pub const UpdateData = union(enum) {
        user: struct {
            id: model.User.Id,
            updates: *const model.User.DataUpdates,
        },
        checklist: struct {
            id: model.Checklist.Id,
            updates: *const model.Checklist.DataUpdates,
        },
    };

    pub const DeleteData = union(enum) {
        user: model.User.Id,
        checklist: model.Checklist.Id,
    };

    allocator: std.mem.Allocator = undefined,
    users: UserStore = undefined,
    checklists: ChecklistStore = undefined,

    pub fn init(self: *Self, allocator: std.mem.Allocator) void {
        self.* = .{
            .allocator = allocator,
            .users = .empty,
            .checklists = .empty,
        };
    }

    pub fn validate(self: Self) !void {
        // TODO
        _ = self;
    }

    pub fn create(self: *Self, data: CreateData) !void {
        switch (data) {
            .user => |user_data| {
                const instanceId = try self.users.create(self.allocator, user_data);
                self.validate() catch |validate_error| {
                    self.users.delete(self.allocator, instanceId) catch |err| switch (err) {
                        error.InvalidInstanceId => unreachable,
                    };

                    return validate_error;
                };
            },
            .checklist => |checklist_data| {
                const instanceId = try self.checklists.create(self.allocator, checklist_data);
                self.validate() catch |validate_error| {
                    self.checklists.delete(self.allocator, instanceId) catch |err| switch (err) {
                        error.InvalidInstanceId => unreachable,
                    };

                    return validate_error;
                };
            },
        }
    }

    pub fn update(self: *Self, data: UpdateData) !void {
        switch (data) {
            .user => |user_data| {
                const instance = try self.users.retrieve(user_data.id);
                const instance_data_backup: model.User.Data = undefined;
                try instance_data_backup.init(self.allocator, instance.data);

                instance.update(user_data.updates) catch |err| {
                    instance_data_backup.deinit(self.allocator);
                    return err;
                };

                self.validate() catch |validate_error| {
                    instance.data.deinit(self.allocator);
                    instance.data = instance_data_backup;
                    return validate_error;
                };

                instance_data_backup.deinit(self.allocator);
            },
            .checklist => |checklist_data| {
                const instance = try self.checklists.retrieve(checklist_data.id);
                const instance_data_backup: model.Checklist.Data = undefined;
                try instance_data_backup.init(self.allocator, instance.data);

                instance.update(checklist_data.updates) catch |err| {
                    instance_data_backup.deinit(self.allocator);
                    return err;
                };

                self.validate() catch |validate_error| {
                    instance.data.deinit(self.allocator);
                    instance.data = instance_data_backup;
                    return validate_error;
                };

                instance_data_backup.deinit(self.allocator);
            },
        }
    }

    pub fn delete(self: *Self, data: DeleteData) !void {
        switch (data) {
            .user => |user_id| {
                try self.users.delete(self.allocator, user_id);
                self.validate() catch |validate_error| {
                    // TODO
                    return validate_error;
                };
            },
            .checklist => |checklist_id| {
                try self.checklists.delete(self.allocator, checklist_id);
                self.validate() catch |validate_error| {
                    // TODO
                    return validate_error;
                };
            },
        }
    }

    pub fn deinit(self: *Self) void {
        self.users.deinit(self.allocator);
        self.checklists.deinit(self.allocator);
    }
};

test "data store usage" {
    var data_store: DataStore = .{};
    data_store.init(std.testing.allocator);
    defer data_store.deinit();

    try data_store.create(DataStore.CreateData{
        .user = &.{
            .display_name = "John Doe",
        },
    });

    try data_store.create(DataStore.CreateData{
        .user = &.{
            .display_name = "Jane Doe",
        },
    });
}

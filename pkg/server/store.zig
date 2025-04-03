const std = @import("std");
const model = @import("model.zig");

pub fn ModelStore(comptime Model: type) type {
    return struct {
        const Self = @This();
        const InstanceHashMap = std.AutoHashMapUnmanaged(Model.Id, *Model);

        nextId: u32 = 0,
        instances: Self.InstanceHashMap = .empty ,

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
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

pub fn CollectionStore(
    comptime Models: []const type,
) type {
    _ = Models; // DEBUG

    // var storage_fields: [Models.len]std.builtin.Type.StructField = undefined;
    var storage_fields: []std.builtin.Type.StructField = &.{};

    const storage_type = @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = storage_fields[0..],
            .decls = &.{},
            .is_tuple = false,
        },
    });

    return struct {
        const Self = @This();
        const Storage = storage_type;

        storage: Storage = .{},

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            // TODO
            _ = self;
            _ = allocator;
        }
    };
}

pub const DefaultStore = CollectionStore(&.{
    UserStore,
    ChecklistStore,
});

test "memory store usage" {
    var store: DefaultStore = .empty;
    defer store.deinit(std.testing.allocator);

    // TODO
}

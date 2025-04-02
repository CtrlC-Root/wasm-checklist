const std = @import("std");

const Timestamp = i64; // std.time.timestamp() return value

// Create a variant of an existing struct type where all fields are optional.
pub fn StructOptionalFields(comptime Original: type) type {
    const original_type = @typeInfo(Original).@"struct";
    const original_data_fields = original_type.fields;

    var optional_data_fields: [original_data_fields.len]std.builtin.Type.StructField = undefined;
    for (0..original_data_fields.len) |index| {
        // https://ziglang.org/documentation/0.14.0/std/#std.builtin.Type.StructField
        const original_data_field = original_data_fields[index];

        // XXX: what if the field is already optional?
        const optional_type = @Type(.{
            .optional = .{ .child = original_data_field.type },
        });

        const default_value_ptr = @as(*const anyopaque, @ptrCast(&@as(optional_type, null)));
        optional_data_fields[index] = .{
            .name = original_data_field.name,
            .type = optional_type,
            .default_value_ptr = default_value_ptr,
            .is_comptime = original_data_field.is_comptime,
            .alignment = original_data_field.alignment,
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = original_type.layout,
            .fields = optional_data_fields[0..],
            .decls = &.{}, // compiler requires reified structs to not have any delcarations
            .is_tuple = original_type.is_tuple,
        },
    });
}

// Create a model struct.
pub fn Model(comptime modelName: []const u8, comptime ModelData: type) type {
    const optional_data_type = StructOptionalFields(ModelData);
    return struct {
        const Self = @This();

        pub const Id = u32;
        pub const Data = ModelData;
        pub const OptionalData = optional_data_type;

        pub const name = modelName;

        id: Self.Id = undefined,
        data: *Self.Data = undefined,

        pub fn init(self: *Self, allocator: std.mem.Allocator, id: Self.Id, data: *const Self.Data) !void {
            const data_owned = try allocator.create(Self.Data);
            errdefer allocator.destroy(data_owned);

            try data_owned.init(allocator, data);
            errdefer data_owned.deinit(allocator);

            self.* = .{
                .id = id,
                .data = data_owned,
            };
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            self.data.deinit(allocator);
            allocator.destroy(self.data);
        }

        pub fn update(
            self: *Self,
            allocator: std.mem.Allocator,
            data: *const Self.OptionalData,
            field_names: []const []const u8,
        ) !void {
            // assemble field values for the updated data by copying the
            // existing values (including references to allocated memory) and
            // overwriting fields specified by field_names from data values
            // XXX: this is horribly inefficient but should be possible to do
            // this in O(n) since we know all the fields at compile time
            var local_data: Self.Data = self.data.*;
            inline for (std.meta.fields(Self.Data)) |field| {
                for (field_names) |field_name| {
                    if (std.mem.eql(u8, field.name, field_name)) {
                        // XXX: optional fields in Self.Data should be a straight copy
                        if (@field(data, field.name)) |value| {
                            @field(local_data, field.name) = value;
                        }
                    }
                }
            }

            // allocate and initialize a new data instance using the local data
            // assembled above for field values
            var updated_data = try allocator.create(Self.Data);
            errdefer allocator.destroy(updated_data);

            try updated_data.init(allocator, &local_data);
            errdefer updated_data.deinit(allocator);

            // make sure we don't use local_data for anything again because it
            // could be a mix of memory allocated from different allocators and
            // we already have a copy of the values in new_data from above
            local_data = undefined;

            // validate the updated data
            try updated_data.update(@as(*const Self.Data, @ptrCast(self.data)));

            // deinitialize the existing data
            self.data.deinit(allocator);
            allocator.destroy(self.data);

            // replace the existing data with the updated data
            self.data = updated_data;
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

    pub fn update(self: *Self, previous: *const Self) !void {
        _ = previous;

        if (self.display_name.len == 0) {
            return error.InvalidValue;
        }
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

    pub fn update(self: *Self, previous: *const Self) !void {
        if (self.title.len == 0) {
            return error.InvalidValue;
        }
    
        const created_by_changed = (self.created_by_user_id != previous.created_by_user_id);
        const created_on_changed = (self.created_on_timestamp != previous.created_on_timestamp);
        if (created_by_changed or created_on_changed) {
            return error.ReadOnlyFieldChanged;
        }
    }
});

test "checklist model usage" {
    const sample_data: Checklist.Data = .{
        .title = "Today's Tasks",
        .created_by_user_id = 10,
        .created_on_timestamp = std.time.timestamp(),
    };

    var checklist: Checklist = undefined;
    try checklist.init(std.testing.allocator, 0, &sample_data);
    defer checklist.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, checklist.id);
    try std.testing.expectEqualSlices(u8, sample_data.title, checklist.data.title);
    try std.testing.expectEqual(sample_data.created_by_user_id, checklist.data.created_by_user_id);
    try std.testing.expectEqual(sample_data.created_on_timestamp, checklist.data.created_on_timestamp);

    const sample_updates: Checklist.OptionalData = .{
        .title = "Tomorrow's Tasks",
        .created_by_user_id = 20,
    };

    try checklist.update(std.testing.allocator, &sample_updates, &.{ "title" });
    try std.testing.expectEqualSlices(u8, "Tomorrow's Tasks", checklist.data.title);
    try std.testing.expectEqual(sample_data.created_by_user_id, checklist.data.created_by_user_id);
    try std.testing.expectEqual(sample_data.created_on_timestamp, checklist.data.created_on_timestamp);
}

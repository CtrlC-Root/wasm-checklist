const std = @import("std");

pub fn Field(comptime FieldValue: type) type {
    return struct {
        const Self = @This();
        pub const Value = FieldValue;
    };
}

pub const BooleanField = Field(bool);
pub const StringField = Field([]const u8);
pub const TimestampField = Field(i64); // std.time.timestamp() result type

pub fn Model(
    comptime modelName: []const u8,
    comptime idFieldName: []const u8,
    comptime ModelDefinition: type,
) type {
    _ = idFieldName; // TODO

    const definition_struct_info = @typeInfo(ModelDefinition).@"struct";
    const definition_struct_fields = definition_struct_info.fields;

    const data_type = model_data_type: {
        var fields: [definition_struct_fields.len]std.builtin.Type.StructField = undefined;
        for (0..definition_struct_fields.len) |index| {
            const original_field = definition_struct_fields[index];

            const field_type = @Type(.{
                .optional = .{ .child = original_field.type.Value },
            });

            const field_default_value_ptr = @as(*const anyopaque, @ptrCast(&@as(field_type, null)));

            fields[index] = .{
                .name = original_field.name,
                .type = field_type,
                .default_value_ptr = field_default_value_ptr,
                .is_comptime = original_field.is_comptime,
                .alignment = original_field.alignment,
            };
        }

        break :model_data_type @Type(.{
            .@"struct" = .{
                .layout = definition_struct_info.layout,
                .fields = fields[0..],
                .decls = &.{}, // compiler requires reified structs to not have any delcarations
                .is_tuple = false,
            },
        });
    };

    return struct {
        const Self = @This();

        pub const name = modelName;
        pub const Definition = ModelDefinition;
        pub const Data = data_type;

        data: Data = undefined,
    };
}

pub const User = Model("user", "id", struct {
    const Self = @This();
    const IdField = Field(u64);

    id: Self.IdField = undefined,
    display_name: StringField = undefined,
});

pub const Checklist = Model("checklist", "id", struct {
    const Self = @This();
    const IdField = Field(u64);

    id: Self.IdField = undefined,
    title: StringField = undefined,
    created_by_user_id: User.Definition.IdField = undefined,
    created_on_timestamp: TimestampField = undefined,
});

pub const Item = Model("item", "id", struct {
    const Self = @This();
    const IdField = Field(u64);

    id: Self.IdField = undefined,
    parent_checklist_id: Checklist.Definition.IdField = undefined,
    title: StringField = undefined,
    complete: BooleanField = undefined,
    created_by_user_id: User.Definition.IdField = undefined,
    created_on_timestamp: TimestampField = undefined,
});

test "placeholder testl" {
    const user: User = .{};
    _ = user;

    const checklist: Checklist = .{};
    _ = checklist;

    const item: Item = .{};
    _ = item;
}

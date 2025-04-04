const std = @import("std");

pub fn Field(comptime FieldValue: type) type {
    return struct {
        const Self = @This();

        const Value = FieldValue;

        value: Value = undefined,
    };
}

pub const StringField = Field([]const u8);
pub const TimestampField = Field(i64); // std.time.timestamp() result type

pub fn Model(
    comptime modelName: []const u8,
    comptime idFieldName: []const u8,
    comptime ModelData: type,
) type {
    _ = idFieldName; // TODO

    return struct {
        const Self = @This();

        const name = modelName;
        const Data = ModelData;

        data: *Data = undefined,
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
    created_by_user_id: User.Data.IdField = undefined,
    created_on_timestamp: TimestampField = undefined,
});

pub const Item = Model("item", "id", struct {
    const Self = @This();
    const IdField = Field(u64);

    id: Self.IdField = undefined,
    parent_checklist_id: Checklist.Data.IdField = undefined,
    title: StringField = undefined,
    complete: Field(bool) = undefined,
    created_by_user_id: User.Data.IdField = undefined,
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

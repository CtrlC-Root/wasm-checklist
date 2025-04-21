const std = @import("std");

pub fn Field(comptime FieldValue: type) type {
    return struct {
        const Self = @This();
        pub const Value = FieldValue;

        pub const OptionalValue = union(enum) {
            none,
            some: Value,
        };

        // memory management for values
        pub fn initValue(allocator: std.mem.Allocator, source: Self.Value) !Self.Value {
            switch (@typeInfo(Self.Value)) {
                .pointer => |pointer| {
                    return try allocator.dupe(pointer.child, source);
                },
                else => {
                    return source;
                }
            }
        }

        pub fn deinitValue(allocator: std.mem.Allocator, target: Self.Value) void {
            switch (@typeInfo(Self.Value)) {
                .pointer => |_| {
                    allocator.free(target);
                },
                else => {},
            }
        }

        // memory management for optional values
        pub fn initOptionalValue(allocator: std.mem.Allocator, source: Self.OptionalValue) !Self.OptionalValue {
            return switch (source) {
                .some => |value| Self.OptionalValue{ .some = try Self.initValue(allocator, value) },
                .none => Self.OptionalValue.none,
            };
        }

        pub fn deinitOptionalValue(allocator: std.mem.Allocator, target: Self.OptionalValue) void {
            switch (target) {
                .some => |value| Self.deinitValue(allocator, value),
                .none => {},
            }
        }
    };
}

pub const BooleanField = Field(bool);
pub const StringField = Field([]const u8);
pub const TimestampField = Field(i64); // std.time.timestamp() result type

pub fn Model(
    comptime modelName: []const u8,
    comptime modelIdFieldName: []const u8,
    comptime ModelFields: type,
) type {
    const definition_struct_info = @typeInfo(ModelFields).@"struct";
    const definition_struct_fields = definition_struct_info.fields;

    const data_type = block: {
        var fields: [definition_struct_fields.len]std.builtin.Type.StructField = undefined;
        for (0..definition_struct_fields.len) |index| {
            const original_field = definition_struct_fields[index];
            const original_data_type = original_field.type.Value;
            const default_value = @as(original_data_type, undefined);

            fields[index] = .{
                .name = original_field.name,
                .type = original_data_type,
                .default_value_ptr = @as(*const anyopaque, @ptrCast(&default_value)),
                .is_comptime = original_field.is_comptime,
                .alignment = original_field.alignment,
            };
        }

        break :block @Type(.{
            .@"struct" = .{
                .layout = definition_struct_info.layout,
                .fields = fields[0..],
                .decls = &.{}, // compiler requires reified structs to not have any delcarations
                .is_tuple = false,
            },
        });
    };

    const partial_data_type = block: {
        var fields: [definition_struct_fields.len]std.builtin.Type.StructField = undefined;
        for (0..definition_struct_fields.len) |index| {
            const original_field = definition_struct_fields[index];
            const original_data_type = original_field.type.OptionalValue;
            const default_value = @as(original_data_type, original_data_type.none);

            fields[index] = .{
                .name = original_field.name,
                .type = original_data_type,
                .default_value_ptr = @as(*const anyopaque, @ptrCast(&default_value)),
                .is_comptime = original_field.is_comptime,
                .alignment = original_field.alignment,
            };
        }

        break :block @Type(.{
            .@"struct" = .{
                .layout = definition_struct_info.layout,
                .fields = fields[0..],
                .decls = &.{}, // compiler requires reified structs to not have any delcarations
                .is_tuple = false,
            },
        });
    };

    const definition_id_field = blk: {
        for (0..definition_struct_fields.len) |index| {
            const original_field = definition_struct_fields[index];
            if (std.mem.eql(u8, original_field.name, modelIdFieldName)) {
                break :blk original_field;
            }
        }

        return error.ModelIdFieldMissing;
    };

    return struct {
        const Self = @This();

        // model definition
        pub const name = modelName;
        pub const Fields = ModelFields;

        pub const idFieldName = definition_id_field.name;
        pub const IdFieldValue = definition_id_field.type.Value;

        // computed based on model definition
        pub const Data = data_type;
        pub const PartialData = partial_data_type;

        // partial data functionality
        pub fn parseJsonPartialData(allocator: std.mem.Allocator, io_reader: anytype) !Self.PartialData {
            var json_reader = std.json.reader(allocator, io_reader);
            defer json_reader.deinit();

            // parse an arbitrary JSON value
            const data_parsed = try std.json.parseFromTokenSource(
                std.json.Value,
                allocator,
                &json_reader,
                .{},
            );

            defer data_parsed.deinit();

            // validate the parsed value is a JSON object
            const data_object = switch (data_parsed.value) {
                .object => |object| object,
                else => return error.InvalidJsonValue,
            };

            // XXX: detect object fields that don't correspond to model fields and throw an error

            // extract field values from the parsed object
            var data: Self.PartialData = .{};
            errdefer Self.deinitPartialData(&data, allocator);

            inline for (std.meta.fields(Self.Fields)) |field| {
                if (data_object.get(field.name)) |value| {
                    const value_parsed = try std.json.parseFromValue(
                        field.type.Value,
                        allocator,
                        value,
                        .{},
                    );

                    defer value_parsed.deinit();

                    const allocated_value = try field.type.initValue(allocator, value_parsed.value);
                    @field(data, field.name) = field.type.OptionalValue{ .some = allocated_value };
                }
            }

            return data;
        }

        pub fn deinitPartialData(self: *const Self.PartialData, allocator: std.mem.Allocator) void {
            inline for (std.meta.fields(Self.Fields)) |field| {
                field.type.deinitOptionalValue(allocator, @field(self, field.name));
            }
        }

        // instance data
        data: Data = undefined,

        pub fn init(self: *Self, allocator: std.mem.Allocator, data: *const Self.Data) !void {
            const fields = std.meta.fields(Self.Fields);
            var initialized = std.StaticBitSet(fields.len).initEmpty();

            errdefer {
                inline for (0.., fields) |index, field| {
                    if (initialized.isSet(index)) {
                        field.type.deinitValue(allocator, @field(self.data, field.name));
                    }
                }
            }

            inline for (0.., fields) |index, field| {
                @field(self.data, field.name) = try field.type.initValue(
                    allocator,
                    @field(data, field.name),
                );

                initialized.set(index);
            }
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            inline for (std.meta.fields(Self.Fields)) |field| {
                field.type.deinitValue(allocator, @field(self.data, field.name));
            }
        }

        pub fn getId(self: Self) Self.IdFieldValue {
            return @field(self.data, Self.idFieldName);
        }
    };
}

test "general model usage" {
    const Vehicle = Model("vehicle", "vin", struct {
        vin: StringField,
        manufacturer: StringField,
        model: StringField,
        model_year: Field(u16),
    });

    // model instance with data on the stack
    const stack_vehicle: Vehicle = .{
        .data = .{
            .vin = "ABCD1234",
            .manufacturer = "Yamaha",
            .model = "XSR700",
            .model_year = 2018,
        },
    };

    try std.testing.expectEqualSlices(u8, Vehicle.idFieldName, "vin");
    try std.testing.expectEqualSlices(u8, stack_vehicle.getId(), "ABCD1234");

    // model instance with data on the heap
    var heap_vehicle: Vehicle = undefined;
    try heap_vehicle.init(std.testing.allocator, &.{
        .vin = "EFGH5678",
        .manufacturer = stack_vehicle.data.manufacturer,
        .model = "XSR900",
        .model_year = stack_vehicle.data.model_year,
    });

    defer heap_vehicle.deinit(std.testing.allocator);

    // partial data on the stack
    const partial_data: Vehicle.PartialData = .{
        .model = .{ .some = "Tenere 700" },
        .model_year = .{ .some = 2024 },
    };

    // parse partial data on the heap
    const sample_partial_json =
        \\{
        \\  "model": "Tenere 700",
        \\  "model_year": 2024
        \\}
    ;

    var sample_partial_fbs = std.io.fixedBufferStream(sample_partial_json);
    const parsed_partial_data = try Vehicle.parseJsonPartialData(std.testing.allocator, sample_partial_fbs.reader());
    defer Vehicle.deinitPartialData(&parsed_partial_data, std.testing.allocator);

    try std.testing.expectEqual(partial_data.vin, parsed_partial_data.vin);
    try std.testing.expectEqual(partial_data.manufacturer, parsed_partial_data.manufacturer);
    try std.testing.expectEqualSlices(u8, partial_data.model.some, parsed_partial_data.model.some);
    try std.testing.expectEqual(partial_data.model_year, parsed_partial_data.model_year);
}

pub const User = Model("user", "id", struct {
    const Self = @This();
    pub const Id = Field(u64);

    id: Self.Id = undefined,
    display_name: StringField = undefined,
});

pub const Checklist = Model("checklist", "id", struct {
    const Self = @This();
    pub const Id = Field(u64);

    id: Self.Id = undefined,
    title: StringField = undefined,
    created_by_user_id: User.Fields.Id = undefined,
    created_on_timestamp: TimestampField = undefined,
});

pub const Item = Model("item", "id", struct {
    const Self = @This();
    pub const Id = Field(u64);

    id: Self.Id = undefined,
    parent_checklist_id: Checklist.Fields.Id = undefined,
    title: StringField = undefined,
    complete: BooleanField = undefined,
    created_by_user_id: User.Fields.Id = undefined,
    created_on_timestamp: TimestampField = undefined,
});

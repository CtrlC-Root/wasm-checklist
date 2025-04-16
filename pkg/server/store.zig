const std = @import("std");
const model = @import("model.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

// testing related import processing
test {
    // note: this only sees public declarations so the only way to include
    // tests that are not otherwise reachable by following those is to
    // explicitly use the related struct which contains it
    std.testing.refAllDeclsRecursive(@This());
}

pub const DataStore = struct {
    const Self = @This();
    const schema_sql = @embedFile("schema.sql");

    database: *c.sqlite3 = undefined,

    pub fn init(self: *Self, source: [:0]const u8) !void {
        var database: ?*c.sqlite3 = undefined;
        const open_result = c.sqlite3_open(source, &database);
        if (open_result != c.SQLITE_OK) {
            return error.DatabaseOpenFailed;
        }

        std.debug.assert(database != null);
        errdefer {
            const close_result = c.sqlite3_close(database.?);
            std.debug.assert(close_result == c.SQLITE_OK);
        }

        self.* = .{
            .database = database.?,
        };

        // XXX: configure the database settings
        try self.executeSql("PRAGMA foreign_keys = ON");

        // TODO: implement schema migrations
        try self.executeSql(Self.schema_sql);
    }

    pub fn deinit(self: Self) void {
        const close_result = c.sqlite3_close(self.database);
        std.debug.assert(close_result == c.SQLITE_OK);
    }

    fn executeSql(self: Self, sql: [:0]const u8) !void {
        var error_message: [*c]u8 = undefined;
        const result = c.sqlite3_exec(self.database, sql, null, null, &error_message);
        if (result != c.SQLITE_OK) {
            defer c.sqlite3_free(error_message);
            std.debug.print("Failed to execute SQL ({d}): {s}\n", .{ result, error_message });
            return error.DatabaseExecuteFailed;
        }

        return;
    }

    pub fn create(
        self: Self,
        comptime Model: type,
        allocator: std.mem.Allocator,
        data: *const Model.PartialData,
    ) !Model.IdFieldValue {
        // create an arena allocator for temporary data
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // determine the names of fields with values in the provided data
        const field_names = blk: {
            const partial_data_fields = std.meta.fields(Model.PartialData);
            var field_names = try std.BoundedArray([]const u8, partial_data_fields.len).init(0);

            inline for (partial_data_fields) |field| {
                switch (@field(data, field.name)) {
                    .some => |_| {
                        field_names.appendAssumeCapacity(field.name);
                    },
                    .none => {},
                }
            }

            break :blk field_names;
        };

        // create the insert statement sql
        const sql: [:0]const u8 = blk: {
            // create the insert sql
            var buffer = std.ArrayList(u8).init(arena_allocator);
            defer buffer.deinit(); // XXX: not required with arena

            try buffer.appendSlice(try std.fmt.allocPrint(
                arena_allocator,
                "INSERT INTO {s} (",
                .{Model.name},
            ));

            for (0.., field_names.slice()) |index, field_name| {
                if (index > 0) {
                    try buffer.appendSlice(", ");
                }

                try buffer.appendSlice(field_name);
            }

            try buffer.appendSlice(try std.fmt.allocPrint(
                arena_allocator,
                ") VALUES (",
                .{},
            ));

            for (0.., field_names.slice()) |index, field_name| {
                if (index > 0) {
                    try buffer.appendSlice(", ");
                }

                try buffer.appendSlice(try std.fmt.allocPrint(
                    arena_allocator,
                    ":{s}",
                    .{field_name},
                ));
            }

            try buffer.appendSlice(")");
            break :blk try arena_allocator.dupeZ(u8, buffer.items);
        };

        // XXX: use logging for this
        // std.debug.print("SQL: {s}\n", .{ sql });

        // create prepared statement
        const statement = blk: {
            var statement: ?*c.sqlite3_stmt = undefined;
            const result = c.sqlite3_prepare_v2(self.database, sql, @intCast(sql.len + 1), &statement, null);
            if (result != c.SQLITE_OK) {
                std.debug.print("failed to prepare statement: {s}\n", .{ c.sqlite3_errmsg(self.database) });
                return error.PrepareStatement;
            }

            break :blk statement.?;
        };

        defer {
            const result = c.sqlite3_finalize(statement);
            std.debug.assert(result == c.SQLITE_OK);
        }

        // bind data to prepared statement placeholders
        inline for (std.meta.fields(Model.Fields)) |field| {
            switch (@field(data, field.name)) {
                .some => |value| {
                    const parameter_index = c.sqlite3_bind_parameter_index(
                        statement,
                        try std.fmt.allocPrintZ(arena_allocator, ":{s}", .{field.name}),
                    );

                    std.debug.assert(parameter_index != 0);
                    switch (@typeInfo(field.type.Value)) {
                        .optional => {
                            // XXX: would require recursion or nesting, skip for now
                            unreachable;

                            // const result = c.sqlite3_bind_null(statement, parameter_index);
                            // std.debug.assert(result == c.SQLITE_OK);
                        },
                        .int => |_| {
                            // XXX: consider bits and signedness
                            const result = c.sqlite3_bind_int64(statement, parameter_index, @intCast(value));
                            std.debug.assert(result == c.SQLITE_OK);
                        },
                        .pointer => |pointer| {
                            switch (@typeInfo(pointer.child)) {
                                .int => |child_int| {
                                    std.debug.assert(child_int.signedness == .unsigned);
                                    std.debug.assert(child_int.bits == 8);

                                    const result = c.sqlite3_bind_text(
                                        statement,
                                        parameter_index,
                                        &value[0],
                                        @intCast(value.len),
                                        c.SQLITE_STATIC,
                                    );

                                    std.debug.assert(result == c.SQLITE_OK);
                                },
                                else => {
                                    // std.debug.print("{}\n", .{ pointer.child });
                                    @panic("field pointer type not supported");
                                },
                            }
                        },
                        else => {
                            std.debug.print("{}\n", .{ field.type.Value });
                            @panic("field type not supported");
                        },
                    }
                },
                .none => {},
            }
        }

        // execute the prepared statement
        const result = c.sqlite3_step(statement);
        if (result != c.SQLITE_DONE) {
            std.debug.print("failed to step statement: {s}\n", .{ c.sqlite3_errmsg(self.database) });
            return error.ExecuteStatement;
        }

        // XXX: is this necessary?
        _ = c.sqlite3_reset(statement);

        // XXX: the rowid may not be the id column so you'd need to SELECT it
        const last_id = c.sqlite3_last_insert_rowid(self.database);
        return @intCast(last_id);
    }

    pub fn retrieve(
        self: Self,
        comptime Model: type,
        allocator: std.mem.Allocator,
        id: Model.IdFieldValue,
    ) !Model {
        // create an arena allocator for temporary data
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        // XXX
        const sql: [:0]const u8 = blk: {
            // create the insert sql
            var buffer = std.ArrayList(u8).init(arena_allocator);
            defer buffer.deinit(); // XXX: not required with arena

            try buffer.appendSlice("SELECT ");

            inline for (0.., std.meta.fields(Model.Data)) |index, field| {
                if (index > 0) {
                    try buffer.appendSlice(", ");
                }

                // XXX: hack for different field types in SQLite3
                const definition_field_index = std.meta.fieldIndex(Model.Fields, field.name) orelse unreachable;
                const definition_field = std.meta.fields(Model.Fields)[definition_field_index];

                if (definition_field.type == model.TimestampField) {
                    try buffer.appendSlice(try std.fmt.allocPrint(
                        arena_allocator,
                        "unixepoch({s}) AS {s}",
                        .{field.name, field.name},
                    ));
                } else {
                    try buffer.appendSlice(field.name);
                }
            }

            try buffer.appendSlice(try std.fmt.allocPrint(
                arena_allocator,
                " FROM {s} WHERE {s} = :{s}",
                .{Model.name, Model.idFieldName, Model.idFieldName},
            ));

            break :blk try arena_allocator.dupeZ(u8, buffer.items);
        };

        // XXX
        // std.debug.print("SQL: {s}\n", .{ sql });

        // create prepared statement
        const statement = blk: {
            var statement: ?*c.sqlite3_stmt = undefined;
            const result = c.sqlite3_prepare_v2(self.database, sql, @intCast(sql.len + 1), &statement, null);
            if (result != c.SQLITE_OK) {
                std.debug.print("failed to prepare statement: {s}\n", .{ c.sqlite3_errmsg(self.database) });
                return error.PrepareStatement;
            }

            break :blk statement.?;
        };

        defer {
            const result = c.sqlite3_finalize(statement);
            std.debug.assert(result == c.SQLITE_OK);
        }

        // bind data to prepared statement placeholders
        // XXX: model id may not always be an integer
        const bind_result = c.sqlite3_bind_int64(statement, 1, @intCast(id));
        std.debug.assert(bind_result == c.SQLITE_OK);

        // execute the statement
        const first_step_result = c.sqlite3_step(statement);
        std.debug.assert(first_step_result == c.SQLITE_ROW);

        // XXX
        var data: Model.Data = undefined;
        inline for (0.., std.meta.fields(Model.Data)) |index, field| {
            switch (@typeInfo(field.type)) {
                .optional => {
                    // XXX: would require recursion or nesting, skip for now
                    unreachable;

                    // std.debug.assert(c.sqlite3_column_type(statement, index) == SQLITE_NULL);
                },
                .bool => {
                    std.debug.assert(c.sqlite3_column_type(statement, index) == c.SQLITE_INTEGER);
                    @field(data, field.name) = (c.sqlite3_column_int(statement, index) != 0);
                },
                .int => |_| {
                    // XXX: consider bits and signedness
                    std.debug.assert(c.sqlite3_column_type(statement, index) == c.SQLITE_INTEGER);
                    @field(data, field.name) = @intCast(c.sqlite3_column_int64(statement, index));
                },
                .pointer => |pointer| {
                    switch (@typeInfo(pointer.child)) {
                        .int => |child_int| {
                            std.debug.assert(child_int.signedness == .unsigned);
                            std.debug.assert(child_int.bits == 8);

                            std.debug.assert(c.sqlite3_column_type(statement, index) == c.SQLITE_TEXT);
                            const value_base = c.sqlite3_column_text(statement, index);
                            @field(data, field.name) = std.mem.span(value_base);
                        },
                        else => {
                            // std.debug.print("{}\n", .{ pointer.child });
                            @panic("field pointer type not supported");
                        },
                    }
                },
                else => {
                    std.debug.print("{}\n", .{ field.type.Value });
                    @panic("field type not supported");
                },
            }
        }

        var instance: Model = .{};
        try instance.init(allocator, &data);
        return instance;
    }
};

test "datastore" {
    var datastore: DataStore = .{};
    try datastore.init(":memory:");
    defer datastore.deinit();

    // create a user from partial data and retrieve it
    const john_user_id = try datastore.create(model.User, std.testing.allocator, &.{
        .display_name = .{ .some = "John Doe" },
    });

    const john = try datastore.retrieve(model.User, std.testing.allocator, john_user_id);
    defer john.deinit(std.testing.allocator);

    try std.testing.expectEqual(john_user_id, john.data.id);
    try std.testing.expectEqualSlices(u8, "John Doe", john.data.display_name);

    // create a second user and verify unique ids
    const jane_user_id = try datastore.create(model.User, std.testing.allocator, &.{
        .display_name = .{ .some = "Jane Doe" },
    });

    try std.testing.expect(john_user_id != jane_user_id);

    // create a checklist from partial data and retrieve it
    const john_checklist_id = try datastore.create(model.Checklist, std.testing.allocator, &.{
        .title = .{ .some = "John's Shopping List" },
        .created_by_user_id = .{ .some = john_user_id },
    });

    const john_checklist = try datastore.retrieve(model.Checklist, std.testing.allocator, john_checklist_id);
    defer john_checklist.deinit(std.testing.allocator);

    try std.testing.expectEqual(john_checklist_id, john_checklist.data.id);
    try std.testing.expectEqualSlices(u8, "John's Shopping List", john_checklist.data.title);
    try std.testing.expectEqual(john_user_id, john_checklist.data.created_by_user_id);
    try std.testing.expect(john_checklist.data.created_on_timestamp != 0); // XXX: better way to validate this?

    // create a second checklist and verify unique ids
    const jane_checklist_id = try datastore.create(model.Checklist, std.testing.allocator, &.{
        .title = .{ .some = "Jane's Shopping List" },
        .created_by_user_id = .{ .some = jane_user_id },
    });

    try std.testing.expect(john_checklist_id != jane_checklist_id);

    // create an item from partial data and retrieve it
    const hotdogs_item_id = try datastore.create(model.Item, std.testing.allocator, &.{
        .parent_checklist_id = .{ .some = john_checklist_id },
        .title = .{ .some = "Hotdogs" },
        .created_by_user_id = .{ .some = john_user_id },
    });

    const hotdogs_item = try datastore.retrieve(model.Item, std.testing.allocator, hotdogs_item_id);
    defer hotdogs_item.deinit(std.testing.allocator);

    try std.testing.expectEqual(hotdogs_item_id, hotdogs_item.data.id);
    try std.testing.expectEqual(john_checklist_id, hotdogs_item.data.parent_checklist_id);
    try std.testing.expectEqualSlices(u8, "Hotdogs", hotdogs_item.data.title);
    try std.testing.expectEqual(false, hotdogs_item.data.complete);
    try std.testing.expectEqual(john_user_id, hotdogs_item.data.created_by_user_id);
    try std.testing.expect(hotdogs_item.data.created_on_timestamp != 0); // XXX: better way to validate this?

    // create a second item and verify unique ids
    const icedtea_item_id = try datastore.create(model.Item, std.testing.allocator, &.{
        .parent_checklist_id = .{ .some = jane_checklist_id },
        .title = .{ .some = "Iced Tea" },
        .created_by_user_id = .{ .some = jane_user_id },
    });

    try std.testing.expect(hotdogs_item_id != icedtea_item_id);
}

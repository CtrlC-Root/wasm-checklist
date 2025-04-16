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

    // TODO
    _ = model.Field;
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

    pub fn create(self: Self, comptime Model: type, allocator: std.mem.Allocator, instance: *const Model) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const arena_allocator = arena.allocator();

        // XXX: create sql
        const insert_sql: [:0]const u8 = blk: {
            var buffer = std.ArrayList(u8).init(allocator);
            defer buffer.deinit();

            const insert_into_fragment = try std.fmt.allocPrint(
                arena_allocator,
                "INSERT INTO {s} (",
                .{Model.name},
            );

            try buffer.appendSlice(insert_into_fragment);

            inline for (0.., std.meta.fields(Model.Definition)) |index, field| {
                if (index > 0) {
                    try buffer.appendSlice(", ");
                }

                try buffer.appendSlice(field.name);
            }

            try buffer.appendSlice(") VALUES (");

            // https://sqlite.org/lang_expr.html#parameters
            inline for (0.., std.meta.fields(Model.Definition)) |index, field| {
                if (index > 0) {
                    try buffer.appendSlice(", ");
                }

                const parameter = try std.fmt.allocPrint(arena_allocator, ":{s}", .{field.name});
                try buffer.appendSlice(parameter);
            }
            
            try buffer.appendSlice(")");

            const sql = try allocator.dupeZ(u8, buffer.items);
            break :blk sql;
        };

        defer allocator.free(insert_sql);
        // std.debug.print("{s}\n", .{ insert_sql });

        // XXX: create prepared statement
        const insert_statement = insert_statement: {
            var statement: ?*c.sqlite3_stmt = undefined;
            const result = c.sqlite3_prepare_v2(self.database, insert_sql, @intCast(insert_sql.len + 1), &statement, null);
            if (result != c.SQLITE_OK) {
                std.debug.print("failed to prepare statement: {s}\n", .{ c.sqlite3_errmsg(self.database) });
                return error.PrepareStatement;
            }

            break :insert_statement statement.?;
        };

        defer {
            const result = c.sqlite3_finalize(insert_statement);
            std.debug.assert(result == c.SQLITE_OK);
        }

        // XXX
        // https://sqlite.org/c3ref/bind_blob.html
        inline for (std.meta.fields(Model.Definition)) |field| {
            const parameter = try std.fmt.allocPrintZ(arena_allocator, ":{s}", .{field.name});
            const parameter_index = c.sqlite3_bind_parameter_index(insert_statement, parameter);
            std.debug.assert(parameter_index != 0);

            const data = @field(instance.data, field.name);
            if (data) |data_value| {
                switch (@typeInfo(field.type.Value)) {
                    .int => |_| {
                        // XXX: consider bits and signedness
                        const result = c.sqlite3_bind_int64(insert_statement, parameter_index, @intCast(data_value));
                        std.debug.assert(result == c.SQLITE_OK);
                    },
                    .pointer => |pointer| {
                        switch (@typeInfo(pointer.child)) {
                            .int => |child_int| {
                                std.debug.assert(child_int.signedness == .unsigned);
                                std.debug.assert(child_int.bits == 8);

                                const result = c.sqlite3_bind_text(
                                    insert_statement,
                                    parameter_index,
                                    &data_value[0],
                                    @intCast(data_value.len),
                                    c.SQLITE_STATIC,
                                );

                                std.debug.assert(result == c.SQLITE_OK);
                            },
                            else => @panic("field type not supported"),
                        }
                    },
                    else => {
                        std.debug.print("{}\n", .{ @typeInfo(field.type) });
                        @panic("field type not supported");
                    },
                }
            } else {
                const result = c.sqlite3_bind_null(insert_statement, parameter_index);
                std.debug.assert(result == c.SQLITE_OK);
            }
        }

        const result = c.sqlite3_step(insert_statement);
        if (result != c.SQLITE_DONE) {
            std.debug.print("failed to step statement: {s}\n", .{ c.sqlite3_errmsg(self.database) });
            return error.ExecuteStatement;
        }

        // TODO: retrieve last row ID and return it or update the model

        _ = c.sqlite3_reset(insert_statement);
    }
};

test "datastore" {
    var datastore: DataStore = .{};
    try datastore.init(":memory:");
    defer datastore.deinit();

    try datastore.create(model.User, std.testing.allocator, &.{
        .data = .{
            .id = null,
            .display_name = "John Doe",
        },
    });

    try datastore.create(model.User, std.testing.allocator, &.{
        .data = .{
            .id = null,
            .display_name = "Jane Doe",
        },
    });
}

const std = @import("std");

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
};

test "datastore" {
    var datastore: DataStore = .{};
    try datastore.init(":memory:");
    defer datastore.deinit();

    // TODO: test actually using the datastore
}

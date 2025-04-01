// zig
const std = @import("std");

// first-party
const http = @import("http.zig");

// XXX
pub fn Task(
    comptime OuterRequest: type,
    comptime OuterResponse: type,
    comptime OuterError: type,
) type {
    return struct {
        const Self = @This();
        pub const Request = OuterRequest;
        pub const Response = OuterResponse;
        pub const Error = OuterError;

        pub const Result = union(enum) {
            none,
            @"error": Self.Error,
            response: Self.Response,
        };

        request: Self.Request = undefined,
        result: Self.Result = undefined,
    };
}

// XXX
pub const HttpTask = Task(http.Request, http.Response, union(enum) { connect_failed, timeout });

test "http task" {
    var request_builder: http.RequestBuilder = undefined;
    request_builder.init(std.testing.allocator);
    errdefer request_builder.deinit();

    try request_builder.setUrl("http://example.com/");
    request_builder.setMethod(.GET);

    const http_task: HttpTask = .{
        .request = try request_builder.toOwned(std.testing.allocator),
        .result = HttpTask.Result.none,
    };

    defer http_task.request.deinit(std.testing.allocator);
}

// XXX
pub const TaskMultiHashMap = struct {
    const Self = @This();
    pub const RequestId = u32;
    pub const TaskId = u32;

    pub const Key = task_id_type: {
        std.debug.assert(@typeInfo(RequestId).int.signedness == .unsigned);
        std.debug.assert(@typeInfo(TaskId).int.signedness == .unsigned);

        break :task_id_type @Type(.{
            .int = .{
                .bits = @typeInfo(RequestId).int.bits + @typeInfo(TaskId).int.bits,
                .signedness = .unsigned,
            },
        });
    };

    pub const Value = union(enum) {
        http: HttpTask,
    };

    pub const HashMap = std.AutoHashMapUnmanaged(Self.Key, Self.Value);

    tasks: Self.HashMap = .empty,

    fn packKey(request_id: Self.RequestId, task_id: Self.TaskId) Self.Key {
        return (@as(Self.Key, request_id) << @typeInfo(TaskId).int.bits) | @as(Self.Key, task_id);
    }

    // XXX: public for now but should be refactored to be internal only
    pub fn unpackKeyTaskId(key: Self.Key, request_id: Self.RequestId) ?Self.TaskId {
        const actual_request_id = @as(Self.RequestId, @intCast(key >> @typeInfo(TaskId).int.bits));
        const task_id = @as(Self.TaskId, @truncate(key)); // discard upper bits

        if (actual_request_id == request_id) {
            return task_id;
        } else {
            return null;
        }
    }

    pub fn getOrPut(
        self: *Self,
        allocator: std.mem.Allocator,
        request_id: Self.RequestId,
        task_id: Self.TaskId,
    ) !Self.HashMap.GetOrPutResult {
        return try self.tasks.getOrPut(allocator, Self.packKey(request_id, task_id));
    }

    pub fn getEntry(
        self: Self,
        request_id: Self.RequestId,
        task_id: Self.TaskId,
    ) ?Self.HashMap.Entry {
        return self.tasks.getEntry(Self.packKey(request_id, task_id));
    }
};

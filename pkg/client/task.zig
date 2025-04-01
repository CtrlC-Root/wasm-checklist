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
        const Request = OuterRequest;
        const Response = OuterResponse;
        const Error = OuterError;

        const Result = union(enum) {
            none,
            @"error": Self.Error,
            response: Self.Response,
        };

        request: Self.Request = undefined,
        result: Self.Result = undefined,
    };
}

// XXX
pub const HttpTask = Task(http.Request, http.Response, error{offline});

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
    const RequestId = u32;
    const TaskId = u32;

    const Key = task_id_type: {
        std.debug.assert(@typeInfo(RequestId).int.signedness == .unsigned);
        std.debug.assert(@typeInfo(TaskId).int.signedness == .unsigned);

        break :task_id_type @Type(.{
            .int = .{
                .bits = @typeInfo(RequestId).int.bits + @typeInfo(TaskId).int.bits,
                .signedness = .unsigned,
            },
        });
    };

    const Value = union(enum) {
        http: HttpTask,
    };

    tasks: std.AutoHashMapUnmanaged(Self.Key, Self.Value) = .empty,
};

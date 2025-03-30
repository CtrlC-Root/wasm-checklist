const std = @import("std");

// HTTP Request
pub const Request = struct {
    const Self = @This();

    url: []const u8,
    method: std.http.Method, // https://ziglang.org/documentation/0.14.0/std/#std.http.Method
    headers: []const std.http.Header, // https://ziglang.org/documentation/0.14.0/std/#std.http.Header
    content: []const u8,
};

test "http request json serialization" {
    const sample_request: Request = .{
        .url = "http://example.com/",
        .method = .GET,
        .headers = &.{
            .{ .name = "User-Agent", .value = "Zig Test Runner" },
        },
        .content = "",
    };

    const sample_request_json =
        \\{
        \\  "url": "http://example.com/",
        \\  "method": "GET",
        \\  "headers": [
        \\    {
        \\      "name": "User-Agent",
        \\      "value": "Zig Test Runner"
        \\    }
        \\  ],
        \\  "content": ""
        \\}
    ;

    const actual_request_json = try std.json.stringifyAlloc(
        std.testing.allocator,
        sample_request,
        .{ .whitespace = .indent_2 },
    );

    defer std.testing.allocator.free(actual_request_json);

    try std.testing.expectEqualSlices(u8, actual_request_json, sample_request_json);

    const actual_request_parsed = try std.json.parseFromSlice(
        @TypeOf(sample_request),
        std.testing.allocator,
        actual_request_json,
        .{},
    );

    defer actual_request_parsed.deinit();

    const actual_request = actual_request_parsed.value;
    try std.testing.expectEqualSlices(u8, actual_request.url, sample_request.url);
    try std.testing.expectEqual(actual_request.method, sample_request.method);
    // XXX: headers
    try std.testing.expectEqualSlices(u8, actual_request.content, sample_request.content);
}

// HTTP Response
pub const Response = struct {
    const Self = @This();

    status: std.http.Status, // https://ziglang.org/documentation/0.14.0/std/#std.http.Status
    headers: []const std.http.Header, // https://ziglang.org/documentation/0.14.0/std/#std.http.Header
    content: []const u8,
};

test "http response json serialization" {
    const sample_response: Response = .{
        .status = std.http.Status.ok,
        .headers = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
        },
        .content = "Hello, world!",
    };

    const sample_response_json =
        \\{
        \\  "status": "ok",
        \\  "headers": [
        \\    {
        \\      "name": "Content-Type",
        \\      "value": "text/plain"
        \\    }
        \\  ],
        \\  "content": "Hello, world!"
        \\}
    ;

    const actual_response_json = try std.json.stringifyAlloc(
        std.testing.allocator,
        sample_response,
        .{ .whitespace = .indent_2 },
    );

    defer std.testing.allocator.free(actual_response_json);

    try std.testing.expectEqualSlices(u8, actual_response_json, sample_response_json);

    const actual_response_parsed = try std.json.parseFromSlice(
        @TypeOf(sample_response),
        std.testing.allocator,
        actual_response_json,
        .{},
    );

    defer actual_response_parsed.deinit();

    const actual_response = actual_response_parsed.value;
    try std.testing.expectEqual(actual_response.status, sample_response.status);
    // XXX: headers
    try std.testing.expectEqualSlices(u8, actual_response.content, sample_response.content);
}

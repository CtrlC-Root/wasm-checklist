const std = @import("std");

// HTTP Request
pub const Request = struct {
    const Self = @This();

    url: []const u8,
    method: std.http.Method, // https://ziglang.org/documentation/0.14.0/std/#std.http.Method
    headers: []const std.http.Header, // https://ziglang.org/documentation/0.14.0/std/#std.http.Header
    content: []const u8,

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        for (self.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }

        allocator.free(self.url);
        allocator.free(self.headers);
        allocator.free(self.content);
    }
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

// HTTP Request Builder
pub const RequestBuilder = struct {
    const Self = @This();
    const HeaderHashMapUnmanaged = std.StringHashMapUnmanaged(
        @FieldType(std.http.Header, "value"),
    );

    allocator: std.mem.Allocator = undefined,

    url: []const u8 = undefined,
    method: std.http.Method = undefined,
    headers: HeaderHashMapUnmanaged = undefined,
    content: []const u8 = undefined,

    pub fn init(self: *Self, allocator: std.mem.Allocator) void {
        self.* = .{
            .allocator = allocator,
            .url = &.{},
            .method = .GET,
            .headers = .empty,
            .content = &.{},
        };
    }

    pub fn setUrl(self: *Self, value: []const u8) !void {
        const internal_copy = try self.allocator.dupe(u8, value);
        self.allocator.free(self.url);
        self.url = internal_copy;
    }

    pub fn setMethod(self: *Self, value: std.http.Method) void {
        self.method = value;
    }

    pub fn setHeader(self: *Self, key: []const u8, value: []const u8) !void {
        const internal_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(internal_key);

        const internal_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(internal_value);

        const result = try self.headers.getOrPut(self.allocator, internal_key);
        if (result.found_existing) {
            self.allocator.free(internal_key);
            self.allocator.free(result.value_ptr.*);
            result.value_ptr.* = internal_value;
        } else {
            result.value_ptr.* = internal_value;
        }
    }

    pub fn setContent(self: *Self, value: []const u8) !void {
        const internal_copy = try self.allocator.dupe(u8, value);
        self.allocator.free(self.content);
        self.content = internal_copy;
    }

    pub fn toOwned(self: *Self, allocator: std.mem.Allocator) !Request {
        var request: Request = undefined;
        request.method = self.method;
        
        request.url = try allocator.dupe(u8, self.url);
        errdefer allocator.free(request.url);

        request.content = try allocator.dupe(u8, self.content);
        errdefer allocator.free(request.content);

        var headers = std.ArrayList(std.http.Header).init(self.allocator);
        errdefer {
            for (headers.items) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }

            headers.deinit();
        }

        var header_iterator = self.headers.iterator();
        while (header_iterator.next()) |entry| {
            var header: std.http.Header = undefined;

            header.name = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(header.name);

            header.value = try allocator.dupe(u8, entry.value_ptr.*);
            errdefer allocator.free(header.value);

            try headers.append(header);
        }

        request.headers = try headers.toOwnedSlice();

        self.deinit();
        return request;
    }

    pub fn deinit(self: *Self) void {
        var header_iterator = self.headers.iterator();
        while (header_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }

        self.allocator.free(self.url);
        self.headers.deinit(self.allocator);
        self.allocator.free(self.content);
    }
};

test "http request builder" {
    var builder: RequestBuilder = .{};
    builder.init(std.testing.allocator);
    errdefer builder.deinit();

    // url
    try builder.setUrl("http://example.com");
    try builder.setUrl("https://example.com");

    // method
    builder.setMethod(.POST);
    builder.setMethod(.DELETE);

    // headers
    try builder.setHeader("User-Agent", "Dummy Value");
    try builder.setHeader("User-Agent", "Zig Test Runner");
    try builder.setHeader("X-Trace-Id", "trace_this");

    // consume the builder to an owned instance
    const request = try builder.toOwned(std.testing.allocator);
    defer request.deinit(std.testing.allocator);

    // validate url
    try std.testing.expectEqualSlices(u8, request.url, "https://example.com");

    // validate method
    try std.testing.expectEqual(request.method, .DELETE);

    // validate headers
    try std.testing.expectEqual(request.headers.len, 2);
    try std.testing.expectEqualSlices(u8, request.headers[0].name, "User-Agent");
    try std.testing.expectEqualSlices(u8, request.headers[0].value, "Zig Test Runner");
    try std.testing.expectEqualSlices(u8, request.headers[1].name, "X-Trace-Id");
    try std.testing.expectEqualSlices(u8, request.headers[1].value, "trace_this");
}

// HTTP Response
pub const Response = struct {
    const Self = @This();

    status: std.http.Status, // https://ziglang.org/documentation/0.14.0/std/#std.http.Status
    headers: []const std.http.Header, // https://ziglang.org/documentation/0.14.0/std/#std.http.Header
    content: []const u8,

    pub fn jsonStringify(self: Self, out: anytype) !void {
        return out.write(.{
            .status = @intFromEnum(self.status),
            .headers = self.headers,
            .content = self.content,
        });
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        for (self.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }

        allocator.free(self.headers);
        allocator.free(self.content);
    }
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
        \\  "status": 200,
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

// HTTP Response Builder
pub const ResponseBuilder = struct {
    const Self = @This();
    const HeaderHashMapUnmanaged = std.StringHashMapUnmanaged(
        @FieldType(std.http.Header, "value"),
    );

    allocator: std.mem.Allocator = undefined,

    status: std.http.Status = undefined,
    headers: HeaderHashMapUnmanaged = undefined,
    content: []const u8 = undefined,

    pub fn init(self: *Self, allocator: std.mem.Allocator) void {
        self.* = .{
            .allocator = allocator,
            .status = .ok,
            .headers = .empty,
            .content = &.{},
        };
    }

    pub fn setStatus(self: *Self, value: std.http.Status) void {
        self.status = value;
    }

    pub fn setHeader(self: *Self, key: []const u8, value: []const u8) !void {
        const internal_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(internal_key);

        const internal_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(internal_value);

        const result = try self.headers.getOrPut(self.allocator, internal_key);
        if (result.found_existing) {
            self.allocator.free(internal_key);
            self.allocator.free(result.value_ptr.*);
            result.value_ptr.* = internal_value;
        } else {
            result.value_ptr.* = internal_value;
        }
    }

    pub fn setContent(self: *Self, value: []const u8) !void {
        const internal_copy = try self.allocator.dupe(u8, value);
        self.allocator.free(self.content);
        self.content = internal_copy;
    }

    pub fn toOwned(self: *Self, allocator: std.mem.Allocator) !Response {
        var response: Response = undefined;
        response.status = self.status;

        // duplicate content
        response.content = try allocator.dupe(u8, self.content);
        errdefer allocator.free(response.content);

        // duplicate headers
        var headers = std.ArrayList(std.http.Header).init(allocator);
        errdefer {
            for (headers.items) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }

            headers.deinit();
        }

        var header_iterator = self.headers.iterator();
        while (header_iterator.next()) |entry| {
            var header: std.http.Header = undefined;

            header.name = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(header.name);

            header.value = try allocator.dupe(u8, entry.value_ptr.*);
            errdefer allocator.free(header.value);

            try headers.append(header);
        }

        // note: toOwnedSlice() will allocate the memory it returns with the
        // same allocator passed into std.ArrayList().init()
        response.headers = try headers.toOwnedSlice();

        self.deinit();
        return response;
    }

    pub fn deinit(self: *Self) void {
        var header_iterator = self.headers.iterator();
        while (header_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }

        self.headers.deinit(self.allocator);
        self.allocator.free(self.content);
    }
};

test "http response builder" {
    var builder: ResponseBuilder = .{};
    builder.init(std.testing.allocator);
    errdefer builder.deinit();

    // status
    builder.setStatus(.internal_server_error);
    builder.setStatus(.not_found);

    // headers
    try builder.setHeader("User-Agent", "Dummy Value");
    try builder.setHeader("User-Agent", "Zig Test Runner");
    try builder.setHeader("X-Trace-Id", "trace_this");

    // content
    try builder.setContent("Hello, world!");

    // consume the builder to an owned instance
    const response = try builder.toOwned(std.testing.allocator);
    defer response.deinit(std.testing.allocator);

    // validate status
    try std.testing.expectEqual(response.status, .not_found);

    // validate headers
    try std.testing.expectEqual(response.headers.len, 2);
    try std.testing.expectEqualSlices(u8, response.headers[0].name, "User-Agent");
    try std.testing.expectEqualSlices(u8, response.headers[0].value, "Zig Test Runner");
    try std.testing.expectEqualSlices(u8, response.headers[1].name, "X-Trace-Id");
    try std.testing.expectEqualSlices(u8, response.headers[1].value, "trace_this");

    // validate content
    try std.testing.expectEqualSlices(u8, response.content, "Hello, world!");
}

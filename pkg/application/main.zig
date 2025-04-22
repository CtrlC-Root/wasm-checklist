// zig
const builtin = @import("builtin");
const std = @import("std");

// first-party
const build = @import("build");
const memory = @import("memory.zig");
const http = @import("http.zig");
const task = @import("task.zig");

const PackedByteSlice = memory.PackedByteSlice;

// third-party
const model = @import("model");
const zts = @import("zts");

// testing related import processing
test {
    std.testing.refAllDecls(@This());
}

// Client state.
const Client = struct {
    const Self = @This();

    allocator: std.mem.Allocator = undefined,
    tasks: task.TaskMultiHashMap = undefined,
};

// Global client state singleton.
var client: Client = undefined;

// Initialize internal client state.
export fn initialize() void {
    const allocator: std.mem.Allocator = allocator: {
        // XXX: use something different for WASI operating system?
        if (builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64) {
            // https://ziglang.org/documentation/0.14.0/std/#std.heap.wasm_allocator
            break :allocator std.heap.wasm_allocator;
        }

        // https://ziglang.org/download/0.14.0/release-notes.html#SmpAllocator
        break :allocator switch (builtin.mode) {
            // TODO: use std.heap.DebugAllocator(.{}).allocator() for Debug and ReleaseSafe
            // https://ziglang.org/documentation/0.14.0/std/#std.heap.debug_allocator.DebugAllocator
            .Debug, .ReleaseSafe => std.heap.smp_allocator,

            // https://ziglang.org/documentation/0.14.0/std/#std.heap.smp_allocator
            .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
        };
    };

    client = .{
        .allocator = allocator,
        .tasks = .{},
    };
}

// Finalize internal client state.
export fn finalize() void {
    // TODO: debug allocator deinit() if necessary
}

// Allocate memory.
export fn allocateBytes(size: usize) PackedByteSlice {
    const data = client.allocator.alloc(u8, size) catch @panic("out of memory");
    return PackedByteSlice.init(data);
}

// Free memory.
export fn freeBytes(slice: PackedByteSlice) void {
    std.debug.assert(slice.ptr != 0 or slice.len != 0); // XXX: can slice.ptr ever be zero?
    client.allocator.free(slice.native());
}

// XXX: dashboard view
fn viewDashboard(
    request_allocator: std.mem.Allocator,
    request_id: u32,
    request: *const http.Request,
    response_builder: *http.ResponseBuilder,
) !void {
    _ = request;

    // retrieve checklists
    const checklists_task_id: task.TaskMultiHashMap.TaskId = 0;
    const checklists_task_entry = try client.tasks.getOrPut(client.allocator, request_id, checklists_task_id);
    if (!checklists_task_entry.found_existing) {
        // TODO: clean up checklists_task_entry if the following fails before filling in the value?

        var request_builder: http.RequestBuilder = undefined;
        request_builder.init(request_allocator);
        // XXX: we actually want this, if we care about freeing memory, but
        // only if we're not returning error.WouldBlock below, except in this
        // case request_allocator happens to be an arena allocator so freeing
        // any allocated memory does nothing, which means it's safe to skip
        // errdefer request_builder.deinit();

        try request_builder.setUrl("http://localhost:8080/checklist"); // TODO: fill in origin based on incoming request or config
        request_builder.setMethod(.GET);

        checklists_task_entry.value_ptr.* = task.TaskMultiHashMap.Value{ .http = .{
            .request = try request_builder.toOwned(client.allocator),
            .result = .none,
        } };

        return error.WouldBlock;
    }

    const checklists_task = switch (checklists_task_entry.value_ptr.*) {
        .http => |*http_task| http_task,
    };

    const checklists_response = switch (checklists_task.*.result) {
        .none => {
            return error.WouldBlock;
        },
        .@"error" => {
            // XXX: nested errors, better error tracing, etc?
            return error.TaskFailed;
        },
        .response => |response| response,
    };

    // extract checklists from response
    const checklists = blk: {
        // parse the checklists response content
        var buffer_stream = std.io.fixedBufferStream(checklists_response.content);
        var json_reader = std.json.reader(request_allocator, buffer_stream.reader());
        defer json_reader.deinit();

        const data_parsed = try std.json.parseFromTokenSource(
            []model.Checklist.Data,
            request_allocator,
            &json_reader,
            .{},
        );

        defer data_parsed.deinit();

        // create model instances from response data
        var checklists = std.ArrayList(model.Checklist).init(request_allocator);
        errdefer {
            for (checklists.items) |checklist| {
                checklist.deinit(request_allocator);
            }

            checklists.deinit();
        }

        for (data_parsed.value) |checklist_data| {
            var checklist: model.Checklist = .{};
            try checklist.init(request_allocator, &checklist_data);
            errdefer checklist.deinit(request_allocator);

            try checklists.append(checklist);
        }

        break :blk try checklists.toOwnedSlice();
    };

    defer {
        for (checklists) |checklist| {
            checklist.deinit(request_allocator);
        }

        request_allocator.free(checklists);
    }

    // XXX
    const template = @embedFile("templates/dashboard.html");

    var buffer: std.ArrayListUnmanaged(u8) = .{};
    errdefer buffer.deinit(request_allocator);
    const writer = buffer.writer(request_allocator);

    try zts.writeHeader(template, writer); // XXX: only on full page load
    try zts.print(template, "checklist-list-start", .{}, writer);

    for (checklists) |checklist| {
        try zts.print(template, "checklist-list-item", .{
            .id = checklist.data.id,
            .title = checklist.data.title,
        }, writer);
    }

    try zts.print(template, "checklist-list-end", .{}, writer);
    try zts.print(template, "footer", .{}, writer); // XXX: only on full page load

    const output = try buffer.toOwnedSlice(request_allocator);
    defer request_allocator.free(output);

    // XXX
    try response_builder.setHeader("Content-Type", "text/html");
    try response_builder.setContent(std.mem.trim(u8, output, &std.ascii.whitespace));
}

// XXX: internal invoke
fn invokeInternal(request_id: u32, request: *const http.Request) !http.Response {
    var arena = std.heap.ArenaAllocator.init(client.allocator);
    defer arena.deinit();
    const request_allocator = arena.allocator();

    // create a response builder
    var response_builder: http.ResponseBuilder = undefined;
    response_builder.init(request_allocator);
    // defer response_builder.deinit();

    // default response status
    response_builder.setStatus(.ok);

    // parse the request uri and resolve the raw request path
    const request_uri = try std.Uri.parse(request.url);
    const request_path = try request_uri.path.toRawMaybeAlloc(request_allocator);

    // version
    if (std.mem.eql(u8, request_path, "/app/version")) {
        try response_builder.setHeader("Content-Type", "text/plain");
        try response_builder.setContent(build.version);

        return try response_builder.toOwned(client.allocator);
    }

    // dashboard
    if (std.mem.eql(u8, request_path, "/app")) {
        try viewDashboard(request_allocator, request_id, request, &response_builder);
        return try response_builder.toOwned(client.allocator);
    }

    // generic fallthrough for unknown routes
    response_builder.setStatus(.not_found);
    return try response_builder.toOwned(client.allocator);
}

// XXX: client error details
const ClientError = struct {
    const Self = @This();

    id: []const u8,
};

// XXX: can we discover these from invokeInternal() function signature?
// XXX: any way to use Zig naming convention while parsing with JSON naming
// convention for field names?
const InvokeArguments = struct {
    requestId: u32,
    httpRequest: http.Request,
};

const PendingTasks = struct {
    taskIds: []const u32,
};

const InvokeResult = union(enum) {
    @"error": ClientError,
    pendingTasks: PendingTasks,
    httpResponse: http.Response,
};

// XXX
fn collectTaskIds(request_id: u32) ![]const u32 {
    // collect pending tasks
    var task_ids = std.ArrayList(task.TaskMultiHashMap.TaskId).init(client.allocator);
    errdefer task_ids.deinit();

    // XXX: should be an iterator over tasks for this request ID
    var task_iterator = client.tasks.tasks.iterator();
    while (task_iterator.next()) |entry| {
        // XXX
        if (task.TaskMultiHashMap.unpackKeyTaskId(entry.key_ptr.*, request_id)) |task_id| {
            try task_ids.append(task_id);
        }
    }

    return try task_ids.toOwnedSlice();
}

// Public interface invoke wrapper.
export fn invoke(data: PackedByteSlice) PackedByteSlice {
    return invoke: {
        // deserialize arguments
        const arguments_parsed = std.json.parseFromSlice(
            InvokeArguments,
            client.allocator,
            data.native(),
            .{},
        ) catch |err| break :invoke err;
        defer arguments_parsed.deinit();

        // process request into response
        const request_id = arguments_parsed.value.requestId;
        const response: http.Response = invokeInternal(
            request_id,
            &arguments_parsed.value.httpRequest,
        ) catch |invoke_error| switch (invoke_error) {
            error.WouldBlock => {
                const pending_task_ids = collectTaskIds(request_id) catch |err| break :invoke err;
                const pending_tasks: PendingTasks = .{ .taskIds = pending_task_ids };

                // serialize pending tasks response
                const response_bytes = std.json.stringifyAlloc(
                    client.allocator,
                    InvokeResult{ .pendingTasks = pending_tasks },
                    .{},
                ) catch |err| break :invoke err;
                errdefer client.allocator.free(response_bytes);

                // return response data
                break :invoke PackedByteSlice.init(response_bytes);
            },
            else => break :invoke invoke_error,
        };

        defer response.deinit(client.allocator);

        // serialize http response
        const response_bytes = std.json.stringifyAlloc(
            client.allocator,
            InvokeResult{ .httpResponse = response },
            .{},
        ) catch |err| break :invoke err;
        errdefer client.allocator.free(response_bytes);

        // return response data
        break :invoke PackedByteSlice.init(response_bytes);
    } catch |err| {
        // TODO: handle out of memory before we try and allocate more memory

        // XXX: there is probably a better way to identify the error
        // const err_type = @TypeOf(err);
        // const err_type_info = @typeInfo(err_type);
        // @compileLog(@typeInfo(@TypeOf(specific_error)));
        // @compileLog(@typeName(@TypeOf(err)));
        const client_error: ClientError = .{
            .id = @errorName(err),
        };

        // serialize client error
        const client_error_bytes = std.json.stringifyAlloc(
            client.allocator,
            InvokeResult{ .@"error" = client_error },
            .{},
        ) catch @panic("failed to serialize ClientError value");
        return PackedByteSlice.init(client_error_bytes);
    };
}

// XXX
const GetTaskResult = union(enum) {
    data: task.TaskMultiHashMap.Value,
    @"error": ClientError,
};

// XXX
export fn getTask(request_id: u32, task_id: u32) PackedByteSlice {
    return get: {
        const task_entry = client.tasks.getEntry(request_id, task_id) orelse {
            break :get error.InvalidTaskId;
        };

        // serialize result
        const result_bytes = std.json.stringifyAlloc(
            client.allocator,
            GetTaskResult{ .data = task_entry.value_ptr.* },
            .{},
        ) catch |err| break :get err;
        errdefer client.allocator.free(result_bytes);

        // return result data
        break :get PackedByteSlice.init(result_bytes);
    } catch |err| {
        // TODO: handle out of memory before we try and allocate more memory

        // XXX: there is probably a better way to identify the error
        // const err_type = @TypeOf(err);
        // const err_type_info = @typeInfo(err_type);
        // @compileLog(@typeInfo(@TypeOf(specific_error)));
        // @compileLog(@typeName(@TypeOf(err)));
        const client_error: ClientError = .{
            .id = @errorName(err),
        };

        // serialize client error
        const client_error_bytes = std.json.stringifyAlloc(
            client.allocator,
            GetTaskResult{ .@"error" = client_error },
            .{},
        ) catch @panic("failed to serialize ClientError value");
        return PackedByteSlice.init(client_error_bytes);
    };
}

// XXX
const CompleteTaskResult = union(enum) {
    ok,
    @"error": ClientError,
};

// XXX
export fn completeTask(request_id: u32, task_id: u32, data: PackedByteSlice) PackedByteSlice {
    return complete: {
        const task_entry = client.tasks.getEntry(request_id, task_id) orelse {
            break :complete error.InvalidTaskId;
        };

        switch (task_entry.value_ptr.*) {
            .http => |*http_task| {
                if (http_task.result != .none) {
                    break :complete error.TaskAlreadyComplete;
                }

                // deserialize arguments
                const result_parsed = std.json.parseFromSlice(
                    task.HttpTask.Result,
                    client.allocator,
                    data.native(),
                    .{},
                ) catch |err| break :complete err;
                defer result_parsed.deinit();

                // update the task
                http_task.result = result_parsed.value;
            },
        }

        // serialize result
        const result_bytes = std.json.stringifyAlloc(
            client.allocator,
            CompleteTaskResult.ok,
            .{},
        ) catch |err| break :complete err;
        errdefer client.allocator.free(result_bytes);

        // return result data
        break :complete PackedByteSlice.init(result_bytes);
    } catch |err| {
        // TODO: handle out of memory before we try and allocate more memory

        // XXX: there is probably a better way to identify the error
        // const err_type = @TypeOf(err);
        // const err_type_info = @typeInfo(err_type);
        // @compileLog(@typeInfo(@TypeOf(specific_error)));
        // @compileLog(@typeName(@TypeOf(err)));
        const client_error: ClientError = .{
            .id = @errorName(err),
        };

        // serialize client error
        const client_error_bytes = std.json.stringifyAlloc(
            client.allocator,
            CompleteTaskResult{ .@"error" = client_error },
            .{},
        ) catch @panic("failed to serialize ClientError value");
        return PackedByteSlice.init(client_error_bytes);
    };
}

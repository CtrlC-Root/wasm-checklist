// Zig
const std = @import("std");

// first-party
const http = @import("../http.zig");
const task = @import("../task.zig");
const main = @import("../main.zig");

// third-party
const model = @import("model");
const zts = @import("zts");

pub fn view(
    request_allocator: std.mem.Allocator,
    request_id: u32,
    request: *const http.Request,
    response_builder: *http.ResponseBuilder,
) !void {
    // create new checklist
    if (request.method == .POST) {
        // parse checklist data
        const data = blk: {
            var buffer_stream = std.io.fixedBufferStream(request.content);
            break :blk try model.Checklist.parseJsonPartialData(request_allocator, buffer_stream.reader());
        };

        defer model.Checklist.deinitPartialData(&data, request_allocator);

        // initial api request: create checklist
        const create_task_id: task.TaskMultiHashMap.TaskId = 0;
        const create_task_entry = try main.client.tasks.getOrPut(main.client.allocator, request_id, create_task_id);
        if (!create_task_entry.found_existing) {
            // TODO: clean up task_id if the following fails before filling in the value?

            var request_builder: http.RequestBuilder = undefined;
            request_builder.init(request_allocator);

            const request_url = try std.fmt.allocPrint(
                request_allocator,
                "http://localhost:8080/checklist", // TODO: fill in origin based on incoming request or config
                .{},
            );

            try request_builder.setUrl(request_url);
            request_builder.setMethod(.POST);
            try request_builder.setContent(request.content);
            try request_builder.setHeader("Content-Type", "application/json");

            create_task_entry.value_ptr.* = task.TaskMultiHashMap.Value{ .http = .{
                .request = try request_builder.toOwned(main.client.allocator),
                .result = .none,
            } };

            return error.WouldBlock;
        }

        const create_http_task = switch (create_task_entry.value_ptr.*) {
            .http => |*http_task| http_task,
        };

        const create_task_response = switch (create_http_task.*.result) {
            .none => {
                return error.WouldBlock;
            },
            .@"error" => {
                // XXX: nested errors, better error tracing, etc?
                return error.TaskFailed;
            },
            .response => |response| response,
        };

        const checklist_id = switch (create_task_response.status) {
            .created => blk: {
                const value = std.mem.trim(u8, create_task_response.content, &std.ascii.whitespace);
                const instance_id = try std.fmt.parseInt(model.Checklist.IdFieldValue, value, 10);
                break :blk instance_id;
            },
            else => return error.CreateChecklistFailed,
        };

        // second api request: retrieve checklist data
        const fetch_task_id: task.TaskMultiHashMap.TaskId = 1;
        const fetch_task_entry = try main.client.tasks.getOrPut(main.client.allocator, request_id, fetch_task_id);
        if (!fetch_task_entry.found_existing) {
            // TODO: clean up task_id if the following fails before filling in the value?

            var request_builder: http.RequestBuilder = undefined;
            request_builder.init(request_allocator);

            const request_url = try std.fmt.allocPrint(
                request_allocator,
                "http://localhost:8080/checklist/{}", // TODO: fill in origin based on incoming request or config
                .{ checklist_id },
            );

            try request_builder.setUrl(request_url);
            request_builder.setMethod(.GET);

            fetch_task_entry.value_ptr.* = task.TaskMultiHashMap.Value{ .http = .{
                .request = try request_builder.toOwned(main.client.allocator),
                .result = .none,
            } };

            return error.WouldBlock;
        }

        const fetch_http_task = switch (fetch_task_entry.value_ptr.*) {
            .http => |*http_task| http_task,
        };

        const fetch_task_response = switch (fetch_http_task.*.result) {
            .none => {
                return error.WouldBlock;
            },
            .@"error" => {
                // XXX: nested errors, better error tracing, etc?
                return error.TaskFailed;
            },
            .response => |response| response,
        };

        const checklist = blk: {
            var buffer_stream = std.io.fixedBufferStream(fetch_task_response.content);
            var json_reader = std.json.reader(request_allocator, buffer_stream.reader());
            defer json_reader.deinit();

            const data_parsed = try std.json.parseFromTokenSource(
                model.Checklist.Data,
                request_allocator,
                &json_reader,
                .{},
            );

            defer data_parsed.deinit();

            var checklist: model.Checklist = .{};
            try checklist.init(request_allocator, &data_parsed.value);
            errdefer checklist.deinit(request_allocator);

            break :blk checklist;
        };

        defer checklist.deinit(request_allocator);

        // finally: render checklist template
        const template = @embedFile("./template.html");

        var buffer: std.ArrayListUnmanaged(u8) = .{};
        errdefer buffer.deinit(request_allocator);
        const writer = buffer.writer(request_allocator);

        try zts.print(template, "checklist-list-item", .{
            .id = checklist.data.id,
            .title = checklist.data.title,
        }, writer);

        const output = try buffer.toOwnedSlice(request_allocator);
        defer request_allocator.free(output);

        // XXX
        try response_builder.setHeader("Content-Type", "text/html");
        try response_builder.setContent(std.mem.trim(u8, output, &std.ascii.whitespace));
        return;
    }

    // XXX: parse checklist id
    const checklist_id_index = std.mem.lastIndexOf(u8, request.url, "/") orelse {
        response_builder.setStatus(.bad_request);
        try response_builder.setContent("missing checklist id in request path");
        return;
    };

    const checklist_id = try std.fmt.parseInt(
        model.Checklist.IdFieldValue,
        request.url[(checklist_id_index + 1)..],
        10,
    );

    // switch on request verb
    switch (request.method) {
        // .PATCH => {
        //     // TODO: update checklist
        // },
        .DELETE => {
            const task_id: task.TaskMultiHashMap.TaskId = 0;
            const task_entry = try main.client.tasks.getOrPut(main.client.allocator, request_id, task_id);
            if (!task_entry.found_existing) {
                // TODO: clean up task_id if the following fails before filling in the value?

                var request_builder: http.RequestBuilder = undefined;
                request_builder.init(request_allocator);

                const request_url = try std.fmt.allocPrint(
                    request_allocator,
                    "http://localhost:8080/checklist/{}", // TODO: fill in origin based on incoming request or config
                    .{ checklist_id },
                );
        
                try request_builder.setUrl(request_url);
                request_builder.setMethod(.DELETE);

                task_entry.value_ptr.* = task.TaskMultiHashMap.Value{ .http = .{
                    .request = try request_builder.toOwned(main.client.allocator),
                    .result = .none,
                } };

                return error.WouldBlock;
            }

            const http_task = switch (task_entry.value_ptr.*) {
                .http => |*http_task| http_task,
            };

            const task_response = switch (http_task.*.result) {
                .none => {
                    return error.WouldBlock;
                },
                .@"error" => {
                    // XXX: nested errors, better error tracing, etc?
                    return error.TaskFailed;
                },
                .response => |response| response,
            };

            switch (task_response.status) {
                // HTMX needs 200 OK with empty content for swapping to remove elements
                .no_content => response_builder.setStatus(.ok),
                // default pass-through
                else => response_builder.setStatus(task_response.status),
            }

            try response_builder.setContent(task_response.content);
        },
        else => {
            response_builder.setStatus(.method_not_allowed);
        },
    }
}

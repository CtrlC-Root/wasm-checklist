// Zig
const std = @import("std");

// first-party
const http = @import("../http.zig");
const task = @import("../task.zig");
const main = @import("../main.zig");

// third-party
const model = @import("model");
//const zts = @import("zts");

pub fn view(
    request_allocator: std.mem.Allocator,
    request_id: u32,
    request: *const http.Request,
    response_builder: *http.ResponseBuilder,
) !void {
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

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
    _ = request;

    // retrieve checklists
    const checklists_task_id: task.TaskMultiHashMap.TaskId = 0;
    const checklists_task_entry = try main.client.tasks.getOrPut(main.client.allocator, request_id, checklists_task_id);
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
            .request = try request_builder.toOwned(main.client.allocator),
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
    const template = @embedFile("./template.html");

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
    try zts.print(template, "checklist-form-start", .{}, writer); // XXX: only if authenticated
    try zts.print(template, "footer", .{}, writer); // XXX: only on full page load

    const output = try buffer.toOwnedSlice(request_allocator);
    defer request_allocator.free(output);

    // XXX
    try response_builder.setHeader("Content-Type", "text/html");
    try response_builder.setContent(std.mem.trim(u8, output, &std.ascii.whitespace));
}

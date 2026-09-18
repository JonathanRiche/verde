//! Cursor ACP extensions translated into Verde's existing interaction and tool rows.
const std = @import("std");
const acp = @import("acp.zig");
const types = @import("types.zig");

const Todo = struct { id: []u8, content: []u8, status: []u8 };

pub const State = struct {
    todos: std.ArrayList(Todo) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.todos.items) |todo| {
            allocator.free(todo.id);
            allocator.free(todo.content);
            allocator.free(todo.status);
        }
        self.todos.deinit(allocator);
        self.* = .{};
    }
};

/// Returns whether the message belongs to the Cursor extension namespace.
pub fn handle(allocator: std.mem.Allocator, value: std.json.Value, request: types.SendPromptRequest, state: *State, stdin: ?std.Io.File) !bool {
    const method = acp.getOptionalObjectString(value, "method") orelse return false;
    if (!std.mem.startsWith(u8, method, "cursor/")) return false;
    const params = acp.getObjectField(value, "params") orelse .null;
    const request_id = acp.serverRequestId(value);
    if (request_id != null and (std.mem.eql(u8, method, "cursor/ask_question") or std.mem.eql(u8, method, "cursor/create_plan"))) {
        const id = request_id.?;
        const response = if (std.mem.eql(u8, method, "cursor/ask_question"))
            try questionResponseAlloc(allocator, id, params, request)
        else
            try planResponseAlloc(allocator, id, params, request);
        defer allocator.free(response);
        if (stdin) |file| try acp.writeJsonLineToFile(allocator, file, response);
        return true;
    }
    if (std.mem.eql(u8, method, "cursor/update_todos")) {
        try updateTodos(allocator, params, request, state);
    } else if (std.mem.eql(u8, method, "cursor/task")) {
        emitTool(request, params, "Subagent task", .subagent, acp.getOptionalObjectString(params, "description") orelse "", .completed);
    } else if (std.mem.eql(u8, method, "cursor/generate_image")) {
        const description = acp.getOptionalObjectString(params, "description") orelse "Generated image";
        const path = acp.getOptionalObjectString(params, "filePath");
        const body = if (path) |p| try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ description, p }) else try allocator.dupe(u8, description);
        defer allocator.free(body);
        emitTool(request, params, "Generated image", .other, body, .completed);
    }
    // Cursor's CLI currently uses extMethod (a request with an ID) even for
    // the non-blocking notifications documented on its ACP reference page.
    // Render both forms, and acknowledge requests so its pending map drains.
    if (request_id) |id| {
        const response = try notificationResponseAlloc(allocator, id, method, params, state);
        defer allocator.free(response);
        if (stdin) |file| try acp.writeJsonLineToFile(allocator, file, response);
    }
    return true;
}

fn notificationResponseAlloc(allocator: std.mem.Allocator, id: std.json.Value, method: []const u8, params: std.json.Value, state: *const State) ![]u8 {
    if (std.mem.eql(u8, method, "cursor/update_todos")) {
        return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .result = .{ .outcome = .{ .outcome = "accepted", .todos = state.todos.items } } }, .{});
    }
    if (std.mem.eql(u8, method, "cursor/task")) return outcomeAlloc(allocator, id, "completed");
    if (std.mem.eql(u8, method, "cursor/generate_image")) {
        if (acp.getOptionalObjectString(params, "filePath")) |path| {
            return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .result = .{ .outcome = .{ .outcome = "generated", .filePath = path } } }, .{});
        }
        return outcomeAlloc(allocator, id, "rejected");
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32601), .message = "Unsupported Cursor extension" } }, .{});
}

fn stopped(request: types.SendPromptRequest) bool {
    return if (request.on_should_stop) |callback| callback(request.stream_context) else false;
}

fn outcomeAlloc(allocator: std.mem.Allocator, id: std.json.Value, outcome: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .result = .{ .outcome = .{ .outcome = outcome } } }, .{});
}

fn planResponseAlloc(allocator: std.mem.Allocator, id: std.json.Value, params: std.json.Value, request: types.SendPromptRequest) ![]u8 {
    const plan = acp.getOptionalObjectString(params, "plan") orelse return outcomeAlloc(allocator, id, "rejected");
    const title = acp.getOptionalObjectString(params, "name") orelse "Cursor plan approval";
    emitTool(request, params, title, .other, plan, .in_progress);
    const call_id = try std.json.Stringify.valueAlloc(allocator, id, .{});
    defer allocator.free(call_id);
    // Plan approval is a user decision even when tool permissions are disabled.
    const decision = if (!stopped(request)) decision: {
        const callback = request.on_approval_request orelse break :decision types.ApprovalDecision.deny;
        break :decision callback(request.stream_context, .{ .call_id = call_id, .title = title, .body = plan });
    } else types.ApprovalDecision.deny;
    const cancelled = stopped(request);
    emitTool(request, params, title, .other, plan, if (decision == .approve and !cancelled) .completed else .cancelled);
    return outcomeAlloc(allocator, id, if (cancelled) "cancelled" else if (decision == .approve) "accepted" else "rejected");
}

fn questionResponseAlloc(allocator: std.mem.Allocator, id: std.json.Value, params: std.json.Value, request: types.SendPromptRequest) ![]u8 {
    if (stopped(request)) return outcomeAlloc(allocator, id, "cancelled");
    const callback = request.on_approval_request orelse return outcomeAlloc(allocator, id, "skipped");
    const questions = acp.getObjectField(params, "questions") orelse return outcomeAlloc(allocator, id, "skipped");
    if (questions != .array or questions.array.items.len == 0) return outcomeAlloc(allocator, id, "skipped");
    const Answer = struct { questionId: []const u8, selectedOptionIds: []const []const u8 };
    var answers: std.ArrayList(Answer) = .empty;
    defer {
        for (answers.items) |answer| allocator.free(answer.selectedOptionIds);
        answers.deinit(allocator);
    }
    for (questions.array.items, 0..) |question, question_index| {
        const question_id = acp.getOptionalObjectString(question, "id") orelse return outcomeAlloc(allocator, id, "skipped");
        const prompt = acp.getOptionalObjectString(question, "prompt") orelse return outcomeAlloc(allocator, id, "skipped");
        const options = acp.getObjectField(question, "options") orelse return outcomeAlloc(allocator, id, "skipped");
        if (options != .array) return outcomeAlloc(allocator, id, "skipped");
        const multiple = acp.getOptionalObjectBool(question, "allowMultiple") orelse false;
        var selected: std.ArrayList([]const u8) = .empty;
        defer selected.deinit(allocator);
        for (options.array.items, 0..) |option, option_index| {
            if (stopped(request)) return outcomeAlloc(allocator, id, "cancelled");
            const option_id = acp.getOptionalObjectString(option, "id") orelse continue;
            const label = acp.getOptionalObjectString(option, "label") orelse continue;
            var body: std.Io.Writer.Allocating = .init(allocator);
            defer body.deinit();
            // Keep the current choice first: the existing approval card clips
            // long bodies, while Copy exposes the complete question/options.
            try body.writer.print("Select: {s}\nAllow selects this option. Decline skips it.{s}\n\n{s}\n\n", .{ label, if (multiple) " You can select more than one." else "", prompt });
            for (options.array.items, 0..) |choice, index| {
                try body.writer.print("{d}. {s}\n", .{ index + 1, acp.getOptionalObjectString(choice, "label") orelse "" });
            }
            const call_id = try std.json.Stringify.valueAlloc(allocator, .{ id, question_index, option_index }, .{});
            defer allocator.free(call_id);
            const decision = callback(request.stream_context, .{ .call_id = call_id, .title = acp.getOptionalObjectString(params, "title") orelse "Cursor question", .body = body.written() });
            if (stopped(request)) return outcomeAlloc(allocator, id, "cancelled");
            if (decision == .approve) {
                try selected.append(allocator, option_id);
                if (!multiple) break;
            }
        }
        if (selected.items.len == 0) return outcomeAlloc(allocator, id, "skipped");
        const owned = try selected.toOwnedSlice(allocator);
        errdefer allocator.free(owned);
        try answers.append(allocator, .{ .questionId = question_id, .selectedOptionIds = owned });
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .result = .{ .outcome = .{ .outcome = "answered", .answers = answers.items } } }, .{});
}

fn emitTool(request: types.SendPromptRequest, params: std.json.Value, title: []const u8, kind: types.ToolCallKind, output: []const u8, status: types.ToolCallStatus) void {
    const callback = request.on_stream_event orelse return;
    callback(request.stream_context, .{ .tool_call = .{
        .call_id = acp.getOptionalObjectString(params, "toolCallId") orelse "cursor-extension",
        .title = title,
        .kind = kind,
        .status = status,
        .output = output,
    } });
}

fn updateTodos(allocator: std.mem.Allocator, params: std.json.Value, request: types.SendPromptRequest, state: *State) !void {
    const todos = acp.getObjectField(params, "todos") orelse return;
    if (todos != .array) return;
    if (!(acp.getOptionalObjectBool(params, "merge") orelse false)) state.deinit(allocator);
    for (todos.array.items) |item| {
        const id = acp.getOptionalObjectString(item, "id") orelse continue;
        const content = acp.getOptionalObjectString(item, "content") orelse continue;
        const status = acp.getOptionalObjectString(item, "status") orelse "pending";
        const copy_id = try allocator.dupe(u8, id);
        errdefer allocator.free(copy_id);
        const copy_content = try allocator.dupe(u8, content);
        errdefer allocator.free(copy_content);
        const copy_status = try allocator.dupe(u8, status);
        errdefer allocator.free(copy_status);
        const todo: Todo = .{ .id = copy_id, .content = copy_content, .status = copy_status };
        var replaced = false;
        for (state.todos.items) |*old| {
            if (!std.mem.eql(u8, old.id, id)) continue;
            allocator.free(old.id);
            allocator.free(old.content);
            allocator.free(old.status);
            old.* = todo;
            replaced = true;
            break;
        }
        if (!replaced) try state.todos.append(allocator, todo);
    }
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    for (state.todos.items) |todo| try body.writer.print("- [{s}] {s}\n", .{ todo.status, todo.content });
    if (request.on_stream_event) |callback| callback(request.stream_context, .{ .tool_call = .{ .call_id = "cursor-todos", .title = "Plan progress", .kind = .other, .status = .completed, .output = body.written() } });
}

const TestInteraction = struct {
    calls: usize = 0,
    decisions: []const types.ApprovalDecision = &.{},
    cancel_after: ?usize = null,

    fn approve(context: ?*anyopaque, _: types.ApprovalRequest) types.ApprovalDecision {
        const self: *TestInteraction = @ptrCast(@alignCast(context.?));
        const index = self.calls;
        self.calls += 1;
        return if (index < self.decisions.len) self.decisions[index] else .deny;
    }

    fn shouldStop(context: ?*anyopaque) bool {
        const self: *TestInteraction = @ptrCast(@alignCast(context.?));
        return if (self.cancel_after) |limit| self.calls >= limit else false;
    }

    fn request(self: *TestInteraction) types.SendPromptRequest {
        return .{ .prompt = "test", .stream_context = self, .approval_policy = .never, .on_approval_request = approve, .on_should_stop = shouldStop };
    }
};

test "Cursor questions preserve option IDs and allow multiple selections" {
    const allocator = std.testing.allocator;
    var params = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"questions":[{"id":"q1","prompt":"Which?","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}]},{"id":"q2","prompt":"Several?","allowMultiple":true,"options":[{"id":"c","label":"C"},{"id":"d","label":"D"}]}]}
    , .{});
    defer params.deinit();
    var interaction: TestInteraction = .{ .decisions = &.{ .deny, .approve, .approve, .approve } };
    const response = try questionResponseAlloc(allocator, .{ .string = "request-3" }, params.value, interaction.request());
    defer allocator.free(response);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":"request-3","result":{"outcome":{"outcome":"answered","answers":[{"questionId":"q1","selectedOptionIds":["b"]},{"questionId":"q2","selectedOptionIds":["c","d"]}]}}}
    , response);
    try std.testing.expectEqual(@as(usize, 4), interaction.calls);
}

test "Cursor questions skip declined choices and cancel stopped turns" {
    const allocator = std.testing.allocator;
    var params = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"questions":[{"id":"q","prompt":"Which?","options":[{"id":"a","label":"A"}]}]}
    , .{});
    defer params.deinit();
    var interaction: TestInteraction = .{};
    const skipped = try questionResponseAlloc(allocator, .{ .integer = 1 }, params.value, interaction.request());
    defer allocator.free(skipped);
    try std.testing.expect(std.mem.indexOf(u8, skipped, "skipped") != null);
    interaction = .{ .decisions = &.{.approve}, .cancel_after = 1 };
    const cancelled = try questionResponseAlloc(allocator, .{ .integer = 1 }, params.value, interaction.request());
    defer allocator.free(cancelled);
    try std.testing.expect(std.mem.indexOf(u8, cancelled, "cancelled") != null);
    const no_ui = try questionResponseAlloc(allocator, .{ .integer = 1 }, params.value, .{ .prompt = "test" });
    defer allocator.free(no_ui);
    try std.testing.expect(std.mem.indexOf(u8, no_ui, "skipped") != null);
}

test "Cursor plan approval remains explicit with automatic tool permissions" {
    const allocator = std.testing.allocator;
    var params = try std.json.parseFromSlice(std.json.Value, allocator, "{\"plan\":\"Do the work\"}", .{});
    defer params.deinit();
    for ([_]types.ApprovalDecision{ .approve, .deny }) |decision| {
        var interaction: TestInteraction = .{ .decisions = &.{decision} };
        const response = try planResponseAlloc(allocator, .{ .integer = 3 }, params.value, interaction.request());
        defer allocator.free(response);
        try std.testing.expectEqual(@as(usize, 1), interaction.calls);
        try std.testing.expect(std.mem.indexOf(u8, response, if (decision == .approve) "accepted" else "rejected") != null);
    }
}

test "Cursor todo notifications merge by ID and replace snapshots" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(allocator);
    const updates = [_][]const u8{
        \\{"todos":[{"id":"1","content":"Read","status":"pending"},{"id":"2","content":"Build","status":"pending"}],"merge":false}
        ,
        \\{"todos":[{"id":"1","content":"Read","status":"completed"}],"merge":true}
        ,
        \\{"todos":[],"merge":false}
        ,
    };
    for (updates, 0..) |update, index| {
        var params = try std.json.parseFromSlice(std.json.Value, allocator, update, .{});
        defer params.deinit();
        try updateTodos(allocator, params.value, .{ .prompt = "test" }, &state);
        try std.testing.expectEqual(@as(usize, if (index == 2) 0 else 2), state.todos.items.len);
        if (index == 1) try std.testing.expectEqualStrings("completed", state.todos.items[0].status);
    }
}

test "Cursor task and image notifications emit completed tool rows" {
    const Capture = struct {
        count: usize = 0,
        subagents: usize = 0,
        saw_path: bool = false,
        fn event(context: ?*anyopaque, update: types.StreamEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (update != .tool_call) return;
            self.count += 1;
            if (update.tool_call.kind == .subagent) self.subagents += 1;
            if (update.tool_call.output) |output| self.saw_path = self.saw_path or std.mem.indexOf(u8, output, "/tmp/image.png") != null;
        }
    };
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(allocator);
    var capture: Capture = .{};
    for ([_][]const u8{
        \\{"method":"cursor/task","params":{"toolCallId":"t1","description":"Explore the code","agentId":"a1"}}
        ,
        \\{"method":"cursor/generate_image","params":{"toolCallId":"i1","description":"App icon","filePath":"/tmp/image.png"}}
        ,
    }) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(try handle(allocator, parsed.value, .{ .prompt = "test", .stream_context = &capture, .on_stream_event = Capture.event }, &state, null));
    }
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(@as(usize, 1), capture.subagents);
    try std.testing.expect(capture.saw_path);
}

test "Cursor notification requests render progress and receive acknowledgements" {
    const Capture = struct {
        count: usize = 0,
        fn event(context: ?*anyopaque, update: types.StreamEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (update == .tool_call) self.count += 1;
        }
    };
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output = try tmp.dir.createFile(std.testing.io, "responses", .{});
    defer output.close(std.testing.io);
    var state: State = .{};
    defer state.deinit(allocator);
    var capture: Capture = .{};
    for ([_][]const u8{
        \\{"id":11,"method":"cursor/update_todos","params":{"toolCallId":"t1","todos":[{"id":"alpha","content":"Check alpha","status":"completed"}],"merge":false}}
        ,
        \\{"id":"task-12","method":"cursor/task","params":{"toolCallId":"t2","description":"Inspect"}}
        ,
        \\{"id":13,"method":"cursor/generate_image","params":{"toolCallId":"t3","filePath":"/tmp/icon.png"}}
        ,
    }) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(try handle(allocator, parsed.value, .{ .prompt = "test", .stream_context = &capture, .on_stream_event = Capture.event }, &state, output));
    }
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    const responses = try tmp.dir.readFileAlloc(std.testing.io, "responses", allocator, .limited(4096));
    defer allocator.free(responses);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":11,"result":{"outcome":{"outcome":"accepted","todos":[{"id":"alpha","content":"Check alpha","status":"completed"}]}}}
        \\{"jsonrpc":"2.0","id":"task-12","result":{"outcome":{"outcome":"completed"}}}
        \\{"jsonrpc":"2.0","id":13,"result":{"outcome":{"outcome":"generated","filePath":"/tmp/icon.png"}}}
        \\
    , responses);
}

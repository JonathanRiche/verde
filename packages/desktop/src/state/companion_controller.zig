//! Bounded presentation state for the pane-less Companion thread.

const std = @import("std");
const palette = @import("palette");

const Self = @This();

pub const Visibility = enum {
    collapsed_chip,
    sidecar_open,
};

pub const RunPhase = enum {
    idle,
    working,
    paused,
};

pub const FixtureState = enum {
    idle,
    working,
    needs_approval,
    paused,
    failed,
};

pub const Pose = enum {
    idle,
    working,
    approval,
    paused,
};

pub const VisualState = struct {
    pose: Pose,
    show_approval: bool,
    show_failure: bool,
};

pub const HitAction = enum {
    open,
    collapse,
    panel,
    body,
    run_tab,
    activity_tab,
    approve,
    deny,
};

pub const Hit = struct {
    rect: palette.Rect,
    action: HitAction,
};

pub const PointerButtonResult = struct {
    consumed: bool = false,
    action: ?HitAction = null,
};

const PRESENTATION_TEXT_CAPACITY = 512;
pub const MAX_OPERATIONS: usize = 32;
pub const MAX_ACTIVITY: usize = 64;

pub const PresentationText = struct {
    storage: [PRESENTATION_TEXT_CAPACITY:0]u8 = std.mem.zeroes([PRESENTATION_TEXT_CAPACITY:0]u8),

    pub fn set(self: *PresentationText, value: []const u8) void {
        const len = @min(value.len, self.storage.len - 1);
        @memcpy(self.storage[0..len], value[0..len]);
        self.storage[len] = 0;
    }

    pub fn slice(self: *const PresentationText) []const u8 {
        return std.mem.sliceTo(self.storage[0..], 0);
    }

    /// Writes a stable namespaced identity only when every component is
    /// losslessly representable; rejected identities leave the value intact.
    pub fn setIdentity(self: *PresentationText, namespace: []const u8, parts: []const []const u8) bool {
        const max_len = self.storage.len - 1;
        if (namespace.len == 0 or std.mem.indexOfScalar(u8, namespace, 0) != null or namespace.len > max_len) return false;
        var total_len = namespace.len;
        for (parts) |part| {
            if (part.len == 0 or std.mem.indexOfScalar(u8, part, 0) != null) return false;
            const digits = decimalDigitCount(part.len);
            if (digits + 2 > max_len - total_len) return false;
            total_len += digits + 2;
            if (part.len > max_len - total_len) return false;
            total_len += part.len;
        }
        var cursor: usize = 0;
        @memcpy(self.storage[cursor..][0..namespace.len], namespace);
        cursor += namespace.len;
        for (parts) |part| {
            self.storage[cursor] = ':';
            cursor += 1;
            const digits = decimalDigitCount(part.len);
            writeDecimal(self.storage[cursor..][0..digits], part.len);
            cursor += digits;
            self.storage[cursor] = ':';
            cursor += 1;
            @memcpy(self.storage[cursor..][0..part.len], part);
            cursor += part.len;
        }
        self.storage[cursor] = 0;
        return true;
    }

    fn decimalDigitCount(value: usize) usize {
        var remaining = value;
        var count: usize = 1;
        while (remaining >= 10) : (count += 1) remaining /= 10;
        return count;
    }

    fn writeDecimal(buffer: []u8, value: usize) void {
        var remaining = value;
        var index = buffer.len;
        while (index > 0) {
            index -= 1;
            buffer[index] = '0' + @as(u8, @intCast(remaining % 10));
            remaining /= 10;
        }
        std.debug.assert(remaining == 0);
    }
};

pub const OperationStatus = enum {
    pending,
    in_progress,
    completed,
    failed,
    cancelled,
};

pub const Operation = struct {
    identity: PresentationText = .{},
    title: PresentationText = .{},
    detail: PresentationText = .{},
    status: OperationStatus = .pending,
    sequence: i64 = 0,
    process: bool = false,

    pub fn active(self: *const Operation) bool {
        return self.status == .pending or self.status == .in_progress;
    }
};

pub const ActivityKind = enum {
    user,
    assistant,
    system,
    tool,
    process,
    streaming,
};

pub const ActivityItem = struct {
    identity: PresentationText = .{},
    author: PresentationText = .{},
    body: PresentationText = .{},
    kind: ActivityKind = .system,
    status: ?OperationStatus = null,
    sequence: i64 = 0,
};

pub const ActiveCounts = struct {
    working: usize = 0,
    pending: usize = 0,
};

pub const Frame = struct {
    workspace_id: PresentationText = .{},
    thread_id: PresentationText = .{},
    has_thread: bool = false,
    has_approval: bool = false,
    has_failure: bool = false,
    working: bool = false,
    objective: PresentationText = .{},
    latest_body: PresentationText = .{},
    partial_text: PresentationText = .{},
    event_author: PresentationText = .{},
    event_body: PresentationText = .{},
    approval_identity: PresentationText = .{},
    approval_title: PresentationText = .{},
    approval_body: PresentationText = .{},
    provider_error: PresentationText = .{},
    control_error: PresentationText = .{},
    ui_error: PresentationText = .{},
    operations: [MAX_OPERATIONS]Operation = [_]Operation{.{}} ** MAX_OPERATIONS,
    operation_count: usize = 0,
    activity: [MAX_ACTIVITY]ActivityItem = [_]ActivityItem{.{}} ** MAX_ACTIVITY,
    activity_count: usize = 0,

    pub fn upsertOperation(self: *Frame, operation: Operation) void {
        const identity = operation.identity.slice();
        if (identity.len > 0) {
            for (self.operations[0..self.operation_count]) |*existing| {
                if (!std.mem.eql(u8, existing.identity.slice(), identity)) continue;
                const preserved_sequence = existing.sequence;
                existing.* = operation;
                existing.sequence = preserved_sequence;
                return;
            }
        }
        if (self.operation_count < self.operations.len) {
            self.operations[self.operation_count] = operation;
            self.operation_count += 1;
            return;
        }
        var replace_index: ?usize = null;
        for (self.operations[0..self.operation_count], 0..) |existing, index| {
            if (existing.active()) continue;
            if (replace_index == null or existing.sequence < self.operations[replace_index.?].sequence) replace_index = index;
        }
        if (replace_index) |index| {
            if (operation.active() or operation.sequence > self.operations[index].sequence) self.operations[index] = operation;
        }
    }

    pub fn sortOperations(self: *Frame) void {
        var index: usize = 1;
        while (index < self.operation_count) : (index += 1) {
            const value = self.operations[index];
            var insertion = index;
            while (insertion > 0 and operationBefore(value, self.operations[insertion - 1])) : (insertion -= 1) {
                self.operations[insertion] = self.operations[insertion - 1];
            }
            self.operations[insertion] = value;
        }
    }

    pub fn appendActivity(self: *Frame, item: ActivityItem) void {
        const identity = item.identity.slice();
        if (identity.len > 0) {
            for (self.activity[0..self.activity_count]) |*existing| {
                if (!std.mem.eql(u8, existing.identity.slice(), identity)) continue;
                const preserved_sequence = existing.sequence;
                existing.* = item;
                existing.sequence = preserved_sequence;
                return;
            }
        }
        if (self.activity_count == self.activity.len) {
            var oldest_index: usize = 0;
            for (self.activity[1..self.activity_count], 1..) |existing, index| {
                if (existing.sequence < self.activity[oldest_index].sequence) oldest_index = index;
            }
            if (item.sequence > self.activity[oldest_index].sequence) self.activity[oldest_index] = item;
            return;
        }
        self.activity[self.activity_count] = item;
        self.activity_count += 1;
    }

    pub fn sortActivity(self: *Frame) void {
        var index: usize = 1;
        while (index < self.activity_count) : (index += 1) {
            const value = self.activity[index];
            var insertion = index;
            while (insertion > 0 and value.sequence < self.activity[insertion - 1].sequence) : (insertion -= 1) {
                self.activity[insertion] = self.activity[insertion - 1];
            }
            self.activity[insertion] = value;
        }
    }

    pub fn activeCounts(self: *const Frame) ActiveCounts {
        var result: ActiveCounts = .{};
        for (self.operations[0..self.operation_count]) |operation| switch (operation.status) {
            .in_progress => result.working += 1,
            .pending => result.pending += 1,
            else => {},
        };
        return result;
    }

    pub fn recentCount(self: *const Frame) usize {
        var count: usize = 0;
        for (self.operations[0..self.operation_count]) |operation| if (!operation.active()) {
            count += 1;
        };
        return count;
    }
};

pub const Presentation = Frame;

pub const Tab = enum { run, activity };

visibility: Visibility = .collapsed_chip,
run_phase: RunPhase = .working,
needs_approval: bool = true,
has_failure: bool = false,
status_text: []const u8 = "Approval needed",
operation_count: usize = 3,
approval_count: usize = 1,
ui_error: ?[]const u8 = null,
presentation: Presentation = .{},
selected_tab: Tab = .run,
frame_width: f32 = 0.0,
frame_height: f32 = 0.0,
hits: [10]Hit = undefined,
hit_count: usize = 0,
body_scroll_y: f32 = 0.0,
activity_scroll_y: f32 = 0.0,
activity_max_scroll: f32 = 0.0,
activity_content_count: usize = 0,
activity_follow_tail: bool = true,
pointer_captured_buttons: [256]bool = [_]bool{false} ** 256,
escape_key_captured: bool = false,

pub fn init() Self {
    return .{};
}

pub fn toggle(self: *Self) void {
    self.visibility = switch (self.visibility) {
        .collapsed_chip => .sidecar_open,
        .sidecar_open => .collapsed_chip,
    };
}

pub fn show(self: *Self) void {
    self.visibility = .sidecar_open;
}

pub fn collapse(self: *Self) void {
    self.visibility = .collapsed_chip;
}

pub fn handleEscapeKey(self: *Self, down: bool) bool {
    if (!down) {
        if (!self.escape_key_captured) return false;
        self.escape_key_captured = false;
        return true;
    }
    if (self.escape_key_captured) return true;
    if (self.visibility != .sidecar_open) return false;
    self.escape_key_captured = true;
    self.collapse();
    return true;
}

pub fn ownsEscapeKey(self: *const Self) bool {
    return self.escape_key_captured;
}

pub fn handlePointerButton(self: *Self, x: f32, y: f32, button: u8, down: bool) PointerButtonResult {
    if (!down) {
        if (self.pointer_captured_buttons[button]) {
            self.pointer_captured_buttons[button] = false;
            return .{ .consumed = true };
        }
        return .{ .consumed = self.hitAt(x, y) != null };
    }

    const action = self.hitAt(x, y) orelse return .{};
    if (self.pointer_captured_buttons[button]) return .{ .consumed = true };
    self.pointer_captured_buttons[button] = true;
    return .{
        .consumed = true,
        .action = if (button == 1) action else null,
    };
}

pub fn ownsPointerButton(self: *const Self, button: u8) bool {
    return self.pointer_captured_buttons[button];
}

pub fn hasPointerCapture(self: *const Self) bool {
    for (self.pointer_captured_buttons) |captured| if (captured) return true;
    return false;
}

pub fn ownsPointerRelease(self: *const Self, button: u8) bool {
    return self.ownsPointerButton(button);
}

pub fn resetInputCaptures(self: *Self) void {
    self.pointer_captured_buttons = [_]bool{false} ** 256;
    self.escape_key_captured = false;
}

pub fn visualState(self: *const Self) VisualState {
    const pose: Pose = if (self.run_phase == .paused)
        .paused
    else if (self.needs_approval)
        .approval
    else switch (self.run_phase) {
        .idle => .idle,
        .working => .working,
        .paused => unreachable,
    };
    return .{
        .pose = pose,
        .show_approval = self.needs_approval,
        .show_failure = self.has_failure,
    };
}

pub fn applyFixture(self: *Self, fixture: FixtureState) void {
    switch (fixture) {
        .idle => self.setSemantic(.idle, false, false, "Ready", 0, 0),
        .working => self.setSemantic(.working, false, false, "Working", 3, 0),
        .needs_approval => self.setSemantic(.working, true, false, "Approval needed", 3, 1),
        .paused => self.setSemantic(.paused, true, false, "Paused", 3, 1),
        .failed => self.setSemantic(.idle, false, true, "Needs attention", 3, 0),
    }
}

pub fn applyActivity(self: *Self, activity: enum { idle, working, waiting, failed }) void {
    switch (activity) {
        .idle => self.setSemantic(.idle, false, false, "Ready", 0, 0),
        .working => self.setSemantic(.working, false, false, "Working", 1, 0),
        .waiting => self.setSemantic(.working, true, false, "Approval needed", 1, 1),
        .failed => self.setSemantic(.idle, false, true, "Needs attention", 0, 0),
    }
}

pub fn applyProjection(self: *Self, phase: RunPhase, needs_approval: bool, has_failure: bool) void {
    self.setSemantic(
        phase,
        needs_approval,
        has_failure,
        if (has_failure) "Needs attention" else if (needs_approval) "Approval needed" else if (phase == .working) "Working" else "Ready",
        if (phase == .idle) 0 else 1,
        if (needs_approval) 1 else 0,
    );
}

pub fn setFrame(self: *Self, frame: Frame) void {
    const identity_changed = !std.mem.eql(u8, self.presentation.workspace_id.slice(), frame.workspace_id.slice()) or
        !std.mem.eql(u8, self.presentation.thread_id.slice(), frame.thread_id.slice());
    if (identity_changed) {
        self.selected_tab = .run;
        self.body_scroll_y = 0.0;
        self.activity_scroll_y = 0.0;
        self.activity_max_scroll = 0.0;
        self.activity_content_count = 0;
        self.activity_follow_tail = true;
    }
    self.presentation = frame;
    self.applyProjection(
        if (frame.working) .working else .idle,
        frame.has_approval,
        frame.has_failure,
    );
    self.operation_count = frame.activeCounts().working + frame.activeCounts().pending;
}

pub fn selectTab(self: *Self, tab: Tab) void {
    self.selected_tab = tab;
}

pub fn currentScrollY(self: *const Self) f32 {
    return if (self.selected_tab == .activity) self.activity_scroll_y else self.body_scroll_y;
}

pub fn scrollCurrent(self: *Self, delta: f32, max_scroll: f32) void {
    if (self.selected_tab == .activity) {
        self.activity_scroll_y = std.math.clamp(self.activity_scroll_y + delta, 0.0, max_scroll);
        self.activity_max_scroll = max_scroll;
        self.activity_follow_tail = max_scroll - self.activity_scroll_y <= 2.0;
    } else {
        self.body_scroll_y = std.math.clamp(self.body_scroll_y + delta, 0.0, max_scroll);
    }
}

pub fn updateActivityExtent(self: *Self, max_scroll: f32) void {
    const grew = self.presentation.activity_count > self.activity_content_count;
    const was_at_tail = self.activity_follow_tail or self.activity_max_scroll - self.activity_scroll_y <= 2.0;
    if (grew and was_at_tail) {
        self.activity_scroll_y = max_scroll;
    } else {
        self.activity_scroll_y = std.math.clamp(self.activity_scroll_y, 0.0, max_scroll);
    }
    self.activity_follow_tail = was_at_tail and max_scroll - self.activity_scroll_y <= 2.0;
    self.activity_max_scroll = max_scroll;
    self.activity_content_count = self.presentation.activity_count;
}

pub fn clearHits(self: *Self) void {
    self.hit_count = 0;
}

pub fn clearApprovalHits(self: *Self) void {
    var write_index: usize = 0;
    for (self.hits[0..self.hit_count]) |hit| {
        if (hit.action == .approve or hit.action == .deny) continue;
        self.hits[write_index] = hit;
        write_index += 1;
    }
    self.hit_count = write_index;
}

pub fn addHit(self: *Self, rect: palette.Rect, action: HitAction) void {
    std.debug.assert(self.hit_count < self.hits.len);
    self.hits[self.hit_count] = .{ .rect = rect, .action = action };
    self.hit_count += 1;
}

pub fn hitAt(self: *const Self, x: f32, y: f32) ?HitAction {
    var index = self.hit_count;
    while (index > 0) {
        index -= 1;
        const hit = self.hits[index];
        if (pointInRect(hit.rect, x, y)) return hit.action;
    }
    return null;
}

fn setSemantic(
    self: *Self,
    phase: RunPhase,
    needs_approval: bool,
    has_failure: bool,
    status_text: []const u8,
    operation_count: usize,
    approval_count: usize,
) void {
    self.run_phase = phase;
    self.needs_approval = needs_approval;
    self.has_failure = has_failure;
    self.status_text = status_text;
    self.operation_count = operation_count;
    self.approval_count = approval_count;
}

fn pointInRect(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn operationBefore(left: Operation, right: Operation) bool {
    const left_rank: u8 = switch (left.status) {
        .in_progress => 0,
        .pending => 1,
        else => 2,
    };
    const right_rank: u8 = switch (right.status) {
        .in_progress => 0,
        .pending => 1,
        else => 2,
    };
    if (left_rank != right_rank) return left_rank < right_rank;
    return if (left_rank < 2) left.sequence < right.sequence else left.sequence > right.sequence;
}

fn testOperation(identity: []const u8, status: OperationStatus, sequence: i64) Operation {
    var operation: Operation = .{ .status = status, .sequence = sequence };
    operation.identity.set(identity);
    operation.title.set("Ran command");
    operation.detail.set("echo test");
    return operation;
}

test "operation identity upserts across lifecycle and moves from Active to Recent" {
    var frame: Frame = .{};
    frame.upsertOperation(testOperation("call-1", .pending, 10));
    frame.upsertOperation(testOperation("call-1", .in_progress, 20));
    try std.testing.expectEqual(@as(usize, 1), frame.operation_count);
    try std.testing.expectEqual(OperationStatus.in_progress, frame.operations[0].status);
    try std.testing.expectEqual(@as(i64, 10), frame.operations[0].sequence);

    frame.upsertOperation(testOperation("call-1", .completed, 30));
    frame.sortOperations();
    try std.testing.expectEqual(@as(usize, 1), frame.operation_count);
    try std.testing.expectEqual(OperationStatus.completed, frame.operations[0].status);
    try std.testing.expectEqual(@as(usize, 0), frame.activeCounts().working + frame.activeCounts().pending);
    try std.testing.expectEqual(@as(usize, 1), frame.recentCount());
}

test "bounded operations prioritize active and activity retains newest chronology" {
    var frame: Frame = .{};
    var id_buffer: [32]u8 = undefined;
    for (0..40) |index| {
        const identity = std.fmt.bufPrint(&id_buffer, "recent-{d}", .{index}) catch unreachable;
        frame.upsertOperation(testOperation(identity, .completed, @intCast(index)));
    }
    for (0..4) |index| {
        const identity = std.fmt.bufPrint(&id_buffer, "active-{d}", .{index}) catch unreachable;
        frame.upsertOperation(testOperation(identity, if (index % 2 == 0) .in_progress else .pending, @intCast(100 + index)));
    }
    frame.sortOperations();
    try std.testing.expectEqual(MAX_OPERATIONS, frame.operation_count);
    try std.testing.expectEqual(@as(usize, 2), frame.activeCounts().working);
    try std.testing.expectEqual(@as(usize, 2), frame.activeCounts().pending);
    try std.testing.expectEqual(OperationStatus.in_progress, frame.operations[0].status);

    for (0..70) |index| {
        var item: ActivityItem = .{ .sequence = @intCast(index) };
        const identity = std.fmt.bufPrint(&id_buffer, "event-{d}", .{index}) catch unreachable;
        item.identity.set(identity);
        frame.appendActivity(item);
    }
    frame.sortActivity();
    try std.testing.expectEqual(MAX_ACTIVITY, frame.activity_count);
    try std.testing.expectEqual(@as(i64, 6), frame.activity[0].sequence);
    try std.testing.expectEqual(@as(i64, 69), frame.activity[MAX_ACTIVITY - 1].sequence);
}

test "activity tail follows once preserves manual offset and rearms within threshold" {
    var state = Self.init();
    var frame: Frame = .{ .has_thread = true, .activity_count = 1 };
    frame.workspace_id.set("workspace");
    frame.thread_id.set("thread");
    state.setFrame(frame);
    state.selectTab(.activity);
    state.updateActivityExtent(100.0);
    try std.testing.expectEqual(@as(f32, 100.0), state.activity_scroll_y);

    frame.activity_count = 2;
    state.setFrame(frame);
    state.updateActivityExtent(200.0);
    try std.testing.expectEqual(@as(f32, 200.0), state.activity_scroll_y);
    state.scrollCurrent(-50.0, 200.0);
    try std.testing.expectEqual(@as(f32, 150.0), state.activity_scroll_y);
    try std.testing.expect(!state.activity_follow_tail);

    frame.activity_count = 3;
    state.setFrame(frame);
    state.updateActivityExtent(300.0);
    try std.testing.expectEqual(@as(f32, 150.0), state.activity_scroll_y);
    state.scrollCurrent(149.0, 300.0);
    try std.testing.expect(state.activity_follow_tail);
    frame.activity_count = 4;
    state.setFrame(frame);
    state.updateActivityExtent(400.0);
    try std.testing.expectEqual(@as(f32, 400.0), state.activity_scroll_y);
}

test "tab and scroll memory survive hide while owner identity replacement resets" {
    var state = Self.init();
    var frame: Frame = .{ .has_thread = true };
    frame.workspace_id.set("workspace-a");
    frame.thread_id.set("thread-a");
    state.setFrame(frame);
    state.selectTab(.activity);
    state.activity_scroll_y = 42.0;
    state.collapse();
    state.show();
    state.setFrame(frame);
    try std.testing.expectEqual(Tab.activity, state.selected_tab);
    try std.testing.expectEqual(@as(f32, 42.0), state.activity_scroll_y);

    frame.thread_id.set("thread-b");
    state.setFrame(frame);
    try std.testing.expectEqual(Tab.run, state.selected_tab);
    try std.testing.expectEqual(@as(f32, 0.0), state.activity_scroll_y);
    try std.testing.expect(state.activity_follow_tail);
}

test "visibility transitions are idempotent and preserve semantic state" {
    var state = Self.init();
    state.applyFixture(.paused);
    const semantic_before = state.visualState();
    const status_before = state.status_text;
    const operations_before = state.operation_count;

    state.show();
    state.show();
    try std.testing.expectEqual(Visibility.sidecar_open, state.visibility);
    state.collapse();
    state.collapse();
    try std.testing.expectEqual(Visibility.collapsed_chip, state.visibility);
    try std.testing.expectEqualDeep(semantic_before, state.visualState());
    try std.testing.expectEqualStrings(status_before, state.status_text);
    try std.testing.expectEqual(operations_before, state.operation_count);

    state.toggle();
    try std.testing.expectEqual(Visibility.sidecar_open, state.visibility);
    state.toggle();
    try std.testing.expectEqual(Visibility.collapsed_chip, state.visibility);
}

test "fixture mapping and visual precedence are orthogonal" {
    var state = Self.init();
    state.applyFixture(.idle);
    try std.testing.expectEqual(Pose.idle, state.visualState().pose);
    state.applyFixture(.working);
    try std.testing.expectEqual(Pose.working, state.visualState().pose);
    state.applyFixture(.needs_approval);
    try std.testing.expectEqual(Pose.approval, state.visualState().pose);

    state.applyFixture(.paused);
    const paused = state.visualState();
    try std.testing.expectEqual(Pose.paused, paused.pose);
    try std.testing.expect(paused.show_approval);

    state.applyFixture(.failed);
    try std.testing.expect(state.visualState().show_failure);
    inline for (.{ RunPhase.idle, RunPhase.working, RunPhase.paused }) |phase| {
        state.run_phase = phase;
        try std.testing.expect(state.visualState().show_failure);
    }
}

test "authoritative thread activity projects without changing visibility" {
    var state = Self.init();
    state.visibility = .collapsed_chip;
    state.applyActivity(.working);
    try std.testing.expectEqual(RunPhase.working, state.run_phase);
    try std.testing.expect(!state.needs_approval);
    state.applyActivity(.waiting);
    try std.testing.expect(state.needs_approval);
    state.applyActivity(.failed);
    try std.testing.expect(state.has_failure);
    try std.testing.expectEqual(Visibility.collapsed_chip, state.visibility);
}

test "collapse cannot express runtime cancellation" {
    var state = Self.init();
    state.show();
    state.applyFixture(.working);
    state.collapse();
    try std.testing.expectEqual(RunPhase.working, state.run_phase);
    try std.testing.expectEqual(@as(usize, 3), state.operation_count);
}

test "Escape down repeat and up remain one Companion-owned action" {
    var state = Self.init();
    try std.testing.expect(!state.handleEscapeKey(true));
    state.show();
    try std.testing.expect(state.handleEscapeKey(true));
    try std.testing.expectEqual(Visibility.collapsed_chip, state.visibility);
    try std.testing.expect(state.ownsEscapeKey());
    try std.testing.expect(state.handleEscapeKey(true));
    try std.testing.expectEqual(Visibility.collapsed_chip, state.visibility);
    try std.testing.expect(state.handleEscapeKey(false));
    try std.testing.expect(!state.ownsEscapeKey());
    try std.testing.expect(!state.handleEscapeKey(true));
}

test "pointer press captures matching release across visibility and hit changes" {
    var state = Self.init();
    state.addHit(.{ .x = 80.0, .y = 80.0, .w = 20.0, .h = 20.0 }, .open);

    const press = state.handlePointerButton(90.0, 90.0, 1, true);
    try std.testing.expect(press.consumed);
    try std.testing.expectEqual(HitAction.open, press.action.?);
    try std.testing.expect(state.ownsPointerButton(1));

    state.show();
    state.clearHits();
    const release = state.handlePointerButton(5.0, 5.0, 1, false);
    try std.testing.expect(release.consumed);
    try std.testing.expect(!state.ownsPointerButton(1));
    try std.testing.expect(!state.handlePointerButton(5.0, 5.0, 1, false).consumed);
}

test "overlapping pointer buttons independently own releases after collapse" {
    var state = Self.init();
    state.show();
    state.addHit(.{ .x = 80.0, .y = 80.0, .w = 20.0, .h = 20.0 }, .collapse);

    const right_down = state.handlePointerButton(90.0, 90.0, 3, true);
    try std.testing.expect(right_down.consumed);
    try std.testing.expect(right_down.action == null);
    const left_down = state.handlePointerButton(90.0, 90.0, 1, true);
    try std.testing.expect(left_down.consumed);
    try std.testing.expectEqual(HitAction.collapse, left_down.action.?);
    try std.testing.expect(state.ownsPointerButton(1));
    try std.testing.expect(state.ownsPointerButton(3));

    state.collapse();
    state.clearHits();
    try std.testing.expect(state.ownsPointerRelease(1));
    try std.testing.expect(state.ownsPointerRelease(3));
    try std.testing.expect(state.handlePointerButton(5.0, 5.0, 1, false).consumed);
    try std.testing.expect(!state.ownsPointerButton(1));
    try std.testing.expect(state.ownsPointerButton(3));
    try std.testing.expect(state.ownsPointerRelease(3));
    try std.testing.expect(state.handlePointerButton(5.0, 5.0, 3, false).consumed);
    try std.testing.expect(!state.ownsPointerRelease(1));
    try std.testing.expect(!state.ownsPointerRelease(3));
}

test "nonmatching release preserves exact capture and focus loss resets all" {
    var state = Self.init();
    state.addHit(.{ .x = 80.0, .y = 80.0, .w = 20.0, .h = 20.0 }, .open);
    try std.testing.expect(state.handlePointerButton(90.0, 90.0, 3, true).consumed);
    state.clearHits();

    try std.testing.expect(state.ownsPointerRelease(3));
    try std.testing.expect(!state.ownsPointerRelease(1));
    try std.testing.expect(!state.handlePointerButton(5.0, 5.0, 1, false).consumed);
    try std.testing.expect(state.ownsPointerButton(3));
    state.resetInputCaptures();
    try std.testing.expect(!state.ownsPointerRelease(3));
    try std.testing.expect(!state.handlePointerButton(5.0, 5.0, 3, false).consumed);
}

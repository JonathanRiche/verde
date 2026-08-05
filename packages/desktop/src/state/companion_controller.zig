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
    mission_control_open,
    mission_control_close,
    panel,
    body,
    run_tab,
    activity_tab,
    approve,
    deny,
    operation_select,
    operation_stop,
    operation_follow_log,
};

pub const Hit = struct {
    rect: palette.Rect,
    action: HitAction,
    reference: ?OperationReference = null,
};

pub const PointerButtonResult = struct {
    consumed: bool = false,
    action: ?HitAction = null,
    reference: ?OperationReference = null,
};

const PRESENTATION_TEXT_CAPACITY = 512;
const INSPECTOR_TEXT_CAPACITY = 160;
pub const MAX_OPERATIONS: usize = 32;
pub const MAX_ACTIVITY: usize = 64;
pub const MAX_INSPECTOR_FILES: usize = 4;
pub const MAX_INSPECTOR_RESOURCES: usize = 4;

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

/// Value-owned routing text. Unlike presentation text, assignment is all or
/// nothing so a rendered frame can never route through a truncated key.
pub const ExactText = struct {
    storage: [PRESENTATION_TEXT_CAPACITY:0]u8 = std.mem.zeroes([PRESENTATION_TEXT_CAPACITY:0]u8),

    pub fn set(self: *ExactText, value: []const u8) bool {
        if (value.len == 0 or value.len >= self.storage.len or std.mem.indexOfScalar(u8, value, 0) != null) return false;
        var replacement: ExactText = .{};
        @memcpy(replacement.storage[0..value.len], value);
        replacement.storage[value.len] = 0;
        self.* = replacement;
        return true;
    }

    pub fn slice(self: *const ExactText) []const u8 {
        return std.mem.sliceTo(self.storage[0..], 0);
    }

    pub fn eql(self: *const ExactText, other: *const ExactText) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const OptionalExactText = struct {
    present: bool = false,
    value: ExactText = .{},

    pub fn set(self: *OptionalExactText, value: ?[]const u8) bool {
        const raw = value orelse {
            self.* = .{};
            return true;
        };
        var replacement: OptionalExactText = .{ .present = true };
        if (!replacement.value.set(raw)) return false;
        self.* = replacement;
        return true;
    }

    pub fn slice(self: *const OptionalExactText) ?[]const u8 {
        return if (self.present) self.value.slice() else null;
    }
};

pub const OperationOwner = struct {
    workspace_id: ExactText = .{},
    local_thread_id: ExactText = .{},
    valid: bool = false,

    pub fn set(self: *OperationOwner, workspace_id: []const u8, local_thread_id: []const u8) bool {
        var replacement: OperationOwner = .{};
        if (!replacement.workspace_id.set(workspace_id) or !replacement.local_thread_id.set(local_thread_id)) return false;
        replacement.valid = true;
        self.* = replacement;
        return true;
    }

    pub fn eql(self: *const OperationOwner, other: *const OperationOwner) bool {
        return self.valid and other.valid and self.workspace_id.eql(&other.workspace_id) and
            self.local_thread_id.eql(&other.local_thread_id);
    }
};

pub const OperationCategory = enum {
    provider_tool,
    background_task,
};

pub const BackgroundIdentity = union(enum) {
    task_id: ExactText,
    item: struct {
        provider_thread_id: ExactText,
        item_id: ExactText,
    },
    process: struct {
        provider_thread_id: ExactText,
        process_id: ExactText,
    },
    command: ExactText,
};

pub const BackgroundTarget = struct {
    identity: BackgroundIdentity,
    command: ExactText,
    task_id: OptionalExactText = .{},
    item_id: OptionalExactText = .{},
    process_id: OptionalExactText = .{},
    provider_thread_id: OptionalExactText = .{},
    pid_path: OptionalExactText = .{},
    log_path: OptionalExactText = .{},
    pid: ?u32 = null,
    pid_verified: bool = false,
    provider_owned: bool = false,
};

pub const OperationTarget = union(enum) {
    none,
    tool_call: ExactText,
    background_task: BackgroundTarget,
};

pub const SupportedActions = packed struct {
    inspect: bool = true,
    stop: bool = false,
    follow_log: bool = false,
    reveal: bool = false,
    redirect: bool = false,
};

pub const InspectorText = struct {
    storage: [INSPECTOR_TEXT_CAPACITY:0]u8 = std.mem.zeroes([INSPECTOR_TEXT_CAPACITY:0]u8),

    pub fn set(self: *InspectorText, value: []const u8) void {
        const len = @min(value.len, self.storage.len - 1);
        @memcpy(self.storage[0..len], value[0..len]);
        self.storage[len] = 0;
    }

    pub fn slice(self: *const InspectorText) []const u8 {
        return std.mem.sliceTo(self.storage[0..], 0);
    }
};

pub const Inspector = struct {
    owner: InspectorText = .{},
    workspace: InspectorText = .{},
    action: InspectorText = .{},
    target: InspectorText = .{},
    provider: InspectorText = .{},
    cwd: InspectorText = .{},
    state: InspectorText = .{},
    wait_reason: InspectorText = .{},
    failure_reason: InspectorText = .{},
    input: InspectorText = .{},
    output: InspectorText = .{},
    locations: InspectorText = .{},
    raw: InspectorText = .{},
    files: [MAX_INSPECTOR_FILES]InspectorText = [_]InspectorText{.{}} ** MAX_INSPECTOR_FILES,
    file_count: usize = 0,
    resources: [MAX_INSPECTOR_RESOURCES]InspectorText = [_]InspectorText{.{}} ** MAX_INSPECTOR_RESOURCES,
    resource_count: usize = 0,
    started_at_ms: ?i64 = null,
    updated_at_ms: ?i64 = null,
    elapsed_ms: ?i64 = null,
};

pub const OperationAction = enum {
    stop,
    follow_log,
};

pub const OperationReference = struct {
    owner: OperationOwner,
    identity: ExactText,
    category: OperationCategory,
    target: OperationTarget,
    actions: SupportedActions,

    pub fn eql(self: *const OperationReference, other: *const OperationReference) bool {
        return self.owner.eql(&other.owner) and self.identity.eql(&other.identity) and
            self.category == other.category and std.meta.eql(self.target, other.target) and
            std.meta.eql(self.actions, other.actions);
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
    category: OperationCategory = .provider_tool,
    target: OperationTarget = .none,
    inspector: Inspector = .{},
    actions: SupportedActions = .{},
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
    owner: OperationOwner = .{},
    has_thread: bool = false,
    has_approval: bool = false,
    has_failure: bool = false,
    working: bool = false,
    objective: PresentationText = .{},
    // Current-turn assistant answer for the latest meaningful objective. A
    // newer user prompt clears it so a stale reply never presents as current.
    answer: PresentationText = .{},
    // True only when the current turn itself failed — never for historical
    // transcript failures — so the Result region reports the real outcome.
    answer_failed: bool = false,
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

    pub fn setOwner(self: *Frame, workspace_id: []const u8, local_thread_id: []const u8) bool {
        self.workspace_id.set(workspace_id);
        self.thread_id.set(local_thread_id);
        return self.owner.set(workspace_id, local_thread_id);
    }

    pub fn operationReference(self: *const Frame, index: usize) ?OperationReference {
        if (!self.owner.valid or index >= self.operation_count) return null;
        const operation = &self.operations[index];
        var identity: ExactText = .{};
        if (!identity.set(operation.identity.slice())) return null;
        return .{
            .owner = self.owner,
            .identity = identity,
            .category = operation.category,
            .target = operation.target,
            .actions = operation.actions,
        };
    }

    pub fn containsReference(self: *const Frame, reference: *const OperationReference) bool {
        return self.operationForReference(reference) != null;
    }

    pub fn operationForReference(self: *const Frame, reference: *const OperationReference) ?*const Operation {
        if (!self.owner.eql(&reference.owner)) return null;
        for (self.operations[0..self.operation_count]) |*operation| {
            if (!std.mem.eql(u8, operation.identity.slice(), reference.identity.slice())) continue;
            if (operation.category != reference.category or !std.meta.eql(operation.target, reference.target) or
                !std.meta.eql(operation.actions, reference.actions)) return null;
            return operation;
        }
        return null;
    }

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

pub const MissionControlScrollRegion = enum {
    summary,
    operations,
    inspector,
    body,
};

visibility: Visibility = .collapsed_chip,
run_phase: RunPhase = .working,
needs_approval: bool = true,
has_failure: bool = false,
status_text: []const u8 = "Approval needed",
operation_count: usize = 3,
approval_count: usize = 1,
ui_error: ?[]const u8 = null,
presentation: Presentation = .{},
selected_operation: ?OperationReference = null,
selected_tab: Tab = .run,
mission_control_open: bool = false,
frame_width: f32 = 0.0,
frame_height: f32 = 0.0,
hits: [80]Hit = undefined,
hit_count: usize = 0,
body_scroll_y: f32 = 0.0,
activity_scroll_y: f32 = 0.0,
activity_max_scroll: f32 = 0.0,
activity_content_count: usize = 0,
activity_follow_tail: bool = true,
mission_control_summary_scroll_y: f32 = 0.0,
mission_control_operations_scroll_y: f32 = 0.0,
mission_control_inspector_scroll_y: f32 = 0.0,
mission_control_body_scroll_y: f32 = 0.0,
pointer_captured_buttons: [256]bool = [_]bool{false} ** 256,
escape_key_captured: bool = false,

pub fn init() Self {
    return .{};
}

pub fn toggle(self: *Self) void {
    switch (self.visibility) {
        .collapsed_chip => self.show(),
        .sidecar_open => self.collapse(),
    }
}

pub fn show(self: *Self) void {
    self.visibility = .sidecar_open;
}

pub fn collapse(self: *Self) void {
    self.mission_control_open = false;
    self.visibility = .collapsed_chip;
}

pub fn openMissionControl(self: *Self) void {
    self.visibility = .sidecar_open;
    self.mission_control_open = true;
    if (self.selected_operation == null) self.selectMissionControlDefault();
}

pub fn closeMissionControl(self: *Self) void {
    self.mission_control_open = false;
    self.visibility = .sidecar_open;
}

pub fn handleEscapeKey(self: *Self, down: bool) bool {
    if (!down) {
        if (!self.escape_key_captured) return false;
        self.escape_key_captured = false;
        return true;
    }
    if (self.escape_key_captured) return true;
    if (self.mission_control_open) {
        self.escape_key_captured = true;
        self.closeMissionControl();
        return true;
    }
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

    const hit = self.hitEntryAt(x, y) orelse return .{};
    if (self.pointer_captured_buttons[button]) return .{ .consumed = true };
    self.pointer_captured_buttons[button] = true;
    return .{
        .consumed = true,
        .action = if (button == 1) hit.action else null,
        .reference = if (button == 1) hit.reference else null,
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
    const exact_owner_changed = self.presentation.owner.valid != frame.owner.valid or
        (self.presentation.owner.valid and !self.presentation.owner.eql(&frame.owner));
    const identity_changed = exact_owner_changed or
        !std.mem.eql(u8, self.presentation.workspace_id.slice(), frame.workspace_id.slice()) or
        !std.mem.eql(u8, self.presentation.thread_id.slice(), frame.thread_id.slice());
    if (identity_changed) {
        self.selected_tab = .run;
        self.body_scroll_y = 0.0;
        self.activity_scroll_y = 0.0;
        self.activity_max_scroll = 0.0;
        self.activity_content_count = 0;
        self.activity_follow_tail = true;
        self.selected_operation = null;
        self.resetMissionControlScroll();
    }
    self.presentation = frame;
    if (self.selected_operation) |*reference| {
        if (!self.presentation.containsReference(reference)) {
            self.selected_operation = null;
            self.mission_control_inspector_scroll_y = 0.0;
        }
    }
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

pub fn toggleOperationSelection(self: *Self, reference: OperationReference) void {
    if (!reference.actions.inspect or !self.presentation.containsReference(&reference)) return;
    if (self.selected_operation) |*selected| {
        if (selected.eql(&reference)) {
            self.selected_operation = null;
            self.mission_control_inspector_scroll_y = 0.0;
            return;
        }
    }
    self.selected_operation = reference;
    self.mission_control_inspector_scroll_y = 0.0;
}

pub fn selectedOperation(self: *const Self) ?*const Operation {
    if (self.selected_operation) |*reference| return self.presentation.operationForReference(reference);
    return null;
}

pub fn operationSelected(self: *const Self, reference: *const OperationReference) bool {
    if (self.selected_operation) |*selected| {
        return selected.eql(reference) and self.presentation.containsReference(selected);
    }
    return false;
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

pub fn scrollMissionControl(self: *Self, region: MissionControlScrollRegion, delta: f32, max_scroll: f32) void {
    const offset = switch (region) {
        .summary => &self.mission_control_summary_scroll_y,
        .operations => &self.mission_control_operations_scroll_y,
        .inspector => &self.mission_control_inspector_scroll_y,
        .body => &self.mission_control_body_scroll_y,
    };
    offset.* = std.math.clamp(offset.* + delta, 0.0, @max(max_scroll, 0.0));
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

pub fn addOperationHit(self: *Self, rect: palette.Rect, action: HitAction, reference: OperationReference) void {
    std.debug.assert(action == .operation_select or action == .operation_stop or action == .operation_follow_log);
    std.debug.assert(self.hit_count < self.hits.len);
    self.hits[self.hit_count] = .{ .rect = rect, .action = action, .reference = reference };
    self.hit_count += 1;
}

pub fn hitAt(self: *const Self, x: f32, y: f32) ?HitAction {
    const hit = self.hitEntryAt(x, y) orelse return null;
    return hit.action;
}

fn hitEntryAt(self: *const Self, x: f32, y: f32) ?Hit {
    var index = self.hit_count;
    while (index > 0) {
        index -= 1;
        const hit = self.hits[index];
        if (pointInRect(hit.rect, x, y)) return hit;
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

fn selectMissionControlDefault(self: *Self) void {
    for (0..self.presentation.operation_count) |index| {
        const operation = &self.presentation.operations[index];
        if (!operation.active()) continue;
        const reference = self.presentation.operationReference(index) orelse continue;
        if (!reference.actions.inspect) continue;
        self.selected_operation = reference;
        self.mission_control_inspector_scroll_y = 0.0;
        return;
    }
    for (0..self.presentation.operation_count) |index| {
        const operation = &self.presentation.operations[index];
        if (operation.active()) continue;
        const reference = self.presentation.operationReference(index) orelse continue;
        if (!reference.actions.inspect) continue;
        self.selected_operation = reference;
        self.mission_control_inspector_scroll_y = 0.0;
        return;
    }
}

fn resetMissionControlScroll(self: *Self) void {
    self.mission_control_summary_scroll_y = 0.0;
    self.mission_control_operations_scroll_y = 0.0;
    self.mission_control_inspector_scroll_y = 0.0;
    self.mission_control_body_scroll_y = 0.0;
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

test "exact routing text rejects empty NUL and overflow without truncating" {
    var exact: ExactText = .{};
    try std.testing.expect(exact.set("owner:thread:with:colons"));
    const preserved = exact;
    try std.testing.expect(!exact.set(""));
    try std.testing.expect(exact.eql(&preserved));
    const nul = [_]u8{ 'a', 0, 'b' };
    try std.testing.expect(!exact.set(&nul));
    try std.testing.expect(exact.eql(&preserved));
    const overflow = [_]u8{'x'} ** PRESENTATION_TEXT_CAPACITY;
    try std.testing.expect(!exact.set(&overflow));
    try std.testing.expect(exact.eql(&preserved));

    const long = [_]u8{'l'} ** (PRESENTATION_TEXT_CAPACITY - 1);
    try std.testing.expect(exact.set(&long));
    try std.testing.expectEqualSlices(u8, &long, exact.slice());
}

test "operation reference retains target metadata through lifecycle copies" {
    var frame: Frame = .{};
    try std.testing.expect(frame.setOwner("workspace:one", "thread:one"));
    var call_id: ExactText = .{};
    try std.testing.expect(call_id.set("call:one"));
    var operation = testOperation("tool:8:call:one", .pending, 1);
    operation.category = .provider_tool;
    operation.target = .{ .tool_call = call_id };
    operation.inspector.input.set("structured input");
    frame.upsertOperation(operation);
    operation.status = .completed;
    operation.inspector.output.set("structured output");
    frame.upsertOperation(operation);

    const reference = frame.operationReference(0).?;
    var copied = frame;
    frame.owner = .{};
    operation.inspector.output.set("mutated source");
    try std.testing.expect(copied.containsReference(&reference));
    try std.testing.expectEqualStrings("structured output", copied.operations[0].inspector.output.slice());
    try std.testing.expectEqualStrings("call:one", copied.operations[0].target.tool_call.slice());
}

test "evicted operation references cannot match a later bounded frame" {
    var frame: Frame = .{};
    try std.testing.expect(frame.setOwner("workspace", "thread"));
    frame.upsertOperation(testOperation("oldest", .completed, 0));
    const oldest = frame.operationReference(0).?;
    var id_buffer: [32]u8 = undefined;
    for (1..MAX_OPERATIONS + 2) |index| {
        const identity = std.fmt.bufPrint(&id_buffer, "new-{d}", .{index}) catch unreachable;
        frame.upsertOperation(testOperation(identity, .completed, @intCast(index)));
    }
    try std.testing.expect(!frame.containsReference(&oldest));
}

test "operation selection toggles exactly and survives only matching frame ownership" {
    var frame: Frame = .{ .has_thread = true };
    try std.testing.expect(frame.setOwner("workspace:one", "thread:one"));
    var call_id: ExactText = .{};
    try std.testing.expect(call_id.set("call:with:colons"));
    var operation = testOperation("operation:one", .in_progress, 1);
    operation.target = .{ .tool_call = call_id };
    operation.actions = .{ .inspect = true, .stop = true };
    frame.upsertOperation(operation);

    var state = Self.init();
    state.setFrame(frame);
    const reference = frame.operationReference(0).?;
    state.toggleOperationSelection(reference);
    try std.testing.expect(state.operationSelected(&reference));
    state.selectTab(.activity);
    state.collapse();
    state.show();
    state.setFrame(frame);
    try std.testing.expect(state.operationSelected(&reference));
    try std.testing.expectEqual(Tab.activity, state.selected_tab);

    state.toggleOperationSelection(reference);
    try std.testing.expect(state.selected_operation == null);
    state.toggleOperationSelection(reference);
    frame.operations[0].inspector.output.set("new display-only output");
    state.setFrame(frame);
    try std.testing.expect(state.operationSelected(&reference));

    frame.operations[0].actions.follow_log = true;
    state.setFrame(frame);
    try std.testing.expect(state.selected_operation == null);
    const changed_actions = frame.operationReference(0).?;
    state.toggleOperationSelection(changed_actions);
    frame.operations[0].target = .none;
    state.setFrame(frame);
    try std.testing.expect(state.selected_operation == null);

    frame.operations[0].target = .{ .tool_call = call_id };
    state.setFrame(frame);
    const restored = frame.operationReference(0).?;
    state.toggleOperationSelection(restored);
    var evicted = frame;
    evicted.operation_count = 0;
    state.setFrame(evicted);
    try std.testing.expect(state.selected_operation == null);

    state.setFrame(frame);
    state.toggleOperationSelection(restored);
    var replacement: Frame = .{ .has_thread = true };
    try std.testing.expect(replacement.setOwner("workspace:two", "thread:two"));
    replacement.upsertOperation(frame.operations[0]);
    state.setFrame(replacement);
    try std.testing.expect(state.selected_operation == null);
    try std.testing.expectEqual(Tab.run, state.selected_tab);
}

test "Mission Control lifecycle preserves work and valid owner-local view state" {
    var frame: Frame = .{ .has_thread = true, .working = true };
    try std.testing.expect(frame.setOwner("workspace", "thread"));
    frame.upsertOperation(testOperation("recent", .completed, 1));
    frame.upsertOperation(testOperation("active", .in_progress, 2));
    frame.sortOperations();

    var state = Self.init();
    state.setFrame(frame);
    const presentation_before = state.presentation;
    state.show();
    state.openMissionControl();
    try std.testing.expect(state.mission_control_open);
    try std.testing.expectEqual(Visibility.sidecar_open, state.visibility);
    try std.testing.expectEqualStrings("active", state.selected_operation.?.identity.slice());
    try std.testing.expectEqualDeep(presentation_before, state.presentation);

    state.mission_control_summary_scroll_y = 11.0;
    state.mission_control_operations_scroll_y = 22.0;
    state.mission_control_inspector_scroll_y = 33.0;
    state.closeMissionControl();
    state.openMissionControl();
    try std.testing.expectEqual(@as(f32, 11.0), state.mission_control_summary_scroll_y);
    try std.testing.expectEqual(@as(f32, 22.0), state.mission_control_operations_scroll_y);
    try std.testing.expectEqual(@as(f32, 33.0), state.mission_control_inspector_scroll_y);
    try std.testing.expectEqualStrings("active", state.selected_operation.?.identity.slice());

    try std.testing.expect(state.handleEscapeKey(true));
    try std.testing.expect(!state.mission_control_open);
    try std.testing.expectEqual(Visibility.sidecar_open, state.visibility);
    try std.testing.expect(state.handleEscapeKey(false));
    state.openMissionControl();
    state.collapse();
    try std.testing.expect(!state.mission_control_open);
    try std.testing.expectEqual(Visibility.collapsed_chip, state.visibility);
    try std.testing.expectEqualDeep(presentation_before, state.presentation);
}

test "Mission Control selection and scroll reset only at exact invalidation boundaries" {
    var frame: Frame = .{ .has_thread = true };
    try std.testing.expect(frame.setOwner("workspace-a", "thread-a"));
    var operation = testOperation("operation", .in_progress, 1);
    operation.actions = .{ .inspect = true, .stop = true };
    frame.upsertOperation(operation);

    var state = Self.init();
    state.setFrame(frame);
    state.openMissionControl();
    const reference = frame.operationReference(0).?;
    state.mission_control_summary_scroll_y = 10.0;
    state.mission_control_operations_scroll_y = 20.0;
    state.mission_control_inspector_scroll_y = 30.0;
    state.mission_control_body_scroll_y = 40.0;

    state.toggleOperationSelection(reference);
    try std.testing.expect(state.selected_operation == null);
    try std.testing.expectEqual(@as(f32, 0.0), state.mission_control_inspector_scroll_y);
    try std.testing.expectEqual(@as(f32, 10.0), state.mission_control_summary_scroll_y);
    try std.testing.expectEqual(@as(f32, 20.0), state.mission_control_operations_scroll_y);
    try std.testing.expectEqual(@as(f32, 40.0), state.mission_control_body_scroll_y);

    state.toggleOperationSelection(reference);
    state.mission_control_inspector_scroll_y = 18.0;
    var evicted = frame;
    evicted.operation_count = 0;
    state.setFrame(evicted);
    try std.testing.expect(state.selected_operation == null);
    try std.testing.expectEqual(@as(f32, 0.0), state.mission_control_inspector_scroll_y);
    try std.testing.expectEqual(@as(f32, 10.0), state.mission_control_summary_scroll_y);

    var replacement = frame;
    try std.testing.expect(replacement.setOwner("workspace-b", "thread-b"));
    state.setFrame(replacement);
    try std.testing.expectEqual(@as(f32, 0.0), state.mission_control_summary_scroll_y);
    try std.testing.expectEqual(@as(f32, 0.0), state.mission_control_operations_scroll_y);
    try std.testing.expectEqual(@as(f32, 0.0), state.mission_control_body_scroll_y);
}

test "Mission Control direct scroll regions clamp independently" {
    var state = Self.init();
    state.scrollMissionControl(.summary, 40.0, 100.0);
    state.scrollMissionControl(.operations, 50.0, 100.0);
    state.scrollMissionControl(.inspector, 60.0, 100.0);
    state.scrollMissionControl(.body, 70.0, 100.0);
    state.scrollMissionControl(.summary, -15.0, 100.0);
    state.scrollMissionControl(.operations, 500.0, 80.0);
    try std.testing.expectEqual(@as(f32, 25.0), state.mission_control_summary_scroll_y);
    try std.testing.expectEqual(@as(f32, 80.0), state.mission_control_operations_scroll_y);
    try std.testing.expectEqual(@as(f32, 60.0), state.mission_control_inspector_scroll_y);
    try std.testing.expectEqual(@as(f32, 70.0), state.mission_control_body_scroll_y);
}

test "operation hit owns its copied reference after source frame replacement" {
    var frame: Frame = .{};
    try std.testing.expect(frame.setOwner("workspace", "thread"));
    var call_id: ExactText = .{};
    try std.testing.expect(call_id.set("call:one"));
    var operation = testOperation("operation:one", .in_progress, 1);
    operation.target = .{ .tool_call = call_id };
    frame.upsertOperation(operation);
    const reference = frame.operationReference(0).?;

    var state = Self.init();
    state.setFrame(frame);
    state.addOperationHit(.{ .x = 10.0, .y = 10.0, .w = 20.0, .h = 20.0 }, .operation_select, reference);
    frame = .{};
    const pressed = state.handlePointerButton(15.0, 15.0, 1, true);
    try std.testing.expectEqual(HitAction.operation_select, pressed.action.?);
    try std.testing.expect(pressed.reference.?.eql(&reference));
    try std.testing.expectEqualStrings("operation:one", pressed.reference.?.identity.slice());
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

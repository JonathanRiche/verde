//! Bounded presentation state for the machine-wide Companion overlay: the
//! avatar dock, the orchestration panel (needs-you inbox, crew, and the
//! conversation), and the companion/brain menus.

const std = @import("std");
const palette = @import("palette");
const app_config = @import("../app/config.zig");

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
    approve,
    deny,
    switch_prev,
    switch_next,
    companion_menu,
    brain_menu,
    menu_dismiss,
    menu_select_companion,
    menu_new_companion,
    menu_new_conversation,
    menu_resume_conversation,
    menu_rename,
    menu_orders,
    menu_remove,
    menu_character,
    brain_provider,
    brain_model,
    brain_reasoning,
    crew_open,
    inbox_open,
    suggestion,
    recap,
};

pub const Hit = struct {
    rect: palette.Rect,
    action: HitAction,
    /// Row index for list actions (companion, provider, model, crew, inbox,
    /// suggestion, character tag); zero otherwise.
    index: usize = 0,
};

pub const PointerButtonResult = struct {
    consumed: bool = false,
    action: ?HitAction = null,
    index: usize = 0,
};

const PRESENTATION_TEXT_CAPACITY = 512;
const BODY_TEXT_CAPACITY = 2048;
const INSPECTOR_TEXT_CAPACITY = 160;
pub const MAX_OPERATIONS: usize = 12;
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

/// Conversation-sized presentation text. Companion replies are read in the
/// panel, so they keep far more than a one-line summary.
pub const BodyText = struct {
    storage: [BODY_TEXT_CAPACITY:0]u8 = std.mem.zeroes([BODY_TEXT_CAPACITY:0]u8),

    pub fn set(self: *BodyText, value: []const u8) void {
        var len = @min(value.len, self.storage.len - 1);
        while (len > 0 and len < value.len and (value[len] & 0xC0) == 0x80) len -= 1;
        @memcpy(self.storage[0..len], value[0..len]);
        self.storage[len] = 0;
    }

    pub fn slice(self: *const BodyText) []const u8 {
        return std.mem.sliceTo(self.storage[0..], 0);
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
    body: BodyText = .{},
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

pub const Menu = enum { none, companions, brain };

pub const MAX_CREW: usize = 8;
pub const MAX_INBOX: usize = 8;
pub const MAX_ROSTER_ROWS: usize = 8;
pub const MAX_BRAIN_PROVIDERS: usize = 8;

pub const ShortText = struct {
    storage: [160:0]u8 = std.mem.zeroes([160:0]u8),

    pub fn set(self: *ShortText, value: []const u8) void {
        var len = @min(value.len, self.storage.len - 1);
        while (len > 0 and len < value.len and (value[len] & 0xC0) == 0x80) len -= 1;
        @memcpy(self.storage[0..len], value[0..len]);
        self.storage[len] = 0;
    }

    pub fn slice(self: *const ShortText) []const u8 {
        return std.mem.sliceTo(self.storage[0..], 0);
    }
};

/// Which way a crew or inbox row is leaning; drives its accent and sort.
pub const Attention = enum {
    approval,
    blocked,
    failed,
    running,
    done,
    idle,

    pub fn rank(self: Attention) u8 {
        return switch (self) {
            .approval, .blocked => 0,
            .failed => 1,
            .running => 2,
            .done => 3,
            .idle => 4,
        };
    }

    pub fn label(self: Attention) []const u8 {
        return switch (self) {
            .approval => "Needs approval",
            .blocked => "Needs input",
            .failed => "Failed",
            .running => "Running",
            .done => "Done",
            .idle => "Idle",
        };
    }
};

/// One chat the companion delegated to (a daemon-linked child) or one chat
/// anywhere on the machine that needs the user. Routing identity is exact so a
/// click can never open the wrong thread.
pub const ChatRow = struct {
    workspace_id: ExactText = .{},
    thread_id: ExactText = .{},
    title: ShortText = .{},
    detail: ShortText = .{},
    provider: ShortText = .{},
    attention: Attention = .idle,
};

/// The active companion's identity as the panel and dock present it.
pub const Identity = struct {
    name: ShortText = .{},
    /// First line of the standing orders, for the menu subtitle.
    orders: ShortText = .{},
    character: app_config.CompanionCharacter = .sprout,
    brain: ShortText = .{},
    index: usize = 0,
    count: usize = 0,
};

pub const RosterRow = struct {
    name: ShortText = .{},
    character: app_config.CompanionCharacter = .sprout,
    active: bool = false,
};

pub const ConversationRow = struct {
    title: ShortText = .{},
    detail: ShortText = .{},
};

pub const MAX_CONVERSATION_ROWS: usize = 5;

pub const BrainProvider = struct {
    label: ShortText = .{},
    selected: bool = false,
};

visibility: Visibility = .collapsed_chip,
run_phase: RunPhase = .idle,
needs_approval: bool = false,
has_failure: bool = false,
ui_error: ?[]const u8 = null,
presentation: Presentation = .{},
identity: Identity = .{},
crew: [MAX_CREW]ChatRow = [_]ChatRow{.{}} ** MAX_CREW,
crew_count: usize = 0,
inbox: [MAX_INBOX]ChatRow = [_]ChatRow{.{}} ** MAX_INBOX,
inbox_count: usize = 0,
roster_rows: [MAX_ROSTER_ROWS]RosterRow = [_]RosterRow{.{}} ** MAX_ROSTER_ROWS,
roster_row_count: usize = 0,
/// Remembered conversations of the active companion, newest first.
conversation_rows: [MAX_CONVERSATION_ROWS]ConversationRow = [_]ConversationRow{.{}} ** MAX_CONVERSATION_ROWS,
conversation_row_count: usize = 0,
brain_providers: [MAX_BRAIN_PROVIDERS]BrainProvider = [_]BrainProvider{.{}} ** MAX_BRAIN_PROVIDERS,
brain_provider_count: usize = 0,
/// Provider tab the brain menu is browsing (index into `brain_providers`).
brain_provider_index: usize = 0,
brain_scroll_y: f32 = 0.0,
brain_max_scroll: f32 = 0.0,
menu: Menu = .none,
/// While set, the composer edits the companion's name instead of sending.
rename_mode: bool = false,
/// While set, the composer edits the companion's standing orders.
orders_mode: bool = false,
/// Set when the user comes back after a while; offers a "catch me up".
recap_available: bool = false,
recap_minutes: u32 = 0,
frame_width: f32 = 0.0,
frame_height: f32 = 0.0,
hits: [160]Hit = undefined,
hit_count: usize = 0,
conversation_scroll_y: f32 = 0.0,
conversation_max_scroll: f32 = 0.0,
conversation_follow_tail: bool = true,
conversation_content_count: usize = 0,
pointer_captured_buttons: [256]bool = [_]bool{false} ** 256,
escape_key_captured: bool = false,
/// Collapsed bubble position as logical-unit distances from the window's
/// right and bottom edges, so it follows that corner when the window resizes.
dock_right: f32 = DOCK_DEFAULT_RIGHT,
dock_bottom: f32 = DOCK_DEFAULT_BOTTOM,
/// Set while button 1 is held on the bubble: a release without movement
/// opens the panel, movement past the threshold drags the bubble instead.
dock_press: ?DockPress = null,

/// Defaults sit the bubble 14 x 18 logical units from the corner once the
/// UI's edge margin is added.
pub const DOCK_DEFAULT_RIGHT: f32 = 8.0;
pub const DOCK_DEFAULT_BOTTOM: f32 = 12.0;
/// Logical units the pointer must travel before a press becomes a drag.
pub const DOCK_DRAG_THRESHOLD: f32 = 4.0;

pub const DockPress = struct {
    x: f32,
    y: f32,
    right: f32,
    bottom: f32,
    dragged: bool = false,
};

/// Allowed range for `dock_right` / `dock_bottom` in logical units.
pub const DockBounds = struct { max_right: f32, max_bottom: f32 };

pub fn init() Self {
    return .{};
}

pub fn beginDockPress(self: *Self, x: f32, y: f32) void {
    self.dock_press = .{ .x = x, .y = y, .right = self.dock_right, .bottom = self.dock_bottom };
}

/// Moves the bubble with the pointer once the drag threshold is crossed.
/// `scale` converts pixel deltas to logical units. Returns true on movement.
pub fn dragDock(self: *Self, x: f32, y: f32, scale: f32, bounds: DockBounds) bool {
    const press = &(self.dock_press orelse return false);
    const s = @max(scale, 0.01);
    const dx = (x - press.x) / s;
    const dy = (y - press.y) / s;
    if (!press.dragged and @abs(dx) < DOCK_DRAG_THRESHOLD and @abs(dy) < DOCK_DRAG_THRESHOLD) return false;
    press.dragged = true;
    self.dock_right = std.math.clamp(press.right - dx, 0.0, @max(bounds.max_right, 0.0));
    self.dock_bottom = std.math.clamp(press.bottom - dy, 0.0, @max(bounds.max_bottom, 0.0));
    return true;
}

/// Ends a bubble press; true when it was a click (no drag), null when no
/// press was active.
pub fn endDockPress(self: *Self) ?bool {
    const press = self.dock_press orelse return null;
    self.dock_press = null;
    return !press.dragged;
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
    self.menu = .none;
    self.rename_mode = false;
    self.orders_mode = false;
    self.visibility = .collapsed_chip;
}

pub fn openMenu(self: *Self, menu: Menu) void {
    self.menu = if (self.menu == menu) .none else menu;
    if (self.menu == .brain) self.brain_scroll_y = 0.0;
}

pub fn closeMenu(self: *Self) void {
    self.menu = .none;
}

/// Escape peels one layer: menu, then rename, then the panel itself. The
/// whole physical key press (down, repeats, up) stays Companion-owned.
pub fn handleEscapeKey(self: *Self, down: bool) bool {
    if (!down) {
        if (!self.escape_key_captured) return false;
        self.escape_key_captured = false;
        return true;
    }
    if (self.escape_key_captured) return true;
    if (self.visibility != .sidecar_open) return false;
    self.escape_key_captured = true;
    if (self.menu != .none) {
        self.menu = .none;
    } else if (self.rename_mode or self.orders_mode) {
        self.rename_mode = false;
        self.orders_mode = false;
    } else {
        self.collapse();
    }
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
        .index = if (button == 1) hit.index else 0,
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
    self.dock_press = null;
    self.escape_key_captured = false;
}

/// Character pose from real state only: approval outranks work, and nothing
/// animates as busy unless a turn or delegated chat is actually running.
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

pub fn setFrame(self: *Self, frame: Frame) void {
    const identity_changed = self.presentation.owner.valid != frame.owner.valid or
        (self.presentation.owner.valid and !self.presentation.owner.eql(&frame.owner)) or
        !std.mem.eql(u8, self.presentation.workspace_id.slice(), frame.workspace_id.slice()) or
        !std.mem.eql(u8, self.presentation.thread_id.slice(), frame.thread_id.slice());
    if (identity_changed) {
        self.conversation_scroll_y = 0.0;
        self.conversation_max_scroll = 0.0;
        self.conversation_follow_tail = true;
        self.conversation_content_count = 0;
    }
    self.presentation = frame;
    self.refreshPosture();
}

/// Crew and inbox state feeds the pose too: a companion whose delegated chat
/// needs approval should look like it needs you even while its own turn idles.
pub fn refreshPosture(self: *Self) void {
    var crew_running = false;
    var crew_needs_you = false;
    for (self.crew[0..self.crew_count]) |row| switch (row.attention) {
        .running => crew_running = true,
        .approval, .blocked => crew_needs_you = true,
        else => {},
    };
    self.run_phase = if (self.presentation.working or crew_running) .working else .idle;
    self.needs_approval = self.presentation.has_approval or crew_needs_you or self.inboxNeedsYouCount() > 0;
    self.has_failure = self.presentation.has_failure;
}

/// One-word posture used by tests and accessibility text.
pub fn statusText(self: *const Self) []const u8 {
    if (self.has_failure) return "Needs attention";
    if (self.needs_approval) return "Approval needed";
    if (self.run_phase == .working) return "Working";
    return "Ready";
}

/// True while the composer edits companion settings instead of messaging.
pub fn editingSettings(self: *const Self) bool {
    return self.rename_mode or self.orders_mode;
}

/// Offers a recap when the user returns after `away_ms` of inactivity.
pub fn noteReturn(self: *Self, away_ms: i64) void {
    const threshold_ms: i64 = 15 * 60 * 1000;
    if (away_ms < threshold_ms) return;
    self.recap_available = true;
    self.recap_minutes = @intCast(@min(@divFloor(away_ms, 60 * 1000), 24 * 60 * 7));
}

pub fn inboxNeedsYouCount(self: *const Self) usize {
    var count: usize = 0;
    for (self.inbox[0..self.inbox_count]) |row| {
        if (row.attention == .approval or row.attention == .blocked) count += 1;
    }
    return count;
}

pub fn crewRunningCount(self: *const Self) usize {
    var count: usize = 0;
    for (self.crew[0..self.crew_count]) |row| {
        if (row.attention == .running) count += 1;
    }
    return count;
}

/// Replaces a bounded row list, keeping what needs the user first.
pub fn setRows(rows: []ChatRow, count: *usize, next: []const ChatRow) void {
    const n = @min(rows.len, next.len);
    @memcpy(rows[0..n], next[0..n]);
    count.* = n;
    var index: usize = 1;
    while (index < n) : (index += 1) {
        const value = rows[index];
        var insertion = index;
        while (insertion > 0 and value.attention.rank() < rows[insertion - 1].attention.rank()) : (insertion -= 1) {
            rows[insertion] = rows[insertion - 1];
        }
        rows[insertion] = value;
    }
}

pub fn setCrew(self: *Self, next: []const ChatRow) void {
    setRows(&self.crew, &self.crew_count, next);
    self.refreshPosture();
}

pub fn setInbox(self: *Self, next: []const ChatRow) void {
    setRows(&self.inbox, &self.inbox_count, next);
    self.refreshPosture();
}

pub fn scrollConversation(self: *Self, delta: f32) void {
    self.conversation_scroll_y = std.math.clamp(self.conversation_scroll_y + delta, 0.0, self.conversation_max_scroll);
    self.conversation_follow_tail = self.conversation_max_scroll - self.conversation_scroll_y <= 2.0;
}

/// Pins the conversation to its newest line while the user has not scrolled
/// away; a manual offset survives growth until they return to the tail.
pub fn updateConversationExtent(self: *Self, max_scroll: f32) void {
    const grew = self.presentation.activity_count != self.conversation_content_count or max_scroll > self.conversation_max_scroll;
    const was_at_tail = self.conversation_follow_tail or self.conversation_max_scroll - self.conversation_scroll_y <= 2.0;
    if (grew and was_at_tail) {
        self.conversation_scroll_y = max_scroll;
    } else {
        self.conversation_scroll_y = std.math.clamp(self.conversation_scroll_y, 0.0, max_scroll);
    }
    self.conversation_follow_tail = was_at_tail and max_scroll - self.conversation_scroll_y <= 2.0;
    self.conversation_max_scroll = max_scroll;
    self.conversation_content_count = self.presentation.activity_count;
}

pub fn scrollBrain(self: *Self, delta: f32) void {
    self.brain_scroll_y = std.math.clamp(self.brain_scroll_y + delta, 0.0, self.brain_max_scroll);
}

pub fn clearHits(self: *Self) void {
    self.hit_count = 0;
}

pub fn addHit(self: *Self, rect: palette.Rect, action: HitAction) void {
    self.addIndexedHit(rect, action, 0);
}

pub fn addIndexedHit(self: *Self, rect: palette.Rect, action: HitAction, index: usize) void {
    if (self.hit_count >= self.hits.len) return;
    if (rect.w <= 0.0 or rect.h <= 0.0) return;
    self.hits[self.hit_count] = .{ .rect = rect, .action = action, .index = index };
    self.hit_count += 1;
}

pub fn hitAt(self: *const Self, x: f32, y: f32) ?HitAction {
    const hit = self.hitEntryAt(x, y) orelse return null;
    return hit.action;
}

pub fn hitEntryAt(self: *const Self, x: f32, y: f32) ?Hit {
    var index = self.hit_count;
    while (index > 0) {
        index -= 1;
        const hit = self.hits[index];
        if (pointInRect(hit.rect, x, y)) return hit;
    }
    return null;
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
    return left.sequence > right.sequence;
}

test "operation identity upserts across lifecycle" {
    var frame: Frame = .{};
    var operation: Operation = .{ .status = .in_progress, .sequence = 1 };
    operation.identity.set("call-1");
    frame.upsertOperation(operation);
    operation.status = .completed;
    operation.sequence = 9;
    frame.upsertOperation(operation);
    try std.testing.expectEqual(@as(usize, 1), frame.operation_count);
    try std.testing.expectEqual(OperationStatus.completed, frame.operations[0].status);
    try std.testing.expectEqual(@as(i64, 1), frame.operations[0].sequence);
}

test "exact routing text rejects empty NUL and overflow without truncating" {
    var text: ExactText = .{};
    try std.testing.expect(text.set("thread-1"));
    try std.testing.expect(!text.set(""));
    try std.testing.expect(!text.set("bad\x00id"));
    const long = [_]u8{'x'} ** (PRESENTATION_TEXT_CAPACITY + 4);
    try std.testing.expect(!text.set(&long));
    try std.testing.expectEqualStrings("thread-1", text.slice());
}

test "body text keeps long replies and never splits a codepoint" {
    var body: BodyText = .{};
    body.set("hello");
    try std.testing.expectEqualStrings("hello", body.slice());
    var long: [BODY_TEXT_CAPACITY + 8]u8 = undefined;
    @memset(&long, 'a');
    // A two-byte codepoint straddling the capacity boundary is dropped whole.
    long[BODY_TEXT_CAPACITY - 2] = 0xC3;
    long[BODY_TEXT_CAPACITY - 1] = 0xA9;
    body.set(&long);
    try std.testing.expectEqual(@as(usize, BODY_TEXT_CAPACITY - 2), body.slice().len);
}

test "escape peels menu, then rename, then the panel, as one owned key press" {
    var companion = Self.init();
    try std.testing.expect(!companion.handleEscapeKey(true));
    companion.show();
    companion.openMenu(.brain);
    companion.rename_mode = true;
    try std.testing.expect(companion.handleEscapeKey(true));
    try std.testing.expectEqual(Menu.none, companion.menu);
    try std.testing.expect(companion.rename_mode);
    try std.testing.expect(companion.handleEscapeKey(true)); // repeat stays owned, no extra effect
    try std.testing.expect(companion.rename_mode);
    try std.testing.expect(companion.handleEscapeKey(false));
    try std.testing.expect(companion.handleEscapeKey(true));
    try std.testing.expect(!companion.rename_mode);
    try std.testing.expect(companion.handleEscapeKey(false));
    try std.testing.expect(companion.handleEscapeKey(true));
    try std.testing.expectEqual(Visibility.collapsed_chip, companion.visibility);
    try std.testing.expect(companion.handleEscapeKey(false));
    try std.testing.expect(!companion.handleEscapeKey(false));
}

test "menus toggle and collapse clears transient modes" {
    var companion = Self.init();
    companion.show();
    companion.openMenu(.companions);
    try std.testing.expectEqual(Menu.companions, companion.menu);
    companion.openMenu(.companions);
    try std.testing.expectEqual(Menu.none, companion.menu);
    companion.openMenu(.brain);
    companion.rename_mode = true;
    companion.collapse();
    try std.testing.expectEqual(Menu.none, companion.menu);
    try std.testing.expect(!companion.rename_mode);
}

test "rows sort what needs the user first and drive the pose" {
    var companion = Self.init();
    var rows: [3]ChatRow = .{ .{ .attention = .done }, .{ .attention = .running }, .{ .attention = .approval } };
    rows[2].title.set("needs me");
    companion.setCrew(&rows);
    try std.testing.expectEqual(@as(usize, 3), companion.crew_count);
    try std.testing.expectEqualStrings("needs me", companion.crew[0].title.slice());
    try std.testing.expectEqual(Attention.done, companion.crew[2].attention);
    try std.testing.expectEqual(@as(usize, 1), companion.crewRunningCount());
    try std.testing.expectEqual(Pose.approval, companion.visualState().pose);

    companion.setCrew(&.{});
    try std.testing.expectEqual(Pose.idle, companion.visualState().pose);
    var inbox: [1]ChatRow = .{.{ .attention = .blocked }};
    companion.setInbox(&inbox);
    try std.testing.expectEqual(@as(usize, 1), companion.inboxNeedsYouCount());
    try std.testing.expect(companion.visualState().show_approval);
}

test "conversation follows the tail until the user scrolls away" {
    var companion = Self.init();
    companion.presentation.activity_count = 2;
    companion.updateConversationExtent(100.0);
    try std.testing.expectEqual(@as(f32, 100.0), companion.conversation_scroll_y);
    companion.scrollConversation(-40.0);
    try std.testing.expect(!companion.conversation_follow_tail);
    companion.presentation.activity_count = 3;
    companion.updateConversationExtent(150.0);
    try std.testing.expectEqual(@as(f32, 60.0), companion.conversation_scroll_y);
    companion.scrollConversation(1000.0);
    try std.testing.expect(companion.conversation_follow_tail);
    companion.presentation.activity_count = 4;
    companion.updateConversationExtent(200.0);
    try std.testing.expectEqual(@as(f32, 200.0), companion.conversation_scroll_y);
}

test "owner change resets conversation scroll" {
    var companion = Self.init();
    var frame: Frame = .{ .has_thread = true };
    _ = frame.setOwner("ws-a", "chat-1");
    companion.setFrame(frame);
    companion.conversation_max_scroll = 50.0;
    companion.conversation_scroll_y = 10.0;
    companion.conversation_follow_tail = false;
    _ = frame.setOwner("ws-a", "chat-2");
    companion.setFrame(frame);
    try std.testing.expectEqual(@as(f32, 0.0), companion.conversation_scroll_y);
    try std.testing.expect(companion.conversation_follow_tail);
}

test "pointer buttons capture through release and report indexed hits" {
    var companion = Self.init();
    companion.addIndexedHit(.{ .x = 0.0, .y = 0.0, .w = 10.0, .h = 10.0 }, .crew_open, 3);
    const down = companion.handlePointerButton(5.0, 5.0, 1, true);
    try std.testing.expect(down.consumed);
    try std.testing.expectEqual(HitAction.crew_open, down.action.?);
    try std.testing.expectEqual(@as(usize, 3), down.index);
    companion.clearHits();
    try std.testing.expect(companion.ownsPointerRelease(1));
    try std.testing.expect(companion.handlePointerButton(50.0, 50.0, 1, false).consumed);
    try std.testing.expect(!companion.ownsPointerRelease(1));
    try std.testing.expect(!companion.handlePointerButton(50.0, 50.0, 1, false).consumed);
}

test "returning after a long absence offers a recap" {
    var companion = Self.init();
    companion.noteReturn(5 * 60 * 1000);
    try std.testing.expect(!companion.recap_available);
    companion.noteReturn(90 * 60 * 1000);
    try std.testing.expect(companion.recap_available);
    try std.testing.expectEqual(@as(u32, 90), companion.recap_minutes);
}

test "bubble press opens on a click and drags past the threshold" {
    var companion = Self.init();
    const bounds: DockBounds = .{ .max_right = 500.0, .max_bottom = 300.0 };
    companion.beginDockPress(100.0, 100.0);
    try std.testing.expect(!companion.dragDock(102.0, 101.0, 1.0, bounds));
    try std.testing.expectEqual(@as(?bool, true), companion.endDockPress());
    try std.testing.expectEqual(@as(?bool, null), companion.endDockPress());

    companion.beginDockPress(100.0, 100.0);
    try std.testing.expect(companion.dragDock(60.0, 40.0, 2.0, bounds));
    try std.testing.expectApproxEqAbs(DOCK_DEFAULT_RIGHT + 20.0, companion.dock_right, 0.001);
    try std.testing.expectApproxEqAbs(DOCK_DEFAULT_BOTTOM + 30.0, companion.dock_bottom, 0.001);
    // Clamped to the window, and back within the threshold still counts as a drag.
    try std.testing.expect(companion.dragDock(5000.0, 5000.0, 1.0, bounds));
    try std.testing.expectEqual(@as(f32, 0.0), companion.dock_right);
    try std.testing.expectEqual(@as(f32, 0.0), companion.dock_bottom);
    try std.testing.expect(companion.dragDock(100.0, 100.0, 1.0, bounds));
    try std.testing.expectEqual(@as(?bool, false), companion.endDockPress());
}

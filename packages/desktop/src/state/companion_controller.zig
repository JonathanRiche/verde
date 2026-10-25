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

/// Live voice overlay on the character: a listening ring or speaking waves.
pub const LiveCue = enum { none, listening, speaking };

pub const VisualState = struct {
    pose: Pose,
    show_approval: bool,
    show_failure: bool,
    live: LiveCue = .none,
    /// 0..1 loudness driving the live cue.
    live_level: f32 = 0,
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
    /// Closes the current conversation (returns to the newest remembered one).
    menu_close_current_conversation,
    /// Closes a remembered conversation (index into conversation_rows).
    menu_close_conversation,
    menu_rename,
    menu_orders,
    menu_remove,
    menu_character,
    brain_provider,
    brain_model,
    brain_reasoning,
    toggle_expand,
    text_copy,
    text_select_all,
    crew_open,
    /// Crew header: show or hide the crew list.
    crew_toggle,
    /// "N done" fold: list or hide the finished crew rows.
    crew_done_toggle,
    /// "Clear done": unlink finished crew chats from the companion thread.
    crew_clear_done,
    /// "Show all": include rows auto-tidy hid (opened or older than a day).
    crew_show_all,
    inbox_open,
    suggestion,
    recap,
    /// Header clock and the view's back link: conversation <-> schedules.
    schedules_view,
    schedule_toggle,
    schedule_run,
    schedule_delete,
    schedule_delete_confirm,
    schedule_delete_cancel,
    schedule_expand,
    /// Empty-state card that pre-fills the composer with an example request.
    schedule_suggestion,
    /// Header mic: start or end Live voice.
    live_toggle,
    live_mute,
    live_end,
    /// The speaking character: cut the reply off (half-duplex barge-in).
    live_interrupt,
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

pub const Menu = enum { none, companions, brain, text };

/// A caret position in the conversation: an activity item and a byte offset
/// into the text that item displays.
pub const TextPoint = struct {
    item: usize,
    offset: usize,

    pub fn lessThan(a: TextPoint, b: TextPoint) bool {
        return a.item < b.item or (a.item == b.item and a.offset < b.offset);
    }

    pub fn eql(a: TextPoint, b: TextPoint) bool {
        return a.item == b.item and a.offset == b.offset;
    }
};

pub const TextRange = struct { start: TextPoint, end: TextPoint };

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
    /// Daemon `updated_at_ms` of the link (latest task update). Links carry no
    /// separate finished-at time, so for a done row this stands in for when it
    /// finished; 0 when unknown (auto-tidy then only uses "already opened").
    updated_at_ms: i64 = 0,
};

/// Crew rows the open list shows directly, plus the done fold and the
/// "Show all" toggle.
pub const MAX_CREW_LINES: usize = MAX_CREW + 2;

pub const CrewLineKind = enum { row, done_fold, show_all };

pub const CrewLine = struct {
    kind: CrewLineKind,
    /// Index into `crew` for `.row` lines.
    row: usize = 0,
};

/// What the open crew list shows, in order: rows that are running or need
/// the user, then the "N done" fold (and its rows while unfolded), then the
/// "Show all" toggle when auto-tidy hid anything. Empty while collapsed.
pub const CrewLines = struct {
    lines: [MAX_CREW_LINES]CrewLine = undefined,
    count: usize = 0,
    /// Done rows the fold counts (tidied rows only with "Show all").
    done_count: usize = 0,
    /// Done rows auto-tidy hides from the default list.
    tidied_count: usize = 0,
};

/// Counts behind the collapsed one-line crew summary.
pub const CrewSummary = struct {
    total: usize = 0,
    needs_you: usize = 0,
    running: usize = 0,
    done: usize = 0,
    idle: usize = 0,
};

/// Finished crew rows older than this drop out of the default list.
pub const CREW_TIDY_AGE_MS: i64 = 24 * std.time.ms_per_hour;
/// Crew chats opened from the list, remembered for auto-tidy (memory only).
pub const MAX_CREW_OPENED: usize = 32;

/// Line breaks of one wrapped conversation body, reused across frames so a
/// keystroke or hover does not re-measure the whole history. Offsets index
/// into the body's cleaned display text, which is cheap to rebuild.
pub const WRAP_CACHE_MAX_LINES: usize = 64;
/// Set-associative: a key may live in any of WRAP_CACHE_WAYS slots of its
/// set, so a full 64-item history never thrashes on colliding keys.
pub const WRAP_CACHE_SLOTS: usize = 256;
pub const WRAP_CACHE_WAYS: usize = 4;

pub const WrapCacheEntry = struct {
    /// Hash of body, wrap width, font, role, line cap and font generation; 0 = empty.
    key: u64 = 0,
    /// Last use (cache clock); the least recently used way is evicted.
    used: u64 = 0,
    count: u8 = 0,
    truncated: bool = false,
    /// Widest measured line, for user bubbles.
    widest: f32 = 0.0,
    starts: [WRAP_CACHE_MAX_LINES]u16 = undefined,
    ends: [WRAP_CACHE_MAX_LINES]u16 = undefined,
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

/// What the panel body shows below the header.
pub const PanelView = enum { conversation, schedules };

/// Schedules the panel keeps; the daemon allows 200, the panel says how many
/// more exist beyond these.
pub const MAX_SCHEDULE_ROWS: usize = 24;

/// Daemon schedule id (`sch-<ms>-<rand>`). Assignment is all or nothing so a
/// click can never act on a truncated id; empty means "none".
pub const ScheduleId = struct {
    storage: [64:0]u8 = std.mem.zeroes([64:0]u8),

    pub fn set(self: *ScheduleId, value: []const u8) bool {
        if (value.len == 0 or value.len >= self.storage.len or std.mem.indexOfScalar(u8, value, 0) != null) return false;
        self.* = .{};
        @memcpy(self.storage[0..value.len], value);
        return true;
    }

    pub fn clear(self: *ScheduleId) void {
        self.* = .{};
    }

    pub fn slice(self: *const ScheduleId) []const u8 {
        return std.mem.sliceTo(self.storage[0..], 0);
    }

    pub fn isEmpty(self: *const ScheduleId) bool {
        return self.storage[0] == 0;
    }

    pub fn eql(self: *const ScheduleId, other: *const ScheduleId) bool {
        return !self.isEmpty() and std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const ScheduleStatus = enum {
    never,
    ok,
    queued,
    failed,
    late,
    unknown,

    /// Maps the daemon's `last_status` (null when it never ran).
    pub fn fromDaemon(value: ?[]const u8) ScheduleStatus {
        const text = value orelse return .never;
        inline for (.{ "ok", "queued", "failed", "late" }) |name| {
            if (std.mem.eql(u8, text, name)) return @field(ScheduleStatus, name);
        }
        return .unknown;
    }
};

/// A host-local wall-clock moment, already converted from epoch ms.
pub const LocalStamp = struct {
    month: u8 = 1,
    day: u8 = 1,
    /// 0 = Sunday … 6 = Saturday, as in the daemon's `weekdays`.
    weekday: u8 = 0,
    hour: u8 = 0,
    minute: u8 = 0,
};

pub const ScheduleRepeat = union(enum) {
    once: struct {
        at_ms: i64,
        local: LocalStamp,
        /// Within the coming week, so a weekday name is unambiguous.
        this_week: bool,
    },
    interval: u32,
    daily: struct {
        hour: u8,
        minute: u8,
        /// Bit n = weekday n (0 = Sunday). Zero means every day.
        weekdays: u7,
    },
    unknown,
};

/// One scheduled task as the panel lists it. Text is copied in so a row
/// renders without touching daemon memory.
pub const ScheduleRow = struct {
    id: ScheduleId = .{},
    name: ShortText = .{},
    prompt: BodyText = .{},
    prompt_truncated: bool = false,
    repeat: ScheduleRepeat = .unknown,
    /// Human repeat ("Weekdays at 09:00"), formatted once when listed.
    repeat_text: ShortText = .{},
    next_run_ms: ?i64 = null,
    last_run_ms: ?i64 = null,
    last_status: ScheduleStatus = .never,
    last_error: ShortText = .{},
    enabled: bool = false,
};

/// A daemon mutation a schedule control asked for.
pub const ScheduleIntent = union(enum) {
    set_enabled: struct { id: ScheduleId, enabled: bool },
    run: ScheduleId,
    delete: ScheduleId,
};

const WEEKDAY_SHORT = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const WEEKDAY_PLURAL = [_][]const u8{ "Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays" };
const MONTH_SHORT = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const WEEKDAYS_MASK: u7 = 0b0111110;
const WEEKEND_MASK: u7 = 0b1000001;

/// Human repeat text: "Weekdays at 09:00", "Every 2 hours",
/// "Once · Tue 14:30". Pure; writes into `buffer` (64 bytes is plenty).
pub fn formatScheduleRepeat(buffer: []u8, repeat: ScheduleRepeat) []const u8 {
    return switch (repeat) {
        .once => |once| if (once.this_week)
            std.fmt.bufPrint(buffer, "Once · {s} {d:0>2}:{d:0>2}", .{ WEEKDAY_SHORT[once.local.weekday % 7], once.local.hour, once.local.minute }) catch ""
        else
            std.fmt.bufPrint(buffer, "Once · {s} {d} {d:0>2}:{d:0>2}", .{ MONTH_SHORT[(@max(once.local.month, 1) - 1) % 12], once.local.day, once.local.hour, once.local.minute }) catch "",
        .interval => |minutes| formatInterval(buffer, minutes),
        .daily => |daily| formatDaily(buffer, daily.hour, daily.minute, daily.weekdays),
        .unknown => "Custom schedule",
    };
}

fn formatInterval(buffer: []u8, minutes: u32) []const u8 {
    const day: u32 = 24 * 60;
    if (minutes == 0) return "Every few minutes";
    if (minutes % day == 0) {
        const days = minutes / day;
        return if (days == 1) "Every day" else if (days == 7) "Every week" else std.fmt.bufPrint(buffer, "Every {d} days", .{days}) catch "";
    }
    if (minutes % 60 == 0) {
        const hours = minutes / 60;
        return if (hours == 1) "Every hour" else std.fmt.bufPrint(buffer, "Every {d} hours", .{hours}) catch "";
    }
    if (minutes > 60 and minutes % 30 == 0) return std.fmt.bufPrint(buffer, "Every {d}.5 hours", .{minutes / 60}) catch "";
    return std.fmt.bufPrint(buffer, "Every {d} minutes", .{minutes}) catch "";
}

fn formatDaily(buffer: []u8, hour: u8, minute: u8, weekdays: u7) []const u8 {
    if (weekdays == 0 or weekdays == std.math.maxInt(u7)) return std.fmt.bufPrint(buffer, "Daily at {d:0>2}:{d:0>2}", .{ hour, minute }) catch "";
    if (weekdays == WEEKDAYS_MASK) return std.fmt.bufPrint(buffer, "Weekdays at {d:0>2}:{d:0>2}", .{ hour, minute }) catch "";
    if (weekdays == WEEKEND_MASK) return std.fmt.bufPrint(buffer, "Weekends at {d:0>2}:{d:0>2}", .{ hour, minute }) catch "";
    if (@popCount(weekdays) == 1) return std.fmt.bufPrint(buffer, "{s} at {d:0>2}:{d:0>2}", .{ WEEKDAY_PLURAL[@ctz(weekdays)], hour, minute }) catch "";
    // Listed Monday first, Sunday last, the way people say a week.
    var len: usize = 0;
    for ([_]u3{ 1, 2, 3, 4, 5, 6, 0 }) |day| {
        if (weekdays & (@as(u7, 1) << day) == 0) continue;
        const part = std.fmt.bufPrint(buffer[len..], "{s}{s}", .{ if (len == 0) "" else ", ", WEEKDAY_SHORT[day] }) catch return "";
        len += part.len;
    }
    const tail = std.fmt.bufPrint(buffer[len..], " at {d:0>2}:{d:0>2}", .{ hour, minute }) catch return "";
    return buffer[0 .. len + tail.len];
}

/// "Next: in 3h", or "Paused" for a disabled schedule.
pub fn formatScheduleNext(buffer: []u8, enabled: bool, next_run_ms: ?i64, now_ms: i64) []const u8 {
    if (!enabled) return "Paused";
    const next = next_run_ms orelse return "Not scheduled";
    const delta_ms = next - now_ms;
    if (delta_ms <= 30 * std.time.ms_per_s) return "Next: now";
    const minutes: i64 = @max(@divFloor(delta_ms + std.time.ms_per_min - 1, std.time.ms_per_min), 1);
    if (minutes < 60) return std.fmt.bufPrint(buffer, "Next: in {d}m", .{minutes}) catch "";
    const hours = @divFloor(minutes, 60);
    if (hours < 24) {
        const rest = @mod(minutes, 60);
        if (hours >= 3 or rest == 0) return std.fmt.bufPrint(buffer, "Next: in {d}h", .{hours}) catch "";
        return std.fmt.bufPrint(buffer, "Next: in {d}h {d}m", .{ hours, rest }) catch "";
    }
    return std.fmt.bufPrint(buffer, "Next: in {d}d", .{@divFloor(hours, 24)}) catch "";
}

/// "Last run ok · 2h ago", "Never run", …
pub fn formatScheduleLast(buffer: []u8, status: ScheduleStatus, last_run_ms: ?i64, now_ms: i64) []const u8 {
    const label: []const u8 = switch (status) {
        .never => return "Never run",
        .ok => "Last run ok",
        .queued => "Queued behind a busy chat",
        .failed => "Last run failed",
        .late => "Ran late",
        .unknown => "Last run",
    };
    const last = last_run_ms orelse return label;
    const minutes = @divFloor(@max(now_ms - last, 0), std.time.ms_per_min);
    if (minutes < 1) return std.fmt.bufPrint(buffer, "{s} · just now", .{label}) catch label;
    if (minutes < 60) return std.fmt.bufPrint(buffer, "{s} · {d}m ago", .{ label, minutes }) catch label;
    if (minutes < 24 * 60) return std.fmt.bufPrint(buffer, "{s} · {d}h ago", .{ label, @divFloor(minutes, 60) }) catch label;
    return std.fmt.bufPrint(buffer, "{s} · {d}d ago", .{ label, @divFloor(minutes, 24 * 60) }) catch label;
}

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
/// Crew list shown under its one-line summary. Collapsed by default; opens
/// itself when a crew row starts needing the user (see `setCrew`).
crew_list_open: bool = false,
/// Finished rows listed under the "N done" fold.
crew_done_open: bool = false,
/// Lists the done rows auto-tidy hides (opened, or older than a day).
crew_show_all: bool = false,
/// Rows that needed the user at the last `setCrew`, keyed by chat and
/// attention, so only a new need re-opens a manually collapsed list.
crew_need_keys: [MAX_CREW]u64 = [_]u64{0} ** MAX_CREW,
crew_need_count: usize = 0,
/// Crew chats opened from the list (ring buffer of chat keys).
crew_opened: [MAX_CREW_OPENED]u64 = [_]u64{0} ** MAX_CREW_OPENED,
crew_opened_count: usize = 0,
crew_opened_next: usize = 0,
/// Conversation wrap cache; see `WrapCacheEntry`.
wrap_cache: [WRAP_CACHE_SLOTS]WrapCacheEntry = [_]WrapCacheEntry{.{}} ** WRAP_CACHE_SLOTS,
wrap_cache_misses: usize = 0,
wrap_cache_clock: u64 = 0,
/// Signature of the last projected companion frame; an unchanged thread
/// skips the rebuild. 0 forces the next projection.
projection_signature: u64 = 0,
/// Tail glide while a reply streams (see `easeConversationTail`).
tail_glide_last_ms: i64 = 0,
tail_gliding: bool = false,
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
/// Conversation or the scheduled-tasks list, below the header.
view: PanelView = .conversation,
schedules: [MAX_SCHEDULE_ROWS]ScheduleRow = [_]ScheduleRow{.{}} ** MAX_SCHEDULE_ROWS,
schedule_count: usize = 0,
/// Schedules the daemon has, which may exceed what the panel keeps.
schedule_total: usize = 0,
/// Set once the first list landed; until then the view says it is loading.
schedules_loaded: bool = false,
/// Last list or mutation failure; empty when the latest request succeeded.
schedules_error: ShortText = .{},
/// Row whose delete asks "Delete?" inline.
schedule_confirm: ScheduleId = .{},
/// Row showing its selectable name and prompt detail.
schedule_expanded: ScheduleId = .{},
/// Row with a run or delete in flight.
schedule_pending: ScheduleId = .{},
schedules_scroll_y: f32 = 0.0,
schedules_max_scroll: f32 = 0.0,
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
/// Open/close transition: 0 = dock only, 1 = panel fully shown. Visibility
/// flips immediately for input; this only drives what is drawn.
/// Conversation text selection (drag, double/triple click, select all).
text_anchor: ?TextPoint = null,
text_focus: ?TextPoint = null,
text_dragging: bool = false,
/// Set after a click in the conversation so Ctrl/Cmd+A selects it.
conversation_focused: bool = false,
/// Where the right-click Copy / Select all menu opened.
text_menu_x: f32 = 0.0,
text_menu_y: f32 = 0.0,
/// Panel covers the workspace area (full chat size) instead of a sidecar.
expanded: bool = false,
/// Left edge of the workspace area (sidebar right edge), set by the root
/// layout each frame so the expanded panel leaves the sidebar visible.
workspace_left: f32 = 0.0,
panel_progress: f32 = 0.0,
transition_last_ms: i64 = 0,

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

/// Advances the open/close transition toward the current visibility.
/// `duration_ms <= 0` (reduced motion) snaps.
pub fn stepTransition(self: *Self, now_ms: i64, duration_ms: i64) void {
    const target: f32 = if (self.visibility == .sidecar_open) 1.0 else 0.0;
    if (self.panel_progress == target) {
        self.transition_last_ms = 0;
        return;
    }
    if (duration_ms <= 0) return self.settleTransition();
    const last = self.transition_last_ms;
    self.transition_last_ms = now_ms;
    // The first frame starts the clock; a stalled frame advances at most 50ms.
    if (last == 0 or now_ms <= last) return;
    const step = @as(f32, @floatFromInt(@min(now_ms - last, 50))) / @as(f32, @floatFromInt(duration_ms));
    self.panel_progress = if (target > self.panel_progress) @min(self.panel_progress + step, 1.0) else @max(self.panel_progress - step, 0.0);
    if (self.panel_progress == target) self.transition_last_ms = 0;
}

pub fn settleTransition(self: *Self) void {
    self.panel_progress = if (self.visibility == .sidecar_open) 1.0 else 0.0;
    self.transition_last_ms = 0;
}

pub fn transitionAnimating(self: *const Self) bool {
    const target: f32 = if (self.visibility == .sidecar_open) 1.0 else 0.0;
    return self.panel_progress != target;
}

pub fn beginTextSelection(self: *Self, point: TextPoint) void {
    self.text_anchor = point;
    self.text_focus = point;
    self.text_dragging = true;
    self.conversation_focused = true;
}

pub fn selectTextRange(self: *Self, start: TextPoint, end: TextPoint) void {
    self.text_anchor = start;
    self.text_focus = end;
    self.text_dragging = false;
    self.conversation_focused = true;
}

pub fn extendTextSelection(self: *Self, point: TextPoint) void {
    if (self.text_anchor == null) return;
    self.text_focus = point;
}

/// Ends a drag; a click that never moved leaves no selection.
pub fn endTextDrag(self: *Self) void {
    self.text_dragging = false;
    if (self.textRange() == null) {
        self.text_anchor = null;
        self.text_focus = null;
    }
}

pub fn clearTextSelection(self: *Self) void {
    self.text_anchor = null;
    self.text_focus = null;
    self.text_dragging = false;
    if (self.menu == .text) self.menu = .none;
}

/// Ordered, non-empty selection, or null.
pub fn textRange(self: *const Self) ?TextRange {
    const anchor = self.text_anchor orelse return null;
    const focus = self.text_focus orelse return null;
    if (anchor.eql(focus)) return null;
    return if (focus.lessThan(anchor)) .{ .start = focus, .end = anchor } else .{ .start = anchor, .end = focus };
}

pub fn openTextMenu(self: *Self, x: f32, y: f32) void {
    self.text_menu_x = x;
    self.text_menu_y = y;
    self.menu = .text;
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
    self.clearTextSelection();
    self.conversation_focused = false;
    self.menu = .none;
    self.rename_mode = false;
    self.orders_mode = false;
    // Reopening goes straight to typing, so it shows the conversation.
    self.view = .conversation;
    self.schedule_confirm.clear();
    self.visibility = .collapsed_chip;
}

/// Switches the panel body; selection and pending confirmations belong to
/// the view they were made in.
pub fn setView(self: *Self, view: PanelView) void {
    if (self.view == view) return;
    self.clearTextSelection();
    self.conversation_focused = false;
    self.menu = .none;
    self.schedule_confirm.clear();
    self.schedules_scroll_y = 0.0;
    self.view = view;
}

pub fn toggleSchedulesView(self: *Self) void {
    self.setView(if (self.view == .schedules) .conversation else .schedules);
}

/// Replaces the listed schedules. Expanded and confirming rows survive by
/// id; a row that disappeared drops its detail selection.
pub fn setSchedules(self: *Self, rows: []const ScheduleRow, total: usize) void {
    const n = @min(rows.len, self.schedules.len);
    @memcpy(self.schedules[0..n], rows[0..n]);
    self.schedule_count = n;
    self.schedule_total = @max(total, n);
    self.schedules_loaded = true;
    self.schedules_error = .{};
    if (!self.schedule_confirm.isEmpty() and self.scheduleIndex(&self.schedule_confirm) == null) self.schedule_confirm.clear();
    if (!self.schedule_expanded.isEmpty() and self.scheduleIndex(&self.schedule_expanded) == null) {
        self.schedule_expanded.clear();
        if (self.view == .schedules) self.clearTextSelection();
    }
}

pub fn setSchedulesError(self: *Self, message: []const u8) void {
    self.schedules_error.set(message);
}

pub fn scheduleIndex(self: *const Self, id: *const ScheduleId) ?usize {
    for (self.schedules[0..self.schedule_count], 0..) |*row, index| {
        if (row.id.eql(id)) return index;
    }
    return null;
}

pub fn enabledScheduleCount(self: *const Self) usize {
    var count: usize = 0;
    for (self.schedules[0..self.schedule_count]) |row| {
        if (row.enabled) count += 1;
    }
    return count;
}

pub fn scheduleConfirming(self: *const Self, index: usize) bool {
    return index < self.schedule_count and self.schedules[index].id.eql(&self.schedule_confirm);
}

pub fn scheduleExpanded(self: *const Self, index: usize) bool {
    return index < self.schedule_count and self.schedules[index].id.eql(&self.schedule_expanded);
}

pub fn schedulePending(self: *const Self, index: usize) bool {
    return index < self.schedule_count and self.schedules[index].id.eql(&self.schedule_pending);
}

/// A press anywhere but the confirming row's Yes / No / × backs out of the
/// inline "Delete?".
pub fn dismissScheduleConfirmUnless(self: *Self, action: ?HitAction, index: usize) void {
    if (self.schedule_confirm.isEmpty()) return;
    if (action) |value| switch (value) {
        .schedule_delete, .schedule_delete_confirm, .schedule_delete_cancel => if (self.scheduleConfirming(index)) return,
        else => {},
    };
    self.schedule_confirm.clear();
}

/// Applies a schedule control locally and returns the daemon mutation it
/// needs, if any. Enabling flips the row at once; the next list confirms it.
pub fn handleScheduleAction(self: *Self, action: HitAction, index: usize) ?ScheduleIntent {
    if (index >= self.schedule_count) return null;
    const row = &self.schedules[index];
    switch (action) {
        .schedule_toggle => {
            row.enabled = !row.enabled;
            return .{ .set_enabled = .{ .id = row.id, .enabled = row.enabled } };
        },
        .schedule_run => {
            if (self.schedulePending(index)) return null;
            self.schedule_pending = row.id;
            return .{ .run = row.id };
        },
        .schedule_delete => {
            if (self.scheduleConfirming(index)) {
                self.schedule_confirm.clear();
            } else {
                self.schedule_confirm = row.id;
            }
            return null;
        },
        .schedule_delete_cancel => {
            self.schedule_confirm.clear();
            return null;
        },
        .schedule_delete_confirm => {
            if (!self.scheduleConfirming(index)) return null;
            self.schedule_confirm.clear();
            self.schedule_pending = row.id;
            return .{ .delete = row.id };
        },
        .schedule_expand => {
            self.clearTextSelection();
            if (self.scheduleExpanded(index)) {
                self.schedule_expanded.clear();
            } else {
                self.schedule_expanded = row.id;
            }
            return null;
        },
        else => return null,
    }
}

pub fn scrollSchedules(self: *Self, delta: f32) void {
    self.schedules_scroll_y = std.math.clamp(self.schedules_scroll_y + delta, 0.0, self.schedules_max_scroll);
}

pub fn openMenu(self: *Self, menu: Menu) void {
    self.menu = if (self.menu == menu) .none else menu;
    if (self.menu == .brain) self.brain_scroll_y = 0.0;
}

pub fn closeMenu(self: *Self) void {
    self.menu = .none;
}

/// Escape peels one layer: menu, selection, an inline "Delete?", rename,
/// the schedules view, then the panel itself. The whole physical key press
/// (down, repeats, up) stays Companion-owned.
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
    } else if (self.textRange() != null) {
        self.clearTextSelection();
    } else if (!self.schedule_confirm.isEmpty()) {
        self.schedule_confirm.clear();
    } else if (self.rename_mode or self.orders_mode) {
        self.rename_mode = false;
        self.orders_mode = false;
    } else if (self.view == .schedules) {
        self.setView(.conversation);
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
        self.clearTextSelection();
        self.conversation_scroll_y = 0.0;
        self.conversation_max_scroll = 0.0;
        self.conversation_follow_tail = true;
        self.conversation_content_count = 0;
        self.tail_gliding = false;
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

/// Replaces the crew. A row that starts needing the user (approval, input,
/// or a failure it did not have at the last sync) opens the crew list; a
/// manual collapse otherwise sticks.
pub fn setCrew(self: *Self, next: []const ChatRow) void {
    setRows(&self.crew, &self.crew_count, next);
    var keys: [MAX_CREW]u64 = undefined;
    var count: usize = 0;
    var new_need = false;
    for (self.crew[0..self.crew_count]) |*row| {
        if (!crewRowNeedsYou(row)) continue;
        const key = crewRowKey(row) ^ (@as(u64, @intFromEnum(row.attention)) +% 1) *% 0x9E3779B97F4A7C15;
        if (std.mem.indexOfScalar(u64, self.crew_need_keys[0..self.crew_need_count], key) == null) new_need = true;
        keys[count] = key;
        count += 1;
    }
    @memcpy(self.crew_need_keys[0..count], keys[0..count]);
    self.crew_need_count = count;
    if (new_need) self.crew_list_open = true;
    self.refreshPosture();
}

/// Approval, input, or a failure: rows the crew list surfaces first.
pub fn crewRowNeedsYou(row: *const ChatRow) bool {
    return switch (row.attention) {
        .approval, .blocked, .failed => true,
        .running, .done, .idle => false,
    };
}

/// Stable identity of a crew chat for in-memory bookkeeping.
pub fn crewRowKey(row: *const ChatRow) u64 {
    var hasher = std.hash.Wyhash.init(0x6372_6577);
    hasher.update(row.workspace_id.slice());
    hasher.update(&.{0});
    hasher.update(row.thread_id.slice());
    const key = hasher.final();
    return if (key == 0) 1 else key;
}

pub fn toggleCrewList(self: *Self) void {
    self.crew_list_open = !self.crew_list_open;
}

pub fn toggleCrewDone(self: *Self) void {
    self.crew_done_open = !self.crew_done_open;
}

/// "Show all" also unfolds the done rows so the tidied ones are visible.
pub fn toggleCrewShowAll(self: *Self) void {
    self.crew_show_all = !self.crew_show_all;
    if (self.crew_show_all) self.crew_done_open = true;
}

/// Remembers that the user opened crew row `index` from the list.
pub fn noteCrewOpened(self: *Self, index: usize) void {
    if (index >= self.crew_count) return;
    const key = crewRowKey(&self.crew[index]);
    if (std.mem.indexOfScalar(u64, self.crew_opened[0..self.crew_opened_count], key) != null) return;
    self.crew_opened[self.crew_opened_next] = key;
    self.crew_opened_next = (self.crew_opened_next + 1) % MAX_CREW_OPENED;
    self.crew_opened_count = @min(self.crew_opened_count + 1, MAX_CREW_OPENED);
}

pub fn crewOpened(self: *const Self, row: *const ChatRow) bool {
    return std.mem.indexOfScalar(u64, self.crew_opened[0..self.crew_opened_count], crewRowKey(row)) != null;
}

/// Auto-tidy: a done row already opened from the list, or finished more
/// than a day ago, leaves the default list. Rows without a time
/// (`updated_at_ms == 0`) only tidy once opened.
pub fn crewRowTidied(self: *const Self, row: *const ChatRow, now_ms: i64) bool {
    if (row.attention != .done) return false;
    if (self.crewOpened(row)) return true;
    return row.updated_at_ms > 0 and now_ms - row.updated_at_ms > CREW_TIDY_AGE_MS;
}

pub fn crewSummary(self: *const Self) CrewSummary {
    var summary: CrewSummary = .{ .total = self.crew_count };
    for (self.crew[0..self.crew_count]) |*row| switch (row.attention) {
        .approval, .blocked, .failed => summary.needs_you += 1,
        .running => summary.running += 1,
        .done => summary.done += 1,
        .idle => summary.idle += 1,
    };
    return summary;
}

/// Lines of the open crew list (see `CrewLines`); rows keep `setRows`
/// order, so what needs the user leads, then running, then idle.
pub fn crewLines(self: *const Self, now_ms: i64) CrewLines {
    var result: CrewLines = .{};
    for (self.crew[0..self.crew_count]) |*row| {
        if (row.attention != .done) continue;
        if (self.crewRowTidied(row, now_ms)) result.tidied_count += 1;
        if (self.crew_show_all or !self.crewRowTidied(row, now_ms)) result.done_count += 1;
    }
    if (!self.crew_list_open) return result;
    for (self.crew[0..self.crew_count], 0..) |*row, index| {
        if (row.attention == .done) continue;
        result.lines[result.count] = .{ .kind = .row, .row = index };
        result.count += 1;
    }
    if (result.done_count > 0) {
        result.lines[result.count] = .{ .kind = .done_fold };
        result.count += 1;
        if (self.crew_done_open) {
            for (self.crew[0..self.crew_count], 0..) |*row, index| {
                if (row.attention != .done) continue;
                if (!self.crew_show_all and self.crewRowTidied(row, now_ms)) continue;
                result.lines[result.count] = .{ .kind = .row, .row = index };
                result.count += 1;
            }
        }
    }
    if (result.tidied_count > 0) {
        result.lines[result.count] = .{ .kind = .show_all };
        result.count += 1;
    }
    return result;
}

fn wrapCacheSet(self: *Self, key: u64) []WrapCacheEntry {
    const set: usize = @intCast(key % (WRAP_CACHE_SLOTS / WRAP_CACHE_WAYS));
    return self.wrap_cache[set * WRAP_CACHE_WAYS ..][0..WRAP_CACHE_WAYS];
}

/// Cached wrap for `key` (marked as just used), or null on a miss.
pub fn wrapCacheGet(self: *Self, key: u64) ?*const WrapCacheEntry {
    for (self.wrapCacheSet(key)) |*entry| {
        if (entry.key != key) continue;
        self.wrap_cache_clock += 1;
        entry.used = self.wrap_cache_clock;
        return entry;
    }
    return null;
}

/// Stores a wrap in an empty way of its set, else over the least recently
/// used one.
pub fn wrapCachePut(self: *Self, entry: WrapCacheEntry) void {
    self.wrap_cache_misses += 1;
    self.wrap_cache_clock += 1;
    const ways = self.wrapCacheSet(entry.key);
    var victim = &ways[0];
    for (ways) |*way| {
        if (way.key == 0 or way.key == entry.key) {
            victim = way;
            break;
        }
        if (way.used < victim.used) victim = way;
    }
    victim.* = entry;
    victim.used = self.wrap_cache_clock;
}

/// Tail glide: while a reply streams the followed tail eases toward the
/// newest line (chat_panel's TAIL_FOLLOW_TAU_MS) instead of hopping a line at
/// a time. `previous` is the offset drawn last frame; call right after
/// `updateConversationExtent`, which already moved a followed offset to the
/// tail. Snaps when not following, when the tail ran a viewport ahead, or
/// when `glide` is false (nothing streaming, or reduced motion).
pub fn easeConversationTail(self: *Self, previous: f32, now_ms: i64, viewport_h: f32, glide: bool) void {
    const target = self.conversation_scroll_y;
    const last = self.tail_glide_last_ms;
    self.tail_glide_last_ms = now_ms;
    self.tail_gliding = false;
    if (!glide or !self.conversation_follow_tail or target - previous <= 0.5 or target - previous > viewport_h or last == 0) return;
    const dt: f32 = @floatFromInt(std.math.clamp(now_ms - last, 0, 100));
    self.conversation_scroll_y = previous + (target - previous) * (1.0 - @exp(-dt / TAIL_GLIDE_TAU_MS));
    self.tail_gliding = target - self.conversation_scroll_y > 0.5;
}

/// Matches chat_panel TAIL_FOLLOW_TAU_MS.
pub const TAIL_GLIDE_TAU_MS: f32 = 90.0;

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
    const was_at_tail = self.conversation_follow_tail or self.conversation_max_scroll - self.conversation_scroll_y <= 2.0;
    // A followed tail always targets the newest line, so a glide that is
    // still catching up (see `easeConversationTail`) keeps following.
    if (was_at_tail) {
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

test "open and close transitions step toward visibility and snap under reduced motion" {
    var companion = Self.init();
    companion.show();
    companion.stepTransition(1000, 200);
    try std.testing.expectEqual(@as(f32, 0.0), companion.panel_progress);
    try std.testing.expect(companion.transitionAnimating());
    companion.stepTransition(1040, 200);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), companion.panel_progress, 0.001);
    // A long stall advances at most 50ms.
    companion.stepTransition(5000, 200);
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), companion.panel_progress, 0.001);
    for (0..10) |i| companion.stepTransition(5000 + @as(i64, @intCast(i + 1)) * 40, 200);
    try std.testing.expectEqual(@as(f32, 1.0), companion.panel_progress);
    try std.testing.expect(!companion.transitionAnimating());

    companion.collapse();
    companion.stepTransition(9000, 0);
    try std.testing.expectEqual(@as(f32, 0.0), companion.panel_progress);
    try std.testing.expect(!companion.transitionAnimating());
}

test "text selection orders its ends and a still click selects nothing" {
    var companion = Self.init();
    companion.beginTextSelection(.{ .item = 2, .offset = 5 });
    try std.testing.expect(companion.textRange() == null);
    companion.extendTextSelection(.{ .item = 1, .offset = 3 });
    const range = companion.textRange().?;
    try std.testing.expectEqual(@as(usize, 1), range.start.item);
    try std.testing.expectEqual(@as(usize, 5), range.end.offset);
    companion.endTextDrag();
    try std.testing.expect(companion.textRange() != null);

    companion.beginTextSelection(.{ .item = 0, .offset = 1 });
    companion.endTextDrag();
    try std.testing.expect(companion.text_anchor == null);
    try std.testing.expect(companion.conversation_focused);

    companion.selectTextRange(.{ .item = 0, .offset = 0 }, .{ .item = 3, .offset = 9 });
    companion.openTextMenu(10.0, 20.0);
    companion.clearTextSelection();
    try std.testing.expect(companion.textRange() == null);
    try std.testing.expectEqual(Menu.none, companion.menu);
}

fn testScheduleRow(id: []const u8, enabled: bool) ScheduleRow {
    var row: ScheduleRow = .{ .enabled = enabled };
    std.debug.assert(row.id.set(id));
    row.name.set(id);
    return row;
}

test "schedule repeat formats as people say it" {
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Weekdays at 09:00", formatScheduleRepeat(&buffer, .{ .daily = .{ .hour = 9, .minute = 0, .weekdays = 0b0111110 } }));
    try std.testing.expectEqualStrings("Daily at 18:05", formatScheduleRepeat(&buffer, .{ .daily = .{ .hour = 18, .minute = 5, .weekdays = 0 } }));
    try std.testing.expectEqualStrings("Daily at 07:30", formatScheduleRepeat(&buffer, .{ .daily = .{ .hour = 7, .minute = 30, .weekdays = 0b1111111 } }));
    try std.testing.expectEqualStrings("Weekends at 10:00", formatScheduleRepeat(&buffer, .{ .daily = .{ .hour = 10, .minute = 0, .weekdays = 0b1000001 } }));
    try std.testing.expectEqualStrings("Mondays at 08:15", formatScheduleRepeat(&buffer, .{ .daily = .{ .hour = 8, .minute = 15, .weekdays = 0b0000010 } }));
    try std.testing.expectEqualStrings("Mon, Wed, Sun at 12:00", formatScheduleRepeat(&buffer, .{ .daily = .{ .hour = 12, .minute = 0, .weekdays = 0b0001011 } }));
    try std.testing.expectEqualStrings("Every 2 hours", formatScheduleRepeat(&buffer, .{ .interval = 120 }));
    try std.testing.expectEqualStrings("Every hour", formatScheduleRepeat(&buffer, .{ .interval = 60 }));
    try std.testing.expectEqualStrings("Every 1.5 hours", formatScheduleRepeat(&buffer, .{ .interval = 90 }));
    try std.testing.expectEqualStrings("Every 45 minutes", formatScheduleRepeat(&buffer, .{ .interval = 45 }));
    try std.testing.expectEqualStrings("Every day", formatScheduleRepeat(&buffer, .{ .interval = 1440 }));
    try std.testing.expectEqualStrings("Every week", formatScheduleRepeat(&buffer, .{ .interval = 10080 }));
    try std.testing.expectEqualStrings("Every 3 days", formatScheduleRepeat(&buffer, .{ .interval = 4320 }));
    const tuesday: LocalStamp = .{ .month = 10, .day = 20, .weekday = 2, .hour = 14, .minute = 30 };
    try std.testing.expectEqualStrings("Once · Tue 14:30", formatScheduleRepeat(&buffer, .{ .once = .{ .at_ms = 0, .local = tuesday, .this_week = true } }));
    try std.testing.expectEqualStrings("Once · Oct 20 14:30", formatScheduleRepeat(&buffer, .{ .once = .{ .at_ms = 0, .local = tuesday, .this_week = false } }));
    try std.testing.expectEqualStrings("Custom schedule", formatScheduleRepeat(&buffer, .unknown));
}

test "schedule next and last run read relative to now" {
    var buffer: [96]u8 = undefined;
    const now: i64 = 1_792_430_000_000;
    const minute: i64 = std.time.ms_per_min;
    try std.testing.expectEqualStrings("Paused", formatScheduleNext(&buffer, false, now + 60 * minute, now));
    try std.testing.expectEqualStrings("Not scheduled", formatScheduleNext(&buffer, true, null, now));
    try std.testing.expectEqualStrings("Next: now", formatScheduleNext(&buffer, true, now - minute, now));
    try std.testing.expectEqualStrings("Next: in 5m", formatScheduleNext(&buffer, true, now + 5 * minute, now));
    try std.testing.expectEqualStrings("Next: in 1h 20m", formatScheduleNext(&buffer, true, now + 80 * minute, now));
    try std.testing.expectEqualStrings("Next: in 3h", formatScheduleNext(&buffer, true, now + 200 * minute, now));
    try std.testing.expectEqualStrings("Next: in 2d", formatScheduleNext(&buffer, true, now + 50 * 60 * minute, now));
    try std.testing.expectEqualStrings("Never run", formatScheduleLast(&buffer, .never, null, now));
    try std.testing.expectEqualStrings("Last run ok · 2h ago", formatScheduleLast(&buffer, .ok, now - 125 * minute, now));
    try std.testing.expectEqualStrings("Last run failed · just now", formatScheduleLast(&buffer, .failed, now - 1000, now));
    try std.testing.expectEqualStrings("Ran late · 3d ago", formatScheduleLast(&buffer, .late, now - 3 * 24 * 60 * minute, now));
    try std.testing.expectEqual(ScheduleStatus.queued, ScheduleStatus.fromDaemon("queued"));
    try std.testing.expectEqual(ScheduleStatus.never, ScheduleStatus.fromDaemon(null));
    try std.testing.expectEqual(ScheduleStatus.unknown, ScheduleStatus.fromDaemon("exploded"));
}

test "schedule controls toggle, run once, and delete only after an inline confirm" {
    var companion = Self.init();
    const rows = [_]ScheduleRow{ testScheduleRow("sch-1", true), testScheduleRow("sch-2", false) };
    companion.setSchedules(&rows, 2);
    try std.testing.expect(companion.schedules_loaded);
    try std.testing.expectEqual(@as(usize, 1), companion.enabledScheduleCount());

    const enable = companion.handleScheduleAction(.schedule_toggle, 1).?;
    try std.testing.expectEqualStrings("sch-2", enable.set_enabled.id.slice());
    try std.testing.expect(enable.set_enabled.enabled);
    try std.testing.expectEqual(@as(usize, 2), companion.enabledScheduleCount());

    try std.testing.expectEqualStrings("sch-1", companion.handleScheduleAction(.schedule_run, 0).?.run.slice());
    // A second press while the run is in flight sends nothing.
    try std.testing.expect(companion.handleScheduleAction(.schedule_run, 0) == null);

    // × only asks; Yes on another row does nothing; Yes on the row deletes.
    try std.testing.expect(companion.handleScheduleAction(.schedule_delete, 1) == null);
    try std.testing.expect(companion.scheduleConfirming(1));
    try std.testing.expect(companion.handleScheduleAction(.schedule_delete_confirm, 0) == null);
    companion.dismissScheduleConfirmUnless(.schedule_delete_confirm, 1);
    try std.testing.expect(companion.scheduleConfirming(1));
    const delete = companion.handleScheduleAction(.schedule_delete_confirm, 1).?;
    try std.testing.expectEqualStrings("sch-2", delete.delete.slice());
    try std.testing.expect(!companion.scheduleConfirming(1));

    // No backs out, and so does a press anywhere else.
    _ = companion.handleScheduleAction(.schedule_delete, 0);
    _ = companion.handleScheduleAction(.schedule_delete_cancel, 0);
    try std.testing.expect(!companion.scheduleConfirming(0));
    _ = companion.handleScheduleAction(.schedule_delete, 0);
    companion.dismissScheduleConfirmUnless(.schedule_run, 1);
    try std.testing.expect(!companion.scheduleConfirming(0));
    try std.testing.expect(companion.handleScheduleAction(.schedule_toggle, 9) == null);
}

test "schedules view keeps expanded rows by id and escape steps back out" {
    var companion = Self.init();
    companion.show();
    var rows = [_]ScheduleRow{ testScheduleRow("sch-1", true), testScheduleRow("sch-2", true) };
    companion.setSchedules(&rows, 30);
    try std.testing.expectEqual(@as(usize, 30), companion.schedule_total);
    companion.toggleSchedulesView();
    try std.testing.expectEqual(PanelView.schedules, companion.view);
    _ = companion.handleScheduleAction(.schedule_expand, 1);
    try std.testing.expect(companion.scheduleExpanded(1));
    // The daemon re-sorted: the expanded row follows its id.
    std.mem.swap(ScheduleRow, &rows[0], &rows[1]);
    companion.setSchedules(&rows, 2);
    try std.testing.expect(companion.scheduleExpanded(0));
    companion.setSchedules(rows[1..], 1);
    try std.testing.expect(companion.schedule_expanded.isEmpty());

    _ = companion.handleScheduleAction(.schedule_delete, 0);
    try std.testing.expect(companion.handleEscapeKey(true));
    try std.testing.expect(companion.handleEscapeKey(false));
    try std.testing.expect(companion.schedule_confirm.isEmpty());
    try std.testing.expectEqual(PanelView.schedules, companion.view);
    try std.testing.expect(companion.handleEscapeKey(true));
    try std.testing.expect(companion.handleEscapeKey(false));
    try std.testing.expectEqual(PanelView.conversation, companion.view);
    try std.testing.expectEqual(Visibility.sidecar_open, companion.visibility);

    companion.toggleSchedulesView();
    companion.collapse();
    try std.testing.expectEqual(PanelView.conversation, companion.view);
}

test "schedule ids are exact or rejected" {
    var id: ScheduleId = .{};
    try std.testing.expect(id.isEmpty());
    try std.testing.expect(id.set("sch-1792430000000-ab12"));
    try std.testing.expect(!id.set(""));
    try std.testing.expect(!id.set("a" ** 80));
    try std.testing.expectEqualStrings("sch-1792430000000-ab12", id.slice());
    const empty: ScheduleId = .{};
    try std.testing.expect(!empty.eql(&empty));
}

fn testCrewRow(thread_id: []const u8, attention: Attention, updated_at_ms: i64) ChatRow {
    var row: ChatRow = .{ .attention = attention, .updated_at_ms = updated_at_ms };
    _ = row.workspace_id.set("ws");
    _ = row.thread_id.set(thread_id);
    row.title.set(thread_id);
    return row;
}

test "crew list starts collapsed, opens on a new need, and a manual collapse sticks" {
    var companion = Self.init();
    var rows: [2]ChatRow = .{ testCrewRow("a", .running, 0), testCrewRow("b", .done, 0) };
    companion.setCrew(&rows);
    try std.testing.expect(!companion.crew_list_open);
    try std.testing.expectEqual(@as(usize, 0), companion.crewLines(0).count);

    // Running -> approval is a new need: the list opens itself.
    rows[0].attention = .approval;
    companion.setCrew(&rows);
    try std.testing.expect(companion.crew_list_open);
    // The user collapses it; the same need on later syncs leaves it shut.
    companion.toggleCrewList();
    companion.setCrew(&rows);
    companion.setCrew(&rows);
    try std.testing.expect(!companion.crew_list_open);
    // A different row failing is a new need and re-opens it.
    rows[1].attention = .failed;
    companion.setCrew(&rows);
    try std.testing.expect(companion.crew_list_open);
    // Clearing the needs and raising one again counts as new too.
    companion.toggleCrewList();
    rows[0].attention = .running;
    rows[1].attention = .done;
    companion.setCrew(&rows);
    try std.testing.expect(!companion.crew_list_open);
    rows[0].attention = .blocked;
    companion.setCrew(&rows);
    try std.testing.expect(companion.crew_list_open);
}

test "crew open list leads with running and needs-you rows and folds done rows" {
    var companion = Self.init();
    var rows: [5]ChatRow = .{
        testCrewRow("done-1", .done, 0),
        testCrewRow("run", .running, 0),
        testCrewRow("done-2", .done, 0),
        testCrewRow("ask", .approval, 0),
        testCrewRow("done-3", .done, 0),
    };
    companion.setCrew(&rows);
    const summary = companion.crewSummary();
    try std.testing.expectEqual(@as(usize, 5), summary.total);
    try std.testing.expectEqual(@as(usize, 1), summary.needs_you);
    try std.testing.expectEqual(@as(usize, 1), summary.running);
    try std.testing.expectEqual(@as(usize, 3), summary.done);

    companion.crew_list_open = true;
    var lines = companion.crewLines(0);
    try std.testing.expectEqual(@as(usize, 3), lines.count);
    try std.testing.expectEqualStrings("ask", companion.crew[lines.lines[0].row].title.slice());
    try std.testing.expectEqualStrings("run", companion.crew[lines.lines[1].row].title.slice());
    try std.testing.expectEqual(CrewLineKind.done_fold, lines.lines[2].kind);
    try std.testing.expectEqual(@as(usize, 3), lines.done_count);

    companion.toggleCrewDone();
    lines = companion.crewLines(0);
    try std.testing.expectEqual(@as(usize, 6), lines.count);
    for (lines.lines[3..6]) |line| {
        try std.testing.expectEqual(CrewLineKind.row, line.kind);
        try std.testing.expectEqual(Attention.done, companion.crew[line.row].attention);
    }
}

test "crew auto-tidy hides opened or day-old done rows until show all" {
    var companion = Self.init();
    const now: i64 = 10 * std.time.ms_per_day;
    var rows: [4]ChatRow = .{
        testCrewRow("fresh", .done, now - std.time.ms_per_hour),
        testCrewRow("stale", .done, now - 2 * std.time.ms_per_day),
        testCrewRow("opened", .done, now - std.time.ms_per_min),
        testCrewRow("untimed", .done, 0),
    };
    companion.setCrew(&rows);
    for (companion.crew[0..companion.crew_count], 0..) |*row, index| {
        if (std.mem.eql(u8, row.title.slice(), "opened")) companion.noteCrewOpened(index);
    }
    // A running row is never tidied, however old.
    try std.testing.expect(!companion.crewRowTidied(&testCrewRow("old-run", .running, 1), now));

    companion.crew_list_open = true;
    companion.crew_done_open = true;
    var lines = companion.crewLines(now);
    try std.testing.expectEqual(@as(usize, 2), lines.tidied_count);
    try std.testing.expectEqual(@as(usize, 2), lines.done_count);
    // Fold, the two kept rows, then "Show all".
    try std.testing.expectEqual(@as(usize, 4), lines.count);
    try std.testing.expectEqual(CrewLineKind.show_all, lines.lines[3].kind);
    for (lines.lines[1..3]) |line| {
        const title = companion.crew[line.row].title.slice();
        try std.testing.expect(std.mem.eql(u8, title, "fresh") or std.mem.eql(u8, title, "untimed"));
    }

    companion.toggleCrewShowAll();
    lines = companion.crewLines(now);
    try std.testing.expectEqual(@as(usize, 4), lines.done_count);
    try std.testing.expectEqual(@as(usize, 6), lines.count);
    try std.testing.expectEqual(CrewLineKind.show_all, lines.lines[5].kind);
    companion.toggleCrewShowAll();
    try std.testing.expectEqual(@as(usize, 4), companion.crewLines(now).count);
}

test "wrap cache keeps colliding keys per set and evicts the least recently used" {
    var companion = Self.init();
    const sets: u64 = WRAP_CACHE_SLOTS / WRAP_CACHE_WAYS;
    try std.testing.expect(companion.wrapCacheGet(42) == null);
    companion.wrapCachePut(.{ .key = 42, .count = 3, .widest = 120.0 });
    try std.testing.expectEqual(@as(u8, 3), companion.wrapCacheGet(42).?.count);
    // Keys sharing the set all stay until the set is full.
    for (1..WRAP_CACHE_WAYS) |way| companion.wrapCachePut(.{ .key = 42 + sets * way, .count = @intCast(way) });
    try std.testing.expect(companion.wrapCacheGet(42) != null);
    for (1..WRAP_CACHE_WAYS) |way| try std.testing.expect(companion.wrapCacheGet(42 + sets * way) != null);
    // One more evicts the least recently used (42 + sets), never mis-serving it.
    _ = companion.wrapCacheGet(42);
    companion.wrapCachePut(.{ .key = 42 + sets * WRAP_CACHE_WAYS, .count = 9 });
    try std.testing.expect(companion.wrapCacheGet(42 + sets) == null);
    try std.testing.expectEqual(@as(u8, 3), companion.wrapCacheGet(42).?.count);
    try std.testing.expectEqual(@as(u8, 9), companion.wrapCacheGet(42 + sets * WRAP_CACHE_WAYS).?.count);
    try std.testing.expectEqual(@as(usize, WRAP_CACHE_WAYS + 1), companion.wrap_cache_misses);
}

test "conversation tail glides toward a streaming tail and stops when the user scrolls away" {
    var companion = Self.init();
    companion.presentation.activity_count = 1;
    companion.updateConversationExtent(100.0);
    companion.easeConversationTail(100.0, 1_000, 400.0, true);
    try std.testing.expectEqual(@as(f32, 100.0), companion.conversation_scroll_y);
    // One new line: the offset eases instead of hopping, and keeps following.
    var previous = companion.conversation_scroll_y;
    companion.updateConversationExtent(130.0);
    companion.easeConversationTail(previous, 1_016, 400.0, true);
    try std.testing.expect(companion.conversation_scroll_y > 100.0 and companion.conversation_scroll_y < 130.0);
    try std.testing.expect(companion.tail_gliding);
    try std.testing.expect(companion.conversation_follow_tail);
    var now: i64 = 1_016;
    while (companion.tail_gliding) {
        now += 16;
        previous = companion.conversation_scroll_y;
        companion.updateConversationExtent(130.0);
        companion.easeConversationTail(previous, now, 400.0, true);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 130.0), companion.conversation_scroll_y, 0.5);
    // Without streaming (or under reduced motion) it snaps.
    previous = companion.conversation_scroll_y;
    companion.updateConversationExtent(160.0);
    companion.easeConversationTail(previous, now + 16, 400.0, false);
    try std.testing.expectEqual(@as(f32, 160.0), companion.conversation_scroll_y);
    companion.scrollConversation(-50.0);
    try std.testing.expect(!companion.conversation_follow_tail);
}

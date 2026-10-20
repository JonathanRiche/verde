//! Setting up a workspace on another machine (docs/multi-machine-workspaces.md,
//! phase 3, desktop side).
//!
//! - A per-machine `core.snapshot` (workspaces scope) cache: which workspace
//!   ids and aliases each connected runtime has, and the normalized `origin`
//!   key of each workspace's primary repository with its checkout path.
//! - The local workspace's own `origin`, read from the local daemon's
//!   repository manifest on a short-lived worker thread.
//! - Run on tiers: machines that have the workspace, machines with a
//!   same-origin checkout ("Use it"), and "Set up on <machine>…".
//! - The transcript setup card and its remote folder browser, both ending in
//!   one `workspace.attach` call. The draft is never touched; the user sends
//!   again once the machine has the workspace.
//!
//! Every remote call goes through `RuntimeService.beginRpc` tickets, so
//! nothing here blocks the render thread. Calls share each runtime's single
//! RPC slot with chat sends; a busy slot is retried on a later poll.

const std = @import("std");
const headless = @import("headless");
const loop_wakeup = @import("loop_wakeup");
const repo_identity = @import("verde_remote").repo_identity;
const RuntimeService = @import("../runtime/service.zig");
const daemon_client = @import("../daemon/client.zig");
const chat_types = @import("chat_types.zig");

const log = std.log.scoped(.workspace_setup);
const page = std.heap.page_allocator;
const Mutex = std.atomic.Mutex;

pub const ATTACH_METHOD = "workspace.attach";
pub const DIRECTORY_LIST_METHOD = "workspace.directory.list";
/// Author of the transcript setup card message; the panel keys on it.
pub const CARD_AUTHOR = "Workspace setup";

/// A machine snapshot older than this is refetched when Run on or the card
/// needs it; one older than `SNAPSHOT_MAX_AGE_MS` is refetched regardless.
pub const SNAPSHOT_FRESH_MS: u64 = 30_000;
pub const SNAPSHOT_MAX_AGE_MS: u64 = 5 * 60_000;
const SNAPSHOT_RETRY_MIN_MS: u64 = 2_000;
const SNAPSHOT_RETRY_MAX_MS: u64 = 60_000;
/// A busy runtime slot (a chat send or readiness probe) is retried this soon.
const BUSY_RETRY_MS: u64 = 750;
/// An attach that cannot get the slot for this long gives up.
const ATTACH_SLOT_TIMEOUT_MS: u64 = 15_000;
const LOCAL_IDENTITY_FRESH_MS: u64 = 60_000;
const LOCAL_MANIFEST_TIMEOUT_MS: u32 = 5_000;

pub const MAX_MACHINE_WORKSPACES: usize = 256;
/// The daemon caps aliases per workspace at 64 (sorted).
pub const MAX_ALIASES: usize = 64;
pub const MAX_PICKER_ROWS: usize = 32;
pub const MAX_CANDIDATES: usize = 3;
const MAX_LOCAL_IDENTITIES: usize = 64;

// ---------------------------------------------------------------------------
// Machine snapshot cache
// ---------------------------------------------------------------------------

/// One workspace a remote machine reported in `core.snapshot`.
pub const MachineWorkspace = struct {
    workspace_id: []u8,
    label: []u8,
    /// Checkout of the primary repository on that machine (its binding for
    /// the machine's runtime id), else the workspace path.
    root_path: []u8,
    aliases: [][]u8,
    /// Normalized `origin` of the primary repository; null without one.
    group_key: ?[]u8,

    pub fn deinit(self: *MachineWorkspace, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.label);
        allocator.free(self.root_path);
        for (self.aliases) |alias| allocator.free(alias);
        allocator.free(self.aliases);
        if (self.group_key) |key| allocator.free(key);
        self.* = undefined;
    }

    pub fn answersTo(self: *const MachineWorkspace, workspace_id: []const u8) bool {
        if (std.mem.eql(u8, self.workspace_id, workspace_id)) return true;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, alias, workspace_id)) return true;
        }
        return false;
    }
};

pub fn freeWorkspaces(allocator: std.mem.Allocator, workspaces: *std.ArrayList(MachineWorkspace)) void {
    for (workspaces.items) |*workspace| workspace.deinit(allocator);
    workspaces.deinit(allocator);
}

const Machine = struct {
    profile_id: []u8,
    runtime_id: ?[]u8 = null,
    instance_id: ?[]u8 = null,
    loaded: bool = false,
    workspaces: std.ArrayList(MachineWorkspace) = .empty,
    fetched_at_ms: u64 = 0,
    ticket: ?RuntimeService.RpcTicket = null,
    /// Bumped whenever the cached identity changes; a ticket from an older
    /// generation is drained and discarded.
    generation: u64 = 0,
    ticket_generation: u64 = 0,
    retry_at_ms: u64 = 0,
    attempt: u8 = 0,
    want_refresh: bool = false,

    fn deinit(self: *Machine, allocator: std.mem.Allocator) void {
        allocator.free(self.profile_id);
        self.clearIdentity(allocator);
        freeWorkspaces(allocator, &self.workspaces);
    }

    fn clearIdentity(self: *Machine, allocator: std.mem.Allocator) void {
        if (self.runtime_id) |value| allocator.free(value);
        if (self.instance_id) |value| allocator.free(value);
        self.runtime_id = null;
        self.instance_id = null;
    }

    fn reset(self: *Machine, allocator: std.mem.Allocator) void {
        self.clearIdentity(allocator);
        freeWorkspaces(allocator, &self.workspaces);
        self.workspaces = .empty;
        self.loaded = false;
        self.fetched_at_ms = 0;
        self.generation +%= 1;
        self.retry_at_ms = 0;
        self.attempt = 0;
    }
};

/// Reads `result.snapshot.workspaces` from a `core.snapshot` JSON-RPC
/// response. Archived workspaces are skipped; lists are bounded.
pub fn parseSnapshotWorkspaces(
    allocator: std.mem.Allocator,
    response_json: []const u8,
    runtime_id: []const u8,
) !std.ArrayList(MachineWorkspace) {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{});
    defer parsed.deinit();
    const result = try rpcResult(parsed.value);
    const snapshot = objectField(result, "snapshot") orelse return error.InvalidDaemonResponse;
    const workspaces_value = objectField(snapshot, "workspaces") orelse return error.InvalidDaemonResponse;
    if (workspaces_value != .array) return error.InvalidDaemonResponse;

    var out: std.ArrayList(MachineWorkspace) = .empty;
    errdefer freeWorkspaces(allocator, &out);
    for (workspaces_value.array.items) |item| {
        if (out.items.len >= MAX_MACHINE_WORKSPACES) break;
        if (item != .object) continue;
        if (boolField(item, "archived")) continue;
        const workspace_id = stringField(item, "workspace_id") orelse continue;
        const path = stringField(item, "path") orelse "";
        const label = stringField(item, "label") orelse workspace_id;

        var group_origin: ?[]const u8 = null;
        var root_path: []const u8 = path;
        if (primaryRepository(item)) |repository| {
            group_origin = stringField(repository, "vcs_identity");
            if (repositoryRoot(repository, runtime_id)) |root| root_path = root;
        }

        var workspace: MachineWorkspace = .{
            .workspace_id = try allocator.dupe(u8, workspace_id),
            .label = &.{},
            .root_path = &.{},
            .aliases = &.{},
            .group_key = null,
        };
        errdefer allocator.free(workspace.workspace_id);
        workspace.label = try allocator.dupe(u8, label);
        errdefer allocator.free(workspace.label);
        workspace.root_path = try allocator.dupe(u8, root_path);
        errdefer allocator.free(workspace.root_path);
        workspace.group_key = if (group_origin) |origin| try repo_identity.normalizeAlloc(allocator, origin) else null;
        errdefer if (workspace.group_key) |key| allocator.free(key);
        workspace.aliases = try parseAliases(allocator, item);
        errdefer {
            for (workspace.aliases) |alias| allocator.free(alias);
            allocator.free(workspace.aliases);
        }
        try out.append(allocator, workspace);
    }
    return out;
}

fn parseAliases(allocator: std.mem.Allocator, workspace: std.json.Value) ![][]u8 {
    const value = objectField(workspace, "aliases") orelse return try allocator.alloc([]u8, 0);
    if (value != .array) return try allocator.alloc([]u8, 0);
    var aliases: std.ArrayList([]u8) = .empty;
    errdefer {
        for (aliases.items) |alias| allocator.free(alias);
        aliases.deinit(allocator);
    }
    for (value.array.items) |alias| {
        if (aliases.items.len >= MAX_ALIASES) break;
        if (alias != .string or alias.string.len == 0) continue;
        try aliases.append(allocator, try allocator.dupe(u8, alias.string));
    }
    return aliases.toOwnedSlice(allocator);
}

/// The repository whose id is `primary` (the doc's `group_key` source),
/// else the workspace's default repository.
fn primaryRepository(workspace: std.json.Value) ?std.json.Value {
    const repositories = objectField(workspace, "repositories") orelse return null;
    if (repositories != .array) return null;
    const default_id = stringField(workspace, "default_repository_id");
    var fallback: ?std.json.Value = null;
    for (repositories.array.items) |repository| {
        if (repository != .object) continue;
        const id = stringField(repository, "repository_id") orelse continue;
        if (std.mem.eql(u8, id, chat_types.PRIMARY_REPOSITORY_ID)) return repository;
        if (default_id != null and std.mem.eql(u8, id, default_id.?)) fallback = repository;
    }
    return fallback;
}

fn repositoryRoot(repository: std.json.Value, runtime_id: []const u8) ?[]const u8 {
    const bindings = objectField(repository, "bindings") orelse return null;
    if (bindings != .array) return null;
    var any: ?[]const u8 = null;
    for (bindings.array.items) |binding| {
        if (binding != .object) continue;
        const root = stringField(binding, "root_path") orelse continue;
        const binding_runtime = stringField(binding, "runtime_id") orelse "";
        if (std.mem.eql(u8, binding_runtime, runtime_id)) return root;
        if (any == null) any = root;
    }
    return any;
}

// ---------------------------------------------------------------------------
// Tiers
// ---------------------------------------------------------------------------

/// Where a machine sits in Run on for the current workspace.
pub const Tier = enum {
    /// The machine has a workspace with this id, directly or as an alias.
    has_workspace,
    /// The machine has a checkout with the same `origin`: "Use it".
    same_origin,
    /// Neither: "Set up on <machine>…" opens the setup card.
    set_up,
    /// Today's entry: the runtime cannot attach (no `workspace.attach.v1`),
    /// is not connected, or its workspaces are not known yet.
    plain,

    fn rank(self: Tier) u8 {
        return switch (self) {
            .has_workspace => 0,
            .same_origin => 1,
            .plain => 2,
            .set_up => 3,
        };
    }
};

pub const TierInput = struct {
    /// Connected and advertising `workspace.attach.v1`.
    attach_capable: bool,
    /// The machine's workspaces are known.
    loaded: bool,
    has_workspace: bool,
    same_origin_count: usize,
};

pub fn classify(input: TierInput) Tier {
    if (input.has_workspace) return .has_workspace;
    if (!input.attach_capable or !input.loaded) return .plain;
    if (input.same_origin_count > 0) return .same_origin;
    return .set_up;
}

pub fn findWorkspace(workspaces: []const MachineWorkspace, workspace_id: []const u8) ?*const MachineWorkspace {
    for (workspaces) |*workspace| {
        if (workspace.answersTo(workspace_id)) return workspace;
    }
    return null;
}

/// Indices of the machine's workspaces whose primary repository has
/// `group_key`. Several when the machine has worktrees or second clones.
pub fn sameOriginCandidates(workspaces: []const MachineWorkspace, group_key: ?[]const u8, out: []usize) usize {
    const key = group_key orelse return 0;
    var count: usize = 0;
    for (workspaces, 0..) |workspace, index| {
        if (count == out.len) break;
        const other = workspace.group_key orelse continue;
        if (!std.mem.eql(u8, other, key)) continue;
        out[count] = index;
        count += 1;
    }
    return count;
}

/// A remote binding-missing rejection opens the setup card only when the
/// machine can attach; otherwise the send keeps today's error row.
pub fn rejectionOpensCard(err: anyerror, attach_capable: bool) bool {
    return attach_capable and err == error.RemoteWorkspaceBindingMissing;
}

// ---------------------------------------------------------------------------
// workspace.attach request and errors
// ---------------------------------------------------------------------------

pub const AttachMutation = struct {
    request_key: []const u8,
    client_id: []const u8,
};

/// Wire params of `workspace.attach` (phase 3a contract).
pub const AttachParams = struct {
    mutation: AttachMutation,
    workspace_id: []const u8,
    label: []const u8,
    repository_id: []const u8,
    role: []const u8,
    root_path: []const u8,
    expect_identity: ?[]const u8 = null,
};

pub const AttachRequest = struct {
    workspace_id: []const u8,
    label: []const u8,
    repository_id: []const u8,
    root_path: []const u8,
    /// Raw `origin` of the source workspace. Always sent when it has one.
    expect_identity: ?[]const u8,
};

pub fn attachParams(request: AttachRequest, request_key: []const u8, client_id: []const u8) AttachParams {
    return .{
        .mutation = .{ .request_key = request_key, .client_id = client_id },
        .workspace_id = request.workspace_id,
        .label = request.label,
        .repository_id = request.repository_id,
        .role = if (std.mem.eql(u8, request.repository_id, chat_types.PRIMARY_REPOSITORY_ID)) "primary" else "context",
        .root_path = request.root_path,
        .expect_identity = request.expect_identity,
    };
}

pub const AttachFailure = enum {
    not_found,
    identity_mismatch,
    path_outside_roots,
    /// The caller's id already names a different folder on that machine.
    conflict,
    scope,
    unsupported,
    unreachable_runtime,
    other,
};

pub fn classifyAttachError(code: []const u8) AttachFailure {
    if (std.mem.eql(u8, code, "not_found") or std.mem.eql(u8, code, headless.protocol.ERR_RESOURCE_NOT_FOUND)) return .not_found;
    if (std.mem.eql(u8, code, "identity_mismatch")) return .identity_mismatch;
    if (std.mem.eql(u8, code, "path_outside_roots")) return .path_outside_roots;
    if (std.mem.eql(u8, code, "conflict") or std.mem.eql(u8, code, headless.protocol.ERR_CONFLICT)) return .conflict;
    if (std.mem.eql(u8, code, "forbidden") or std.mem.eql(u8, code, "insufficient_scope") or
        std.mem.eql(u8, code, "authentication_rejected")) return .scope;
    if (std.mem.eql(u8, code, "method_not_found") or std.mem.eql(u8, code, "unknown_method") or
        std.mem.eql(u8, code, "unsupported")) return .unsupported;
    return .other;
}

/// One sentence for the card; `machine` names the target.
pub fn attachFailureMessage(buffer: []u8, failure: AttachFailure, machine: []const u8) []const u8 {
    return switch (failure) {
        .not_found => std.fmt.bufPrint(buffer, "That folder no longer exists on {s}. Pick another one.", .{machine}),
        .identity_mismatch => std.fmt.bufPrint(buffer, "That folder's git origin doesn't match this workspace, or it has none. Pick the matching checkout on {s}.", .{machine}),
        .path_outside_roots => std.fmt.bufPrint(buffer, "{s} only allows folders under its home or VERDE_DIRECTORY_ROOTS. Pick a folder there.", .{machine}),
        .conflict => std.fmt.bufPrint(buffer, "{s} already uses this workspace for a different folder. Pick another folder.", .{machine}),
        .scope => std.fmt.bufPrint(buffer, "Setting up a workspace on {s} needs a Full device or the owner. This device can't change its repositories.", .{machine}),
        .unsupported => std.fmt.bufPrint(buffer, "Verde on {s} is too old to set up workspaces. Update it, then try again.", .{machine}),
        .unreachable_runtime => std.fmt.bufPrint(buffer, "{s} could not be reached. Check the connection, then try again.", .{machine}),
        .other => std.fmt.bufPrint(buffer, "{s} could not set up this workspace. Try again.", .{machine}),
    } catch "This machine could not set up the workspace.";
}

// ---------------------------------------------------------------------------
// Card text
// ---------------------------------------------------------------------------

pub const CardPhase = enum { choosing, attaching, done };

pub const CardText = struct {
    machine: []const u8,
    workspace: []const u8,
    candidates: []const []const u8 = &.{},
    /// The local workspace has a usable `origin`.
    local_has_origin: bool = true,
    /// This device lacks `repository:write` on the machine.
    scope_denied: bool = false,
    phase: CardPhase = .choosing,
    /// Folder the machine now uses (phase `.done`).
    attached_path: []const u8 = "",
    /// Last failure, shown under the choices.
    notice: []const u8 = "",
};

/// Selectable body of the setup card (the buttons are drawn separately).
pub fn cardBodyAlloc(allocator: std.mem.Allocator, text: CardText) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    if (text.phase == .done) {
        try w.print("{s} now has \u{201C}{s}\u{201D} at {s}. Send your message again to run it there.", .{ text.machine, text.workspace, text.attached_path });
        return out.toOwnedSlice();
    }
    try w.print("{s} doesn't have \u{201C}{s}\u{201D} yet. Chats here will run on {s}.", .{ text.machine, text.workspace, text.machine });
    if (text.scope_denied) {
        try w.print("\nSetting it up needs a Full device or the owner of {s}. Pair this device with Full access, or ask the owner to set it up.", .{text.machine});
    } else if (text.candidates.len > 0) {
        for (text.candidates) |candidate| try w.print("\n{s} \u{00B7} same origin", .{candidate});
    } else if (!text.local_has_origin) {
        try w.print("\nThis workspace has no git origin, so Verde can't find its checkout. Pick its folder on {s}.", .{text.machine});
    } else {
        try w.print("\nNo checkout with the same origin was found on {s}. Pick its folder.", .{text.machine});
    }
    if (text.phase == .attaching) try w.writeAll("\nSetting up\u{2026}");
    if (text.notice.len > 0) try w.print("\n{s}", .{text.notice});
    return out.toOwnedSlice();
}

pub const CardButtonKind = enum { use_candidate, pick_folder, cancel };

pub const CardButton = struct {
    kind: CardButtonKind,
    /// Candidate index for `.use_candidate`.
    index: usize = 0,
    label: []const u8,
};

pub const MAX_CARD_BUTTONS: usize = MAX_CANDIDATES + 2;

/// Buttons for the card's current state, written into `out`.
pub fn cardButtons(phase: CardPhase, scope_denied: bool, candidate_names: []const []const u8, out: *[MAX_CARD_BUTTONS]CardButton, label_storage: *[MAX_CANDIDATES][96]u8) []const CardButton {
    if (phase != .choosing) return out[0..0];
    var count: usize = 0;
    if (!scope_denied) {
        for (candidate_names, 0..) |name, index| {
            if (index == MAX_CANDIDATES) break;
            const label = if (candidate_names.len == 1)
                "Use it"
            else
                std.fmt.bufPrint(&label_storage[index], "Use {s}", .{name}) catch "Use it";
            out[count] = .{ .kind = .use_candidate, .index = index, .label = label };
            count += 1;
        }
        out[count] = .{ .kind = .pick_folder, .label = "Pick folder\u{2026}" };
        count += 1;
    }
    out[count] = .{ .kind = .cancel, .label = "Cancel" };
    count += 1;
    return out[0..count];
}

// ---------------------------------------------------------------------------
// Local workspace origin (local daemon, worker thread)
// ---------------------------------------------------------------------------

const LocalIdentity = struct {
    workspace_id: []u8,
    /// Raw `origin` of the primary repository (sent as `expect_identity`).
    origin: ?[]u8 = null,
    group_key: ?[]u8 = null,
    fetched_at_ms: u64 = 0,
    known: bool = false,

    fn deinit(self: *LocalIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        if (self.origin) |value| allocator.free(value);
        if (self.group_key) |value| allocator.free(value);
    }
};

const LocalLane = struct {
    mutex: Mutex = .unlocked,
    worker: ?std.Thread = null,
    done: bool = false,
    workspace_id: ?[]u8 = null,
    pref_path: ?[]u8 = null,
    /// Result: whether the call succeeded, and the raw origin (page-owned).
    ok: bool = false,
    origin: ?[]u8 = null,

    fn lock(self: *LocalLane) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn clear(self: *LocalLane) void {
        if (self.workspace_id) |value| page.free(value);
        if (self.pref_path) |value| page.free(value);
        if (self.origin) |value| page.free(value);
        self.* = .{};
    }
};

fn localWorker(lane: *LocalLane) void {
    var ok = false;
    var origin: ?[]u8 = null;
    fetch: {
        var transport: daemon_client.HeadlessTransport = .{
            .allocator = page,
            .pref_path = lane.pref_path.?,
            .timeout_ms = LOCAL_MANIFEST_TIMEOUT_MS,
        };
        var client = daemon_client.headlessClient(page, &transport);
        var parsed = client.call(
            headless.store_protocol.METHOD_WORKSPACE_REPOSITORY_MANIFEST_GET,
            headless.store_protocol.WorkspaceRepositoryManifestRequest{ .workspace_id = lane.workspace_id.? },
        ) catch break :fetch;
        defer parsed.deinit();
        if (parsed.response.err != null) {
            // A workspace the daemon doesn't know has no origin to match.
            ok = true;
            break :fetch;
        }
        const result = parsed.response.result orelse break :fetch;
        ok = true;
        const repository = primaryRepository(result) orelse break :fetch;
        const raw = stringField(repository, "vcs_identity") orelse break :fetch;
        origin = page.dupe(u8, raw) catch null;
    }
    lane.lock();
    lane.ok = ok;
    lane.origin = origin;
    lane.done = true;
    lane.mutex.unlock();
    loop_wakeup.notify();
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const Card = struct {
    project_id: []u8,
    local_thread_id: []u8,
    profile_id: []u8,
    machine_label: []u8,
    workspace_label: []u8,
    /// Address of the card message's current body: identifies the live row
    /// even when earlier transcript rows move.
    body_addr: usize = 0,
    phase: CardPhase = .choosing,
    scope_denied: bool = false,
    local_has_origin: bool = true,
    candidates: std.ArrayList([]u8) = .empty,
    attached_path: ?[]u8 = null,
    notice: ?[]u8 = null,

    fn deinit(self: *Card, allocator: std.mem.Allocator) void {
        allocator.free(self.project_id);
        allocator.free(self.local_thread_id);
        allocator.free(self.profile_id);
        allocator.free(self.machine_label);
        allocator.free(self.workspace_label);
        self.clearCandidates(allocator);
        self.candidates.deinit(allocator);
        if (self.attached_path) |value| allocator.free(value);
        if (self.notice) |value| allocator.free(value);
    }

    fn clearCandidates(self: *Card, allocator: std.mem.Allocator) void {
        for (self.candidates.items) |value| allocator.free(value);
        self.candidates.clearRetainingCapacity();
    }

    fn setNotice(self: *Card, allocator: std.mem.Allocator, notice: ?[]const u8) void {
        if (self.notice) |value| allocator.free(value);
        self.notice = if (notice) |value| allocator.dupe(u8, value) catch null else null;
    }
};

const AttachStep = enum { register, attach };

const AttachJob = struct {
    profile_id: []u8,
    project_id: []u8,
    local_thread_id: []u8,
    workspace_id: []u8,
    label: []u8,
    repository_id: []u8,
    root_path: []u8,
    expect_identity: ?[]u8,
    request_key: []u8,
    client_id: ?[]u8 = null,
    step: AttachStep = .register,
    ticket: ?RuntimeService.RpcTicket = null,
    started_ms: u64,
    retry_at_ms: u64 = 0,

    fn deinit(self: *AttachJob, allocator: std.mem.Allocator) void {
        allocator.free(self.profile_id);
        allocator.free(self.project_id);
        allocator.free(self.local_thread_id);
        allocator.free(self.workspace_id);
        allocator.free(self.label);
        allocator.free(self.repository_id);
        allocator.free(self.root_path);
        if (self.expect_identity) |value| allocator.free(value);
        allocator.free(self.request_key);
        if (self.client_id) |value| allocator.free(value);
    }
};

const Browse = struct {
    profile_id: []u8,
    ticket: ?RuntimeService.RpcTicket = null,
    /// Path the outstanding ticket lists (empty = first root).
    requested: []u8 = &.{},
    retry_at_ms: u64 = 0,

    fn deinit(self: *Browse, allocator: std.mem.Allocator) void {
        allocator.free(self.profile_id);
        allocator.free(self.requested);
    }
};

pub const PickerRow = struct {
    profile_index: usize = 0,
    tier: Tier = .plain,
    label_buf: [160]u8 = undefined,
    label_len: usize = 0,
    description_buf: [320]u8 = undefined,
    description_len: usize = 0,
    badge: []const u8 = "",
};

pub const State = struct {
    machines: std.ArrayList(Machine) = .empty,
    local: std.ArrayList(LocalIdentity) = .empty,
    local_lane: LocalLane = .{},
    card: ?Card = null,
    attach: ?AttachJob = null,
    /// Tickets whose owner went away; drained so the runtime slot frees.
    orphan_tickets: std.ArrayList(RuntimeService.RpcTicket) = .empty,
    browse: ?Browse = null,
    /// Run on rows ordered by tier, rebuilt by `syncPickerRows`.
    picker_rows: [MAX_PICKER_ROWS]PickerRow = undefined,
    picker_row_count: usize = 0,
    /// Set when cached data changed so an open Run on picker refreshes.
    picker_stale: bool = false,
    request_counter: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.machines.items) |*machine| machine.deinit(allocator);
        self.machines.deinit(allocator);
        for (self.local.items) |*entry| entry.deinit(allocator);
        self.local.deinit(allocator);
        if (self.local_lane.worker) |thread| thread.join();
        self.local_lane.clear();
        if (self.card) |*card| card.deinit(allocator);
        if (self.attach) |*job| job.deinit(allocator);
        if (self.browse) |*browse| browse.deinit(allocator);
        self.orphan_tickets.deinit(allocator);
        self.* = .{};
    }

    /// Picker row for display index `profile_row` (0-based among profiles);
    /// null when rows were not built for the current profile list.
    pub fn pickerRow(self: *const State, profile_row: usize, profile_count: usize) ?*const PickerRow {
        if (self.picker_row_count != profile_count or profile_row >= self.picker_row_count) return null;
        return &self.picker_rows[profile_row];
    }

    /// Maps a picker display position to the profile list index.
    pub fn pickerProfileIndex(self: *const State, profile_row: usize, profile_count: usize) usize {
        const row = self.pickerRow(profile_row, profile_count) orelse return profile_row;
        return row.profile_index;
    }

    /// Maps a profile list index back to its picker display position.
    pub fn pickerDisplayRow(self: *const State, profile_index: usize, profile_count: usize) usize {
        if (self.picker_row_count != profile_count) return profile_index;
        for (self.picker_rows[0..self.picker_row_count], 0..) |row, display| {
            if (row.profile_index == profile_index) return display;
        }
        return profile_index;
    }

    pub fn rowLabel(row: *const PickerRow) []const u8 {
        return row.label_buf[0..row.label_len];
    }

    pub fn rowDescription(row: *const PickerRow) []const u8 {
        return row.description_buf[0..row.description_len];
    }

    fn findMachine(self: *State, profile_id: []const u8) ?*Machine {
        for (self.machines.items) |*entry| {
            if (std.mem.eql(u8, entry.profile_id, profile_id)) return entry;
        }
        return null;
    }

    fn findConstMachine(self: *const State, profile_id: []const u8) ?*const Machine {
        for (self.machines.items) |*entry| {
            if (std.mem.eql(u8, entry.profile_id, profile_id)) return entry;
        }
        return null;
    }

    fn localIdentity(self: *const State, workspace_id: []const u8) ?*const LocalIdentity {
        for (self.local.items) |*entry| {
            if (std.mem.eql(u8, entry.workspace_id, workspace_id)) return entry;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// AppState-facing API (`self` is *AppState)
// ---------------------------------------------------------------------------

fn currentProject(self: anytype) ?*const @TypeOf(self.project_controller.projects.items[0]) {
    const projects = self.project_controller.projects.items;
    if (projects.len == 0) return null;
    return &projects[@min(self.project_controller.selected_index, projects.len - 1)];
}

fn snapshotFor(self: anytype, profile_id: []const u8) ?RuntimeService.Snapshot {
    const service = self.runtime_service orelse return null;
    return service.snapshot(profile_id);
}

fn attachCapable(snapshot: RuntimeService.Snapshot) bool {
    return snapshot.execution_ready and snapshot.workspace_attach_capable;
}

/// Tier of `profile_id` for workspace `workspace_id`, with the same-origin
/// candidate indices written to `candidates`.
fn tierFor(self: anytype, profile_id: []const u8, workspace_id: []const u8, candidates: []usize, candidate_count: *usize) Tier {
    candidate_count.* = 0;
    const snapshot = snapshotFor(self, profile_id) orelse return .plain;
    const entry = self.workspace_setup.findConstMachine(profile_id);
    const loaded = entry != null and entry.?.loaded;
    const workspaces: []const MachineWorkspace = if (entry) |value| value.workspaces.items else &.{};
    const local = self.workspace_setup.localIdentity(workspace_id);
    const group_key: ?[]const u8 = if (local) |value| value.group_key else null;
    candidate_count.* = sameOriginCandidates(workspaces, group_key, candidates);
    return classify(.{
        .attach_capable = attachCapable(snapshot),
        .loaded = loaded,
        .has_workspace = findWorkspace(workspaces, workspace_id) != null,
        .same_origin_count = candidate_count.*,
    });
}

/// Rebuilds Run on rows (tier, label, description, order) for the current
/// workspace. Called whenever the picker syncs.
pub fn syncPickerRows(self: anytype) void {
    const state = &self.workspace_setup;
    state.picker_stale = false;
    const profiles = self.runtime_picker_profiles.items;
    if (profiles.len > MAX_PICKER_ROWS) {
        state.picker_row_count = 0;
        return;
    }
    noteInterest(self);
    const project = currentProject(self);
    const workspace_id: []const u8 = if (project) |value| value.id else "";
    const workspace_label: []const u8 = if (project) |value| value.label else "";
    for (profiles, 0..) |configured, index| {
        var row: PickerRow = .{ .profile_index = index };
        var candidates: [MAX_CANDIDATES]usize = undefined;
        var candidate_count: usize = 0;
        row.tier = if (workspace_id.len == 0) .plain else tierFor(self, configured.profile_id, workspace_id, &candidates, &candidate_count);
        const snapshot = snapshotFor(self, configured.profile_id);
        const machine_label: []const u8 = if (snapshot) |value| value.label else configured.profile_id;
        const scope_denied = if (snapshot) |value| value.repository_write_granted == false else false;
        switch (row.tier) {
            .has_workspace, .plain => {},
            .same_origin => {
                const machine = state.findConstMachine(configured.profile_id).?;
                const first = machine.workspaces.items[candidates[0]].root_path;
                row.label_len = copyInto(&row.label_buf, machine_label);
                const description = if (candidate_count > 1)
                    std.fmt.bufPrint(&row.description_buf, "Same origin \u{00B7} Use it \u{00B7} {s} (+{d} more)", .{ first, candidate_count - 1 })
                else
                    std.fmt.bufPrint(&row.description_buf, "Same origin \u{00B7} Use it \u{00B7} {s}", .{first});
                row.description_len = if (description) |value| value.len else |_| 0;
                row.badge = "Use it";
            },
            .set_up => {
                const label = std.fmt.bufPrint(&row.label_buf, "Set up on {s}\u{2026}", .{machine_label}) catch
                    row.label_buf[0..copyInto(&row.label_buf, machine_label)];
                row.label_len = label.len;
                const description = if (scope_denied)
                    std.fmt.bufPrint(&row.description_buf, "Setting up needs a Full device or the owner", .{})
                else
                    std.fmt.bufPrint(&row.description_buf, "\u{201C}{s}\u{201D} isn't on this machine yet", .{workspace_label});
                row.description_len = if (description) |value| value.len else |_| 0;
                row.badge = "Set up";
            },
        }
        state.picker_rows[index] = row;
    }
    state.picker_row_count = profiles.len;
    // Stable: equal tiers keep the configured order.
    std.sort.insertion(PickerRow, state.picker_rows[0..state.picker_row_count], {}, struct {
        fn lessThan(_: void, a: PickerRow, b: PickerRow) bool {
            return a.tier.rank() < b.tier.rank();
        }
    }.lessThan);
}

fn copyInto(buffer: []u8, value: []const u8) usize {
    const len = @min(buffer.len, value.len);
    @memcpy(buffer[0..len], value[0..len]);
    return len;
}

/// Run on asked for `profile_id`. Consumes the choice when its tier needs
/// setup (Use it / Set up on…); returns false to keep today's selection.
pub fn handlePickerSelection(self: anytype, profile_id: []const u8) bool {
    if (std.mem.eql(u8, profile_id, chat_types.LOCAL_RUNTIME_PROFILE_ID)) return false;
    const thread = self.currentThread();
    // A started chat stays on its machine; the existing path explains that.
    if (thread.committed or thread.pinnedRuntimeRoute() != null) return false;
    const project = currentProject(self) orelse return false;
    var candidates: [MAX_CANDIDATES]usize = undefined;
    var candidate_count: usize = 0;
    const tier = tierFor(self, profile_id, project.id, &candidates, &candidate_count);
    switch (tier) {
        .has_workspace, .plain => return false,
        .same_origin => {
            self.closePaletteRuntimePicker();
            const snapshot = snapshotFor(self, profile_id) orelse return false;
            if (snapshot.repository_write_granted == false) {
                _ = openCard(self, project.id, thread.local_thread_id, profile_id);
                return true;
            }
            const machine = self.workspace_setup.findConstMachine(profile_id) orelse return false;
            const root = machine.workspaces.items[candidates[0]].root_path;
            startAttach(self, profile_id, project.id, thread.local_thread_id, root);
            var buffer: [256]u8 = undefined;
            self.setSidebarNotice(std.fmt.bufPrint(&buffer, "Setting up \u{201C}{s}\u{201D} on {s}\u{2026}", .{ project.label, snapshot.label }) catch "Setting up the workspace\u{2026}");
            return true;
        },
        .set_up => {
            self.closePaletteRuntimePicker();
            _ = openCard(self, project.id, thread.local_thread_id, profile_id);
            return true;
        },
    }
}

/// `commitAcceptanceDispatch` rejected a send with
/// `RemoteWorkspaceBindingMissing`: open the card in place of the failure
/// row when `profile_id` can attach. Returns false to keep today's row.
pub fn openCardForRejectedSend(self: anytype, project_id: []const u8, local_thread_id: []const u8, profile_id: []const u8) bool {
    const snapshot = snapshotFor(self, profile_id) orelse return false;
    if (!rejectionOpensCard(error.RemoteWorkspaceBindingMissing, attachCapable(snapshot))) return false;
    // The machine said it lacks the workspace; whatever we cached is stale.
    if (self.workspace_setup.findMachine(profile_id)) |entry| entry.want_refresh = true;
    return openCard(self, project_id, local_thread_id, profile_id);
}

fn openCard(self: anytype, project_id: []const u8, local_thread_id: []const u8, profile_id: []const u8) bool {
    const resolved = self.projectThreadIndexByLocalId(project_id, local_thread_id) orelse return false;
    const project = &self.project_controller.projects.items[resolved.project_index];
    const thread = &project.threads.items[resolved.thread_index];
    const snapshot = snapshotFor(self, profile_id) orelse return false;
    closeCard(self, false);
    noteInterest(self);

    var card: Card = .{
        .project_id = self.allocator.dupe(u8, project_id) catch return false,
        .local_thread_id = &.{},
        .profile_id = &.{},
        .machine_label = &.{},
        .workspace_label = &.{},
        .scope_denied = snapshot.repository_write_granted == false,
    };
    card.local_thread_id = self.allocator.dupe(u8, local_thread_id) catch {
        self.allocator.free(card.project_id);
        return false;
    };
    card.profile_id = self.allocator.dupe(u8, profile_id) catch return dropCard(self, &card);
    card.machine_label = self.allocator.dupe(u8, snapshot.label) catch return dropCard(self, &card);
    card.workspace_label = self.allocator.dupe(u8, project.label) catch return dropCard(self, &card);
    _ = refreshCardCandidates(self, &card);

    const body = cardBodyAlloc(self.allocator, cardText(&card)) catch return dropCard(self, &card);
    defer self.allocator.free(body);
    self.appendMessageToThread(thread, .system, CARD_AUTHOR, body, null, &.{}) catch |err| {
        log.warn("failed to append workspace setup card: {s}", .{@errorName(err)});
        return dropCard(self, &card);
    };
    card.body_addr = @intFromPtr(thread.messages.items[thread.messages.items.len - 1].body.ptr);
    self.workspace_setup.card = card;
    if (resolved.project_index == self.project_controller.selected_index and
        resolved.thread_index == project.currentThreadIndex())
    {
        self.requestTranscriptScrollToBottom();
    }
    self.markDirty();
    return true;
}

fn dropCard(self: anytype, card: *Card) bool {
    // Fields not yet duplicated are empty slices, which free safely.
    card.deinit(self.allocator);
    return false;
}

fn cardText(card: *const Card) CardText {
    return .{
        .machine = card.machine_label,
        .workspace = card.workspace_label,
        .candidates = @ptrCast(card.candidates.items),
        .local_has_origin = card.local_has_origin,
        .scope_denied = card.scope_denied,
        .phase = card.phase,
        .attached_path = card.attached_path orelse "",
        .notice = card.notice orelse "",
    };
}

/// Recomputes the card's same-origin checkouts from the caches. Returns
/// whether they changed.
fn refreshCardCandidates(self: anytype, card: *Card) bool {
    const state = &self.workspace_setup;
    const local = state.localIdentity(card.project_id);
    const group_key: ?[]const u8 = if (local) |value| value.group_key else null;
    const has_origin = local == null or !local.?.known or group_key != null;
    const machine = state.findConstMachine(card.profile_id);
    const workspaces: []const MachineWorkspace = if (machine) |value| value.workspaces.items else &.{};
    var indices: [MAX_CANDIDATES]usize = undefined;
    const count = sameOriginCandidates(workspaces, group_key, &indices);
    var changed = has_origin != card.local_has_origin or count != card.candidates.items.len;
    if (!changed) {
        for (indices[0..count], card.candidates.items) |index, existing| {
            if (!std.mem.eql(u8, workspaces[index].root_path, existing)) changed = true;
        }
    }
    if (!changed) return false;
    card.local_has_origin = has_origin;
    card.clearCandidates(self.allocator);
    for (indices[0..count]) |index| {
        const owned = self.allocator.dupe(u8, workspaces[index].root_path) catch break;
        card.candidates.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            break;
        };
    }
    return true;
}

/// Rewrites the card message's body after its state changed.
fn rewriteCardMessage(self: anytype) void {
    const card = if (self.workspace_setup.card) |*value| value else return;
    const message = cardMessage(self, card) orelse return;
    const body = cardBodyAlloc(self.allocator, cardText(card)) catch return;
    defer self.allocator.free(body);
    const owned = self.allocator.dupeZ(u8, body) catch return;
    self.allocator.free(message.body);
    message.body = owned;
    card.body_addr = @intFromPtr(owned.ptr);
    self.markDirty();
}

fn cardMessageIndex(self: anytype, card: *const Card) ?struct { thread: *chat_types.ChatThread, index: usize } {
    const resolved = self.projectThreadIndexByLocalId(card.project_id, card.local_thread_id) orelse return null;
    const thread = &self.project_controller.projects.items[resolved.project_index].threads.items[resolved.thread_index];
    var index = thread.messages.items.len;
    while (index > 0) {
        index -= 1;
        const message = &thread.messages.items[index];
        if (@intFromPtr(message.body.ptr) != card.body_addr) continue;
        if (message.role != .system or !std.mem.eql(u8, message.author, CARD_AUTHOR)) return null;
        return .{ .thread = thread, .index = index };
    }
    return null;
}

fn cardMessage(self: anytype, card: *const Card) ?*chat_types.ChatMessage {
    const found = cardMessageIndex(self, card) orelse return null;
    return &found.thread.messages.items[found.index];
}

/// Closes the active card. `remove_message` drops its transcript row
/// (Cancel); a finished card keeps its row as a record.
fn closeCard(self: anytype, remove_message: bool) void {
    var card = self.workspace_setup.card orelse return;
    self.workspace_setup.card = null;
    defer card.deinit(self.allocator);
    if (!remove_message) return;
    const found = cardMessageIndex(self, &card) orelse return;
    const removed = found.thread.messages.orderedRemove(found.index);
    self.releaseMessage(removed);
    self.markDirty();
}

/// Buttons of the live setup card when `body` is its message body; null for
/// any other row (including finished or cancelled cards).
pub fn cardButtonsFor(
    self: anytype,
    body: []const u8,
    out: *[MAX_CARD_BUTTONS]CardButton,
    label_storage: *[MAX_CANDIDATES][96]u8,
) ?[]const CardButton {
    const card = if (self.workspace_setup.card) |*value| value else return null;
    if (card.body_addr == 0 or @intFromPtr(body.ptr) != card.body_addr) return null;
    var names: [MAX_CANDIDATES][]const u8 = undefined;
    const count = @min(card.candidates.items.len, MAX_CANDIDATES);
    for (card.candidates.items[0..count], 0..) |path, index| names[index] = std.fs.path.basename(path);
    const buttons = cardButtons(card.phase, card.scope_denied, names[0..count], out, label_storage);
    return if (buttons.len == 0) null else buttons;
}

/// Runs a card button.
pub fn cardAction(self: anytype, kind: CardButtonKind, index: usize) void {
    const card = if (self.workspace_setup.card) |*value| value else return;
    switch (kind) {
        .cancel => closeCard(self, true),
        .use_candidate => {
            if (card.phase != .choosing or index >= card.candidates.items.len) return;
            const root = self.allocator.dupe(u8, card.candidates.items[index]) catch return;
            defer self.allocator.free(root);
            startAttach(self, card.profile_id, card.project_id, card.local_thread_id, root);
        },
        .pick_folder => {
            if (card.phase != .choosing) return;
            startRemoteBrowse(self, card.profile_id, card.machine_label, card.project_id);
        },
    }
    self.markDirty();
}

// ---------------------------------------------------------------------------
// Remote folder browser
// ---------------------------------------------------------------------------

fn startRemoteBrowse(self: anytype, profile_id: []const u8, machine_label: []const u8, workspace_id: []const u8) void {
    self.picker_state.mutex.lock();
    if (self.picker_state.status == .pending) {
        self.picker_state.mutex.unlock();
        return;
    }
    self.picker_state.status = .pending;
    self.picker_state.selected_path = null;
    self.picker_state.mutex.unlock();

    if (self.workspace_setup.browse) |*browse| {
        if (browse.ticket) |ticket| self.workspace_setup.orphan_tickets.append(self.allocator, ticket) catch {};
        browse.deinit(self.allocator);
    }
    self.workspace_setup.browse = null;
    const owned = self.allocator.dupe(u8, profile_id) catch return;
    self.workspace_setup.browse = .{ .profile_id = owned };
    const local = self.workspace_setup.localIdentity(workspace_id);
    const key: ?[]const u8 = if (local) |value| value.group_key else null;
    self.folder_browser.openRemote(self.allocator, machine_label, key);
    self.palette_modal_text_focus = .folder_browser;
    self.modal_text_selection_anchor = null;
    self.markDirty();
}

/// `pollPicker` hands every finished folder pick here first. Returns true
/// when the pick belonged to the remote setup browser.
pub fn takePickerResult(self: anytype, picked_path: ?[]u8, selected: bool) bool {
    var browse = self.workspace_setup.browse orelse return false;
    self.workspace_setup.browse = null;
    if (browse.ticket) |ticket| self.workspace_setup.orphan_tickets.append(self.allocator, ticket) catch {};
    defer browse.deinit(self.allocator);
    const path = picked_path orelse return true;
    defer page.free(path);
    // Nothing was listed yet (the machine never answered): nothing to use.
    if (!selected or path.len == 0) return true;
    const card = if (self.workspace_setup.card) |*value| value else return true;
    startAttach(self, card.profile_id, card.project_id, card.local_thread_id, path);
    return true;
}

fn pollBrowse(self: anytype, service: *RuntimeService, now_ms: u64) bool {
    const browse = if (self.workspace_setup.browse) |*value| value else return false;
    if (browse.ticket) |ticket| {
        var result = (service.takeRpcResult(ticket) catch {
            browse.ticket = null;
            self.folder_browser.failRemoteListing("The folder list could not be loaded.");
            return true;
        }) orelse return false;
        defer result.deinit();
        browse.ticket = null;
        applyBrowseResult(self, &result);
        return true;
    }
    if (!self.folder_browser.open or !self.folder_browser.isRemote()) return false;
    if (now_ms < browse.retry_at_ms) return false;
    const requested = self.folder_browser.takeRemoteRequest() orelse return false;
    const owned = self.allocator.dupe(u8, requested) catch return false;
    self.allocator.free(browse.requested);
    browse.requested = owned;
    const ticket = (if (owned.len == 0)
        service.beginRpc(browse.profile_id, DIRECTORY_LIST_METHOD, struct {}{})
    else
        service.beginRpc(browse.profile_id, DIRECTORY_LIST_METHOD, .{ .path = owned })) catch |err| {
        if (err == error.RuntimeRpcBusy or err == error.RuntimeRpcResultPending) {
            // Ask again shortly for the same path.
            self.folder_browser.rearmRemoteRequest(self.allocator, owned);
            browse.retry_at_ms = now_ms + BUSY_RETRY_MS;
            return false;
        }
        self.folder_browser.failRemoteListing("That machine is not connected.");
        return true;
    };
    browse.ticket = ticket;
    return true;
}

fn applyBrowseResult(self: anytype, result: *RuntimeService.RpcCallResult) void {
    const response = switch (result.*) {
        .response => |value| value,
        .failed => {
            self.folder_browser.failRemoteListing("That machine could not be reached.");
            return;
        },
        .canceled => {
            self.folder_browser.failRemoteListing("The folder list was canceled.");
            return;
        },
    };
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response.json, .{}) catch {
        self.folder_browser.failRemoteListing("That machine sent an unreadable folder list.");
        return;
    };
    defer parsed.deinit();
    if (rpcErrorCode(parsed.value)) |code| {
        self.folder_browser.failRemoteListing(if (std.mem.eql(u8, code, "path_outside_roots"))
            "That folder is outside the folders this machine allows."
        else if (std.mem.eql(u8, code, "not_found"))
            "That folder does not exist on this machine."
        else
            "That machine could not list this folder.");
        return;
    }
    const result_value = rpcResult(parsed.value) catch {
        self.folder_browser.failRemoteListing("That machine sent an unreadable folder list.");
        return;
    };
    const path = stringField(result_value, "path") orelse {
        self.folder_browser.failRemoteListing("That machine sent an unreadable folder list.");
        return;
    };
    const directories = objectField(result_value, "directories");
    var entries: std.ArrayList(@import("folder_browser.zig").RemoteEntry) = .empty;
    defer entries.deinit(self.allocator);
    if (directories) |list| if (list == .array) for (list.array.items) |item| {
        if (item != .object) continue;
        const name = stringField(item, "name") orelse continue;
        entries.append(self.allocator, .{ .name = name, .git_identity = stringField(item, "git_identity") }) catch break;
    };
    self.folder_browser.applyRemoteListing(self.allocator, path, stringField(result_value, "parent"), entries.items);
}

// ---------------------------------------------------------------------------
// Attach job
// ---------------------------------------------------------------------------

fn startAttach(self: anytype, profile_id: []const u8, project_id: []const u8, local_thread_id: []const u8, root_path: []const u8) void {
    const state = &self.workspace_setup;
    if (state.attach != null) {
        self.setSidebarNotice("A workspace setup is already running.");
        return;
    }
    const resolved = self.projectThreadIndexByLocalId(project_id, local_thread_id) orelse return;
    const project = &self.project_controller.projects.items[resolved.project_index];
    const thread = &project.threads.items[resolved.thread_index];
    const local = state.localIdentity(project_id);
    const expect: ?[]const u8 = if (local) |value| value.origin else null;
    const now_ms = self.runtimeNowMs();
    state.request_counter +%= 1;

    const allocator = self.allocator;
    const job: AttachJob = .{
        .profile_id = allocator.dupe(u8, profile_id) catch return,
        .project_id = allocator.dupe(u8, project_id) catch return,
        .local_thread_id = allocator.dupe(u8, local_thread_id) catch return,
        .workspace_id = allocator.dupe(u8, project.id) catch return,
        .label = allocator.dupe(u8, project.label) catch return,
        .repository_id = allocator.dupe(u8, thread.selectedRuntimeRoute().repository_id) catch return,
        .root_path = allocator.dupe(u8, root_path) catch return,
        .expect_identity = if (expect) |value| allocator.dupe(u8, value) catch return else null,
        .request_key = std.fmt.allocPrint(allocator, "gui:workspace.attach:{x}:{d}:{d}", .{
            std.hash.Wyhash.hash(0, root_path),
            now_ms,
            state.request_counter,
        }) catch return,
        .started_ms = now_ms,
    };
    state.attach = job;
    if (state.card) |*card| {
        if (std.mem.eql(u8, card.profile_id, profile_id)) {
            card.phase = .attaching;
            card.setNotice(allocator, null);
            rewriteCardMessage(self);
        }
    }
    self.markDirty();
}

fn pollAttach(self: anytype, service: *RuntimeService, now_ms: u64) bool {
    const state = &self.workspace_setup;
    const job = if (state.attach) |*value| value else return false;
    if (job.ticket) |ticket| {
        var result = (service.takeRpcResult(ticket) catch {
            job.ticket = null;
            finishAttach(self, .{ .failure = .unreachable_runtime });
            return true;
        }) orelse return false;
        defer result.deinit();
        job.ticket = null;
        applyAttachStep(self, &result);
        return true;
    }
    if (now_ms < job.retry_at_ms) return false;
    const ticket = switch (job.step) {
        .register => service.beginRpc(job.profile_id, "daemon.client.register", .{ .persistent = false }),
        .attach => service.beginRpc(job.profile_id, ATTACH_METHOD, attachParams(.{
            .workspace_id = job.workspace_id,
            .label = job.label,
            .repository_id = job.repository_id,
            .root_path = job.root_path,
            .expect_identity = job.expect_identity,
        }, job.request_key, job.client_id orelse "")),
    } catch |err| {
        if ((err == error.RuntimeRpcBusy or err == error.RuntimeRpcResultPending) and
            now_ms -| job.started_ms < ATTACH_SLOT_TIMEOUT_MS)
        {
            job.retry_at_ms = now_ms + BUSY_RETRY_MS;
            return false;
        }
        log.warn("workspace attach rpc start failed: {s}", .{@errorName(err)});
        finishAttach(self, .{ .failure = .unreachable_runtime });
        return true;
    };
    job.ticket = ticket;
    return false;
}

const AttachOutcome = union(enum) {
    attached: []const u8,
    failure: AttachFailure,
};

fn applyAttachStep(self: anytype, result: *RuntimeService.RpcCallResult) void {
    const job = &self.workspace_setup.attach.?;
    const response = switch (result.*) {
        .response => |value| value,
        .failed, .canceled => return finishAttach(self, .{ .failure = .unreachable_runtime }),
    };
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response.json, .{}) catch
        return finishAttach(self, .{ .failure = .other });
    defer parsed.deinit();
    if (rpcErrorCode(parsed.value)) |code| {
        log.info("workspace setup {s} failed: code={s}", .{ @tagName(job.step), code });
        return finishAttach(self, .{ .failure = classifyAttachError(code) });
    }
    const value = rpcResult(parsed.value) catch return finishAttach(self, .{ .failure = .other });
    switch (job.step) {
        .register => {
            const client_id = stringField(value, "client_id") orelse return finishAttach(self, .{ .failure = .other });
            job.client_id = self.allocator.dupe(u8, client_id) catch return finishAttach(self, .{ .failure = .other });
            job.step = .attach;
        },
        .attach => {
            const root = stringField(value, "root_path") orelse job.root_path;
            const owned = self.allocator.dupe(u8, root) catch return finishAttach(self, .{ .attached = job.root_path });
            defer self.allocator.free(owned);
            finishAttach(self, .{ .attached = owned });
        },
    }
}

fn finishAttach(self: anytype, outcome: AttachOutcome) void {
    const state = &self.workspace_setup;
    var job = state.attach orelse return;
    state.attach = null;
    defer job.deinit(self.allocator);
    if (state.findMachine(job.profile_id)) |entry| entry.want_refresh = true;
    state.picker_stale = true;

    const card: ?*Card = if (state.card) |*value|
        if (std.mem.eql(u8, value.profile_id, job.profile_id) and std.mem.eql(u8, value.local_thread_id, job.local_thread_id)) value else null
    else
        null;
    switch (outcome) {
        .attached => |root| {
            selectRuntimeForThread(self, job.project_id, job.local_thread_id, job.profile_id);
            const machine_label: []const u8 = if (snapshotFor(self, job.profile_id)) |snapshot| snapshot.label else job.profile_id;
            var buffer: [256]u8 = undefined;
            self.setSidebarNotice(std.fmt.bufPrint(&buffer, "{s} is set up. Send your message again to run it there.", .{machine_label}) catch "Set up. Send your message again.");
            if (card) |value| {
                value.phase = .done;
                if (value.attached_path) |old| self.allocator.free(old);
                value.attached_path = self.allocator.dupe(u8, root) catch null;
                rewriteCardMessage(self);
                closeCard(self, false);
            }
        },
        .failure => |failure| {
            const machine_label: []const u8 = if (snapshotFor(self, job.profile_id)) |snapshot| snapshot.label else job.profile_id;
            var buffer: [320]u8 = undefined;
            const message = attachFailureMessage(&buffer, failure, machine_label);
            if (card) |value| {
                value.phase = .choosing;
                if (failure == .scope) value.scope_denied = true;
                value.setNotice(self.allocator, message);
                rewriteCardMessage(self);
            } else if (openCard(self, job.project_id, job.local_thread_id, job.profile_id)) {
                // "Use it" from Run on failed: explain it in the card.
                if (state.card) |*opened| {
                    if (failure == .scope) opened.scope_denied = true;
                    opened.setNotice(self.allocator, message);
                    rewriteCardMessage(self);
                }
            } else {
                self.setSidebarNotice(message);
            }
        },
    }
    self.markDirty();
}

fn selectRuntimeForThread(self: anytype, project_id: []const u8, local_thread_id: []const u8, profile_id: []const u8) void {
    const resolved = self.projectThreadIndexByLocalId(project_id, local_thread_id) orelse return;
    const thread = &self.project_controller.projects.items[resolved.project_index].threads.items[resolved.thread_index];
    const current = thread.selectedRuntimeRoute();
    if (std.mem.eql(u8, current.profile_id, profile_id)) return;
    const result = thread.selectRuntimeRoute(self.allocator, .{
        .profile_id = profile_id,
        .repository_id = current.repository_id,
        .relative_cwd = current.relative_cwd,
    }) catch |err| {
        log.warn("failed to select the set-up runtime: {s}", .{@errorName(err)});
        return;
    };
    if (result == .updated) self.connectRuntimeProfileFromPicker(profile_id);
}

// ---------------------------------------------------------------------------
// Polling
// ---------------------------------------------------------------------------

/// Marks cached data as wanted now (Run on opened, card opened). Machines
/// older than `SNAPSHOT_FRESH_MS` refetch, and the current workspace's
/// local origin is looked up if unknown or old.
pub fn noteInterest(self: anytype) void {
    const now_ms = self.runtimeNowMs();
    for (self.workspace_setup.machines.items) |*entry| {
        if (!entry.loaded or now_ms -| entry.fetched_at_ms >= SNAPSHOT_FRESH_MS) entry.want_refresh = true;
    }
    if (currentProject(self)) |project| requestLocalIdentity(self, project.id, now_ms);
}

fn requestLocalIdentity(self: anytype, workspace_id: []const u8, now_ms: u64) void {
    const state = &self.workspace_setup;
    if (state.localIdentity(workspace_id)) |entry| {
        if (entry.known and now_ms -| entry.fetched_at_ms < LOCAL_IDENTITY_FRESH_MS) return;
    }
    const lane = &state.local_lane;
    if (lane.worker != null) return;
    lane.workspace_id = page.dupe(u8, workspace_id) catch return;
    lane.pref_path = page.dupe(u8, self.storage.pref_path) catch {
        lane.clear();
        return;
    };
    lane.done = false;
    lane.worker = std.Thread.spawn(.{}, localWorker, .{lane}) catch {
        lane.clear();
        return;
    };
}

fn pollLocalIdentity(self: anytype) bool {
    const state = &self.workspace_setup;
    const lane = &state.local_lane;
    const thread = lane.worker orelse return false;
    lane.lock();
    const done = lane.done;
    lane.mutex.unlock();
    if (!done) return false;
    thread.join();
    lane.worker = null;
    defer lane.clear();
    if (!lane.ok) return false;
    const workspace_id = lane.workspace_id.?;
    const entry = blk: {
        for (state.local.items) |*existing| {
            if (std.mem.eql(u8, existing.workspace_id, workspace_id)) break :blk existing;
        }
        if (state.local.items.len >= MAX_LOCAL_IDENTITIES) {
            var oldest = state.local.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
        const owned = self.allocator.dupe(u8, workspace_id) catch return false;
        state.local.append(self.allocator, .{ .workspace_id = owned }) catch {
            self.allocator.free(owned);
            return false;
        };
        break :blk &state.local.items[state.local.items.len - 1];
    };
    if (entry.origin) |value| self.allocator.free(value);
    if (entry.group_key) |value| self.allocator.free(value);
    entry.origin = if (lane.origin) |value| self.allocator.dupe(u8, value) catch null else null;
    entry.group_key = if (lane.origin) |value| repo_identity.normalizeAlloc(self.allocator, value) catch null else null;
    entry.known = true;
    entry.fetched_at_ms = self.runtimeNowMs();
    return true;
}

fn syncMachines(self: anytype) void {
    const state = &self.workspace_setup;
    const profiles = self.runtime_picker_profiles.items;
    // Drop machines whose profile is gone; their tickets drain as orphans.
    var index: usize = 0;
    while (index < state.machines.items.len) {
        const entry = &state.machines.items[index];
        const present = for (profiles) |configured| {
            if (std.mem.eql(u8, configured.profile_id, entry.profile_id)) break true;
        } else false;
        if (present) {
            index += 1;
            continue;
        }
        if (entry.ticket) |ticket| state.orphan_tickets.append(self.allocator, ticket) catch {};
        var removed = state.machines.swapRemove(index);
        removed.deinit(self.allocator);
        state.picker_stale = true;
    }
    for (profiles) |configured| {
        if (state.machines.items.len >= MAX_PICKER_ROWS) break;
        if (state.findMachine(configured.profile_id) != null) continue;
        const owned = self.allocator.dupe(u8, configured.profile_id) catch continue;
        state.machines.append(self.allocator, .{ .profile_id = owned }) catch self.allocator.free(owned);
    }
}

fn pollMachine(self: anytype, service: *RuntimeService, entry: *Machine, now_ms: u64) bool {
    var changed = false;
    if (entry.ticket) |ticket| {
        var result = (service.takeRpcResult(ticket) catch {
            entry.ticket = null;
            scheduleSnapshotRetry(entry, now_ms);
            return false;
        }) orelse return false;
        defer result.deinit();
        entry.ticket = null;
        if (entry.ticket_generation != entry.generation) return false;
        changed = applySnapshotResult(self, entry, &result, now_ms);
    }
    const snapshot = service.snapshot(entry.profile_id) orelse return changed;
    const runtime = snapshot.runtime orelse return changed;
    if (!snapshot.execution_ready) return changed;
    // A new runtime identity (connect, daemon restart) invalidates the cache.
    if (entry.runtime_id == null or entry.instance_id == null or
        !std.mem.eql(u8, entry.runtime_id.?, runtime.runtime_id) or
        !std.mem.eql(u8, entry.instance_id.?, runtime.instance_id))
    {
        const had_data = entry.loaded;
        entry.reset(self.allocator);
        entry.runtime_id = self.allocator.dupe(u8, runtime.runtime_id) catch return changed;
        entry.instance_id = self.allocator.dupe(u8, runtime.instance_id) catch return changed;
        if (had_data) changed = true;
    }
    if (entry.ticket != null or now_ms < entry.retry_at_ms) return changed;
    const due = !entry.loaded or entry.want_refresh or now_ms -| entry.fetched_at_ms >= SNAPSHOT_MAX_AGE_MS;
    if (!due) return changed;
    const scopes = [_][]const u8{headless.store_protocol.SNAPSHOT_SCOPE_WORKSPACES};
    const ticket = service.beginRpc(entry.profile_id, headless.store_protocol.METHOD_CORE_SNAPSHOT, headless.store_protocol.CoreSnapshotRequest{
        .scopes = &scopes,
    }) catch |err| {
        if (err == error.RuntimeRpcBusy or err == error.RuntimeRpcResultPending) {
            entry.retry_at_ms = now_ms + BUSY_RETRY_MS;
        } else {
            scheduleSnapshotRetry(entry, now_ms);
        }
        return changed;
    };
    entry.ticket = ticket;
    entry.ticket_generation = entry.generation;
    entry.want_refresh = false;
    return changed;
}

fn scheduleSnapshotRetry(entry: *Machine, now_ms: u64) void {
    entry.attempt +|= 1;
    const shift: u6 = @intCast(@min(entry.attempt, 5));
    entry.retry_at_ms = now_ms + @min(SNAPSHOT_RETRY_MIN_MS << shift, SNAPSHOT_RETRY_MAX_MS);
}

fn applySnapshotResult(self: anytype, entry: *Machine, result: *RuntimeService.RpcCallResult, now_ms: u64) bool {
    const response = switch (result.*) {
        .response => |value| value,
        .failed, .canceled => {
            scheduleSnapshotRetry(entry, now_ms);
            return false;
        },
    };
    var workspaces = parseSnapshotWorkspaces(self.allocator, response.json, entry.runtime_id orelse "") catch |err| {
        log.warn("machine snapshot for {s} unreadable: {s}", .{ entry.profile_id, @errorName(err) });
        scheduleSnapshotRetry(entry, now_ms);
        return false;
    };
    errdefer freeWorkspaces(self.allocator, &workspaces);
    freeWorkspaces(self.allocator, &entry.workspaces);
    entry.workspaces = workspaces;
    entry.loaded = true;
    entry.fetched_at_ms = now_ms;
    entry.attempt = 0;
    entry.retry_at_ms = 0;
    return true;
}

fn drainOrphans(self: anytype, service: *RuntimeService) void {
    const tickets = &self.workspace_setup.orphan_tickets;
    var index: usize = 0;
    while (index < tickets.items.len) {
        const taken = service.takeRpcResult(tickets.items[index]) catch {
            _ = tickets.swapRemove(index);
            continue;
        };
        if (taken) |value| {
            var result = value;
            result.deinit();
            _ = tickets.swapRemove(index);
            continue;
        }
        index += 1;
    }
}

/// Advances caches, the attach job and the remote browser. Called from
/// `pollRuntimeService` on the UI thread; returns true when anything a
/// frame shows changed.
pub fn poll(self: anytype) bool {
    var changed = pollLocalIdentity(self);
    const service = self.runtime_service orelse return changed;
    const now_ms = self.runtimeNowMs();
    drainOrphans(self, service);
    syncMachines(self);
    // Attach first, then the open browser, then background snapshots: they
    // share each runtime's single RPC slot.
    changed = pollAttach(self, service, now_ms) or changed;
    changed = pollBrowse(self, service, now_ms) or changed;
    var data_changed = changed;
    for (self.workspace_setup.machines.items) |*entry| {
        data_changed = pollMachine(self, service, entry, now_ms) or data_changed;
    }
    if (data_changed) {
        self.workspace_setup.picker_stale = true;
        if (self.workspace_setup.card) |*card| {
            if (card.phase == .choosing and refreshCardCandidates(self, card)) rewriteCardMessage(self);
        }
    }
    return data_changed;
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

fn rpcResult(value: std.json.Value) !std.json.Value {
    if (value != .object) return error.InvalidDaemonResponse;
    if (value.object.get("error")) |_| return error.DaemonRequestFailed;
    return value.object.get("result") orelse error.InvalidDaemonResponse;
}

fn rpcErrorCode(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const err = value.object.get("error") orelse return null;
    if (err != .object) return "unknown";
    return stringField(err, "code") orelse "unknown";
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = objectField(value, key) orelse return null;
    return if (field == .string) field.string else null;
}

fn boolField(value: std.json.Value, key: []const u8) bool {
    const field = objectField(value, key) orelse return false;
    return field == .bool and field.bool;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const SNAPSHOT_FIXTURE =
    \\{"jsonrpc":"2.0","id":7,"result":{"store_revision":12,"snapshot":{"workspaces":[
    \\ {"workspace_id":"ws-lightning","label":"verde","path":"/home/zod/verde",
    \\  "aliases":["dd1e48af92e33f49"],"default_repository_id":"primary",
    \\  "repositories":[{"repository_id":"primary","label":"verde","vcs_identity":"git@github.com:JonathanRiche/verde.git",
    \\   "bindings":[{"runtime_id":"other","root_path":"/mnt/elsewhere"},{"runtime_id":"rt-zod","root_path":"/home/zod/dev/verde"}]}]},
    \\ {"workspace_id":"ws-wt","label":"verde-wt","path":"/home/zod/verde-wt",
    \\  "repositories":[{"repository_id":"primary","label":"verde","vcs_identity":"https://github.com/jonathanriche/verde"}]},
    \\ {"workspace_id":"ws-fork","label":"fork","path":"/home/zod/fork",
    \\  "repositories":[{"repository_id":"primary","label":"fork","vcs_identity":"https://github.com/someone/verde"}]},
    \\ {"workspace_id":"ws-old","label":"old","path":"/home/zod/old","archived":true},
    \\ {"workspace_id":"ws-plain","label":"notes","path":"/home/zod/notes"}
    \\]}}}
;

test "machine snapshot parses ids, aliases, group keys and checkout paths" {
    const allocator = std.testing.allocator;
    var workspaces = try parseSnapshotWorkspaces(allocator, SNAPSHOT_FIXTURE, "rt-zod");
    defer freeWorkspaces(allocator, &workspaces);
    try std.testing.expectEqual(@as(usize, 4), workspaces.items.len);
    const first = workspaces.items[0];
    try std.testing.expectEqualStrings("ws-lightning", first.workspace_id);
    try std.testing.expectEqualStrings("/home/zod/dev/verde", first.root_path);
    try std.testing.expectEqualStrings("v1:github.com/jonathanriche/verde", first.group_key.?);
    try std.testing.expect(first.answersTo("dd1e48af92e33f49"));
    try std.testing.expect(!first.answersTo("nope"));
    // No binding: the workspace path stands in for the checkout.
    try std.testing.expectEqualStrings("/home/zod/verde-wt", workspaces.items[1].root_path);
    try std.testing.expect(workspaces.items[3].group_key == null);

    try std.testing.expectError(error.DaemonRequestFailed, parseSnapshotWorkspaces(
        allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":\"forbidden\",\"message\":\"no\"}}",
        "rt",
    ));
}

test "run on tiers: has workspace, same origin, set up, plain" {
    const allocator = std.testing.allocator;
    var workspaces = try parseSnapshotWorkspaces(allocator, SNAPSHOT_FIXTURE, "rt-zod");
    defer freeWorkspaces(allocator, &workspaces);
    const items = workspaces.items;
    var candidates: [MAX_CANDIDATES]usize = undefined;

    // Direct id and alias both count as having the workspace.
    try std.testing.expect(findWorkspace(items, "ws-plain") != null);
    try std.testing.expect(findWorkspace(items, "dd1e48af92e33f49") != null);
    try std.testing.expectEqual(Tier.has_workspace, classify(.{ .attach_capable = false, .loaded = true, .has_workspace = true, .same_origin_count = 0 }));

    // Same origin across URL spellings; the fork never matches.
    const key = "v1:github.com/jonathanriche/verde";
    const count = sameOriginCandidates(items, key, &candidates);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 0), candidates[0]);
    try std.testing.expectEqual(@as(usize, 1), candidates[1]);
    try std.testing.expectEqual(Tier.same_origin, classify(.{ .attach_capable = true, .loaded = true, .has_workspace = false, .same_origin_count = count }));

    // No origin locally: nothing to match, so the machine needs setting up.
    try std.testing.expectEqual(@as(usize, 0), sameOriginCandidates(items, null, &candidates));
    try std.testing.expectEqual(Tier.set_up, classify(.{ .attach_capable = true, .loaded = true, .has_workspace = false, .same_origin_count = 0 }));

    // Unknown workspaces keep today's plain entry until the snapshot lands.
    try std.testing.expectEqual(Tier.plain, classify(.{ .attach_capable = true, .loaded = false, .has_workspace = false, .same_origin_count = 0 }));
}

test "runtimes without workspace.attach.v1 keep the plain entry and the error row" {
    try std.testing.expectEqual(Tier.plain, classify(.{ .attach_capable = false, .loaded = true, .has_workspace = false, .same_origin_count = 2 }));
    try std.testing.expectEqual(Tier.plain, classify(.{ .attach_capable = false, .loaded = true, .has_workspace = false, .same_origin_count = 0 }));
    try std.testing.expect(!rejectionOpensCard(error.RemoteWorkspaceBindingMissing, false));
    try std.testing.expect(rejectionOpensCard(error.RemoteWorkspaceBindingMissing, true));
    try std.testing.expect(!rejectionOpensCard(error.DaemonRequestFailed, true));
}

test "workspace.attach params carry the caller's id, role and expected identity" {
    const allocator = std.testing.allocator;
    const params = attachParams(.{
        .workspace_id = "dd1e48af92e33f49",
        .label = "verde",
        .repository_id = "primary",
        .root_path = "/home/zod/dev/verde",
        .expect_identity = "git@github.com:JonathanRiche/verde.git",
    }, "gui:workspace.attach:1", "client-9");
    const json = try std.json.Stringify.valueAlloc(allocator, params, .{});
    defer allocator.free(json);
    try std.testing.expectEqualStrings(
        \\{"mutation":{"request_key":"gui:workspace.attach:1","client_id":"client-9"},"workspace_id":"dd1e48af92e33f49","label":"verde","repository_id":"primary","role":"primary","root_path":"/home/zod/dev/verde","expect_identity":"git@github.com:JonathanRiche/verde.git"}
    , json);

    const context = attachParams(.{
        .workspace_id = "w",
        .label = "w",
        .repository_id = "docs",
        .root_path = "/r",
        .expect_identity = null,
    }, "k", "c");
    try std.testing.expectEqualStrings("context", context.role);
    try std.testing.expect(context.expect_identity == null);
}

test "attach errors map to card messages" {
    try std.testing.expectEqual(AttachFailure.identity_mismatch, classifyAttachError("identity_mismatch"));
    try std.testing.expectEqual(AttachFailure.path_outside_roots, classifyAttachError("path_outside_roots"));
    try std.testing.expectEqual(AttachFailure.not_found, classifyAttachError("not_found"));
    try std.testing.expectEqual(AttachFailure.conflict, classifyAttachError("conflict"));
    try std.testing.expectEqual(AttachFailure.scope, classifyAttachError("forbidden"));
    try std.testing.expectEqual(AttachFailure.unsupported, classifyAttachError("method_not_found"));
    try std.testing.expectEqual(AttachFailure.other, classifyAttachError("store_unavailable"));
    var buffer: [320]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, attachFailureMessage(&buffer, .scope, "Lightning"), "Full device") != null);
}

test "setup card text and buttons follow the doc copy" {
    const allocator = std.testing.allocator;
    const body = try cardBodyAlloc(allocator, .{
        .machine = "Lightning",
        .workspace = "verde",
        .candidates = &.{"/home/zod/dev/verde"},
    });
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        "Lightning doesn't have \u{201C}verde\u{201D} yet. Chats here will run on Lightning.\n/home/zod/dev/verde \u{00B7} same origin",
        body,
    );

    var out: [MAX_CARD_BUTTONS]CardButton = undefined;
    var labels: [MAX_CANDIDATES][96]u8 = undefined;
    const one = cardButtons(.choosing, false, &.{"verde"}, &out, &labels);
    try std.testing.expectEqual(@as(usize, 3), one.len);
    try std.testing.expectEqualStrings("Use it", one[0].label);
    try std.testing.expectEqual(CardButtonKind.pick_folder, one[1].kind);
    try std.testing.expectEqual(CardButtonKind.cancel, one[2].kind);
    const two = cardButtons(.choosing, false, &.{ "verde", "verde-wt" }, &out, &labels);
    try std.testing.expectEqualStrings("Use verde-wt", two[1].label);

    // Chat-preset devices get the scope explanation and only Cancel.
    const denied = try cardBodyAlloc(allocator, .{ .machine = "Lightning", .workspace = "verde", .scope_denied = true });
    defer allocator.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "needs a Full device or the owner") != null);
    const denied_buttons = cardButtons(.choosing, true, &.{"verde"}, &out, &labels);
    try std.testing.expectEqual(@as(usize, 1), denied_buttons.len);
    try std.testing.expectEqual(CardButtonKind.cancel, denied_buttons[0].kind);
    try std.testing.expectEqual(@as(usize, 0), cardButtons(.attaching, false, &.{"verde"}, &out, &labels).len);

    const done = try cardBodyAlloc(allocator, .{ .machine = "Lightning", .workspace = "verde", .phase = .done, .attached_path = "/home/zod/dev/verde" });
    defer allocator.free(done);
    try std.testing.expect(std.mem.indexOf(u8, done, "Send your message again") != null);
}

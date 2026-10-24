//! Connect control-plane accounts for Settings › Connections and the
//! composer runtime picker. Each linked machine stays its own Connect
//! profile (own pin, link and runtime-local device credential); this module
//! only groups those profiles by control plane, keeps one long-lived Connect
//! session per account, and links the account's other machines through the
//! normal signed bootstrap. Nothing here is persisted and no credential is
//! held: bootstrap results pass straight to the host's commit.
//!
//! The functions taking `host` are duck-typed so production (the AppState
//! adapter in `runtime_connections_controller.zig`) and hermetic tests share
//! one implementation. A host provides:
//!   allocator: std.mem.Allocator
//!   fn profileCount(host) usize
//!   fn profileAt(host, index) ?ProfileRef        (slices valid for the call)
//!   fn createSession(host, url) !*connect_client.Session
//!   fn createMachineProfile(host, label, url) ![]u8  (caller frees)
//!   fn selectMachine(host, profile_id, Selection) !void
//!   fn commitMachine(host, profile_id, Commit) !bool  (true when durable)
//!   fn removeMachineProfile(host, profile_id) void
//!   fn machineLinked(host, profile_id, thread_id: ?[]const u8) void
//!   fn notice(host, text) void

const std = @import("std");
const builtin = @import("builtin");
const connect_client = @import("../runtime/connect_client.zig");
const profile = @import("../runtime/profile.zig");
const access_protocol = @import("headless").access_protocol;

const log = std.log.scoped(.native_connect_accounts);

/// Default managed control plane offered by the connection wizard.
pub const VERDE_CLOUD_URL: []const u8 = "https://cloud.verdeai.dev";
pub const VERDE_CLOUD_TITLE: []const u8 = "Verde Cloud";
/// Bound on distinct control planes shown; more are listed as plain rows.
pub const MAX_ACCOUNTS: usize = 8;
/// `link_machine` actions encode `account * LINK_ROW_STRIDE + machine`.
pub const LINK_ROW_STRIDE: usize = 64;
/// Composed `<account> · <machine>` picker label.
pub const MAX_DISPLAY_LABEL_BYTES: usize = 192;
const FALLBACK_DEVICE_LABEL = "Verde desktop";
const FALLBACK_MACHINE_NAME = "Cloud machine";

comptime {
    std.debug.assert(connect_client.MAX_INVENTORY_ROWS < LINK_ROW_STRIDE);
}

/// One Connect profile as the host sees it. Borrowed for the call only.
pub const ProfileRef = struct {
    profile_id: []const u8,
    label: []const u8,
    control_plane_url: []const u8,
    runtime_id: ?[]const u8,
    https_url: ?[]const u8,
};

/// Verified selection to commit before the device (generic inventories, and
/// integration backends after their signed grant).
pub const Selection = struct {
    link_id: []const u8,
    runtime_id: []const u8,
    instance_id: []const u8,
    https_url: []const u8,
    wss_url: []const u8,
    spki_sha256: []const u8,
};

pub const Commit = struct {
    runtime_id: []const u8,
    instance_id: []const u8,
    device_id: []const u8,
    device_credential: []const u8,
};

/// UI copy of one inventory row so rendering never borrows worker memory.
pub const Machine = struct {
    selection_key: ?[]u8 = null,
    link_id: []u8,
    runtime_id: []u8,
    instance_id: []u8,
    https_url: []u8,
    wss_url: []u8,
    spki_sha256: []u8,
    label: ?[]u8 = null,

    fn clone(allocator: std.mem.Allocator, row: connect_client.RuntimeRow) !Machine {
        var out: Machine = undefined;
        out.selection_key = if (row.selection_key) |key| try allocator.dupe(u8, key) else null;
        errdefer if (out.selection_key) |key| allocator.free(key);
        out.link_id = try allocator.dupe(u8, row.link_id);
        errdefer allocator.free(out.link_id);
        out.runtime_id = try allocator.dupe(u8, row.runtime_id);
        errdefer allocator.free(out.runtime_id);
        out.instance_id = try allocator.dupe(u8, row.instance_id);
        errdefer allocator.free(out.instance_id);
        out.https_url = try allocator.dupe(u8, row.https_url);
        errdefer allocator.free(out.https_url);
        out.wss_url = try allocator.dupe(u8, row.wss_url);
        errdefer allocator.free(out.wss_url);
        out.spki_sha256 = try allocator.dupe(u8, row.spki_sha256);
        errdefer allocator.free(out.spki_sha256);
        out.label = if (row.label) |value| try allocator.dupe(u8, value) else null;
        return out;
    }

    fn deinit(self: *Machine, allocator: std.mem.Allocator) void {
        if (self.selection_key) |key| allocator.free(key);
        allocator.free(self.link_id);
        allocator.free(self.runtime_id);
        allocator.free(self.instance_id);
        allocator.free(self.https_url);
        allocator.free(self.wss_url);
        allocator.free(self.spki_sha256);
        if (self.label) |value| allocator.free(value);
        self.* = undefined;
    }

    /// Name shown for this machine: the control plane's label, else the
    /// endpoint's first host label.
    pub fn name(self: *const Machine) []const u8 {
        return machineName(self.label, null, "", self.https_url);
    }
};

/// An in-flight link of one available machine.
pub const LinkJob = struct {
    profile_id: []u8,
    runtime_id: []u8,
    /// Draft that asked for this machine from the picker, if any.
    thread_id: ?[]u8,

    fn deinit(self: *LinkJob, allocator: std.mem.Allocator) void {
        allocator.free(self.profile_id);
        allocator.free(self.runtime_id);
        if (self.thread_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Account = struct {
    /// Control plane as stored in its profiles (already sanitized).
    control_plane_url: []u8,
    session: ?*connect_client.Session = null,
    /// The connection wizard currently borrows `session`.
    lent: bool = false,
    phase: connect_client.Phase = .idle,
    failure: ?connect_client.Failure = null,
    identity: ?[]u8 = null,
    machines: std.ArrayList(Machine) = .empty,
    machines_truncated: usize = 0,
    link: ?LinkJob = null,
    /// Profiles referencing this control plane at the last reconcile.
    profile_count: usize = 0,
    /// A session could not be created (for example the backend refused);
    /// the card offers Retry instead of re-creating every frame.
    session_unavailable: bool = false,

    fn deinit(self: *Account, allocator: std.mem.Allocator) void {
        if (self.session) |session| if (!self.lent) session.destroy();
        clearMachines(self, allocator);
        self.machines.deinit(allocator);
        if (self.identity) |value| allocator.free(value);
        if (self.link) |*job| job.deinit(allocator);
        allocator.free(self.control_plane_url);
        self.* = undefined;
    }

    pub fn title(self: *const Account) []const u8 {
        return accountTitle(self.control_plane_url);
    }

    /// Signed in with an inventory (or one being refreshed).
    pub fn signedIn(self: *const Account) bool {
        return switch (self.phase) {
            .signed_in, .inventory_loaded, .bootstrapping, .bootstrap_ready => true,
            .loading_inventory => self.machines.items.len > 0,
            else => false,
        };
    }

    /// True while the session is working and the user should wait.
    pub fn busy(self: *const Account) bool {
        return switch (self.phase) {
            .discovering, .signing_in, .loading_inventory, .bootstrapping => true,
            else => self.link != null,
        };
    }

    pub fn canSignIn(self: *const Account) bool {
        return self.session != null and !self.lent and self.phase == .discovered;
    }

    pub fn machineAt(self: *const Account, index: usize) ?*const Machine {
        if (index >= self.machines.items.len) return null;
        return &self.machines.items[index];
    }

    pub fn linkingRuntime(self: *const Account, runtime_id: []const u8) bool {
        const job = self.link orelse return false;
        return std.mem.eql(u8, job.runtime_id, runtime_id);
    }
};

/// Cached display label for one Connect profile.
pub const ProfileLabel = struct {
    profile_id: []u8,
    text: []u8,
    account: usize,
};

/// An account machine that has no profile yet, offered in the picker.
pub const Available = struct {
    account: usize,
    machine: usize,
    label_buf: [MAX_DISPLAY_LABEL_BYTES]u8 = undefined,
    label_len: usize = 0,

    pub fn label(self: *const Available) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

pub const State = struct {
    accounts: std.ArrayList(Account) = .empty,
    labels: std.ArrayList(ProfileLabel) = .empty,
    available: std.ArrayList(Available) = .empty,
    /// Hash of every input to `labels`/`available`; rebuilt when it moves.
    signature: u64 = 0,
    /// Account the Connections card should scroll to once.
    focus_account: ?usize = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.accounts.items) |*account| account.deinit(allocator);
        self.accounts.deinit(allocator);
        clearLabels(self, allocator);
        self.labels.deinit(allocator);
        self.available.deinit(allocator);
        self.* = undefined;
    }

    pub fn accountIndex(self: *const State, control_plane_url: []const u8) ?usize {
        for (self.accounts.items, 0..) |account, index| {
            if (sameControlPlane(account.control_plane_url, control_plane_url)) return index;
        }
        return null;
    }

    pub fn accountAt(self: *const State, index: usize) ?*const Account {
        if (index >= self.accounts.items.len) return null;
        return &self.accounts.items[index];
    }

    /// `<account> · <machine>` for a Connect profile, when known.
    pub fn displayLabel(self: *const State, profile_id: []const u8) ?[]const u8 {
        for (self.labels.items) |entry| {
            if (std.mem.eql(u8, entry.profile_id, profile_id)) return entry.text;
        }
        return null;
    }

    /// Machine part of the display label (after the account title).
    pub fn machineLabel(self: *const State, profile_id: []const u8) ?[]const u8 {
        for (self.labels.items) |entry| {
            if (!std.mem.eql(u8, entry.profile_id, profile_id)) continue;
            const account = self.accountAt(entry.account) orelse return entry.text;
            const prefix_len = account.title().len + SEPARATOR.len;
            return if (entry.text.len > prefix_len) entry.text[prefix_len..] else entry.text;
        }
        return null;
    }

    pub fn availableAt(self: *const State, index: usize) ?*const Available {
        if (index >= self.available.items.len) return null;
        return &self.available.items[index];
    }

    /// Account index that owns a Connect profile, if any.
    pub fn accountForProfile(self: *const State, profile_id: []const u8) ?usize {
        for (self.labels.items) |entry| {
            if (std.mem.eql(u8, entry.profile_id, profile_id)) return entry.account;
        }
        return null;
    }
};

const SEPARATOR = " \u{00B7} ";

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/// Stored control-plane URLs are sanitized (no trailing slash); compare the
/// scheme/host case-insensitively and tolerate a typed trailing slash.
pub fn sameControlPlane(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(normalizedUrl(a), normalizedUrl(b));
}

fn normalizedUrl(value: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    while (trimmed.len > "https://".len and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    return trimmed;
}

/// Account title: the managed default's name, else the control plane host.
pub fn accountTitle(control_plane_url: []const u8) []const u8 {
    if (sameControlPlane(control_plane_url, VERDE_CLOUD_URL)) return VERDE_CLOUD_TITLE;
    return urlHost(control_plane_url);
}

/// Host (and port) of an https URL, or the URL itself when unparsable.
pub fn urlHost(url: []const u8) []const u8 {
    const trimmed = normalizedUrl(url);
    const scheme = "https://";
    if (!std.ascii.startsWithIgnoreCase(trimmed, scheme)) return trimmed;
    const rest = trimmed[scheme.len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return rest[0..end];
}

/// First DNS label of an endpoint host (`w-pilot-02` for
/// `https://w-pilot-02.example.dev`).
pub fn hostName(https_url: []const u8) []const u8 {
    const host = urlHost(https_url);
    const end = std.mem.indexOfAny(u8, host, ".:") orelse host.len;
    return host[0..end];
}

/// Machine name: inventory label, else a profile label that names the
/// machine rather than the account, else the endpoint's first host label.
pub fn machineName(inventory_label: ?[]const u8, profile_label: ?[]const u8, account_title: []const u8, https_url: ?[]const u8) []const u8 {
    if (inventory_label) |value| {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len > 0) return trimmed;
    }
    if (profile_label) |value| {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, account_title)) return trimmed;
    }
    if (https_url) |url| {
        const host = hostName(url);
        if (host.len > 0) return host;
    }
    return FALLBACK_MACHINE_NAME;
}

/// Inventory row for a linked profile: runtime ID first (stable identity),
/// then the endpoint for profiles that predate a pinned identity.
pub fn matchMachine(machines: []const Machine, runtime_id: ?[]const u8, https_url: ?[]const u8) ?usize {
    if (runtime_id) |id| {
        for (machines, 0..) |machine, index| if (std.mem.eql(u8, machine.runtime_id, id)) return index;
    }
    if (https_url) |url| {
        for (machines, 0..) |machine, index| if (std.ascii.eqlIgnoreCase(normalizedUrl(machine.https_url), normalizedUrl(url))) return index;
    }
    return null;
}

/// Whether an inventory machine already has a profile on this desktop.
pub fn machineLinked(host: anytype, account: *const Account, machine: *const Machine) bool {
    return linkedProfileIndex(host, account, machine) != null;
}

fn linkedProfileIndex(host: anytype, account: *const Account, machine: *const Machine) ?usize {
    for (0..host.profileCount()) |index| {
        const ref = host.profileAt(index) orelse continue;
        if (!sameControlPlane(ref.control_plane_url, account.control_plane_url)) continue;
        if (ref.runtime_id) |id| {
            if (std.mem.eql(u8, id, machine.runtime_id)) return index;
            continue;
        }
        if (ref.https_url) |url| if (std.ascii.eqlIgnoreCase(normalizedUrl(url), normalizedUrl(machine.https_url))) return index;
    }
    return null;
}

/// Linked profiles of `account`, in host order.
pub fn profilesOf(host: anytype, account_url: []const u8, out: []usize) usize {
    var count: usize = 0;
    for (0..host.profileCount()) |index| {
        const ref = host.profileAt(index) orelse continue;
        if (!sameControlPlane(ref.control_plane_url, account_url)) continue;
        if (count == out.len) break;
        out[count] = index;
        count += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Account lifecycle
// ---------------------------------------------------------------------------

/// Brings accounts in line with the host's Connect profiles, polls each
/// account session, finishes link jobs, and rebuilds display labels. Returns
/// true when anything visible changed.
pub fn poll(host: anytype, state: *State) bool {
    var changed = reconcile(host, state);
    for (state.accounts.items, 0..) |_, index| {
        changed = pollAccount(host, state, index) or changed;
    }
    changed = rebuildLabels(host, state) or changed;
    return changed;
}

fn reconcile(host: anytype, state: *State) bool {
    const allocator = host.allocator;
    var changed = false;
    for (state.accounts.items) |*account| account.profile_count = 0;
    for (0..host.profileCount()) |index| {
        const ref = host.profileAt(index) orelse continue;
        if (state.accountIndex(ref.control_plane_url)) |existing| {
            state.accounts.items[existing].profile_count += 1;
            continue;
        }
        if (state.accounts.items.len >= MAX_ACCOUNTS) continue;
        const url = allocator.dupe(u8, normalizedUrl(ref.control_plane_url)) catch continue;
        state.accounts.append(allocator, .{ .control_plane_url = url, .profile_count = 1 }) catch {
            allocator.free(url);
            continue;
        };
        changed = true;
    }
    // An account whose last machine was removed goes away with its session,
    // unless the wizard holds the session or a link is still finishing.
    var index: usize = state.accounts.items.len;
    while (index > 0) {
        index -= 1;
        const account = &state.accounts.items[index];
        if (account.profile_count != 0 or account.lent or account.link != null) continue;
        account.deinit(allocator);
        _ = state.accounts.orderedRemove(index);
        if (state.focus_account) |focus| {
            if (focus == index) state.focus_account = null else if (focus > index) state.focus_account = focus - 1;
        }
        changed = true;
    }
    return changed;
}

fn ensureSession(host: anytype, account: *Account) void {
    if (account.session != null or account.lent or account.session_unavailable) return;
    account.session = host.createSession(account.control_plane_url) catch |err| {
        // SessionBusy means another view (the wizard) is attached; a later
        // poll retries once it closes. Anything else waits for Retry.
        if (err != error.SessionBusy) {
            log.warn("connect account session unavailable: {s}", .{@errorName(err)});
            account.session_unavailable = true;
        }
        return;
    };
    account.phase = .idle;
    account.failure = null;
}

fn pollAccount(host: anytype, state: *State, index: usize) bool {
    const allocator = host.allocator;
    const account = &state.accounts.items[index];
    ensureSession(host, account);
    if (account.lent) return false;
    const session = account.session orelse return false;
    var snapshot = session.poll();
    var changed = snapshot.phase != account.phase or snapshot.failure != account.failure;
    // Inventory needs no further input after sign-in.
    if (snapshot.phase == .signed_in and session.loadInventory()) {
        snapshot.phase = .loading_inventory;
        changed = true;
    }
    account.phase = snapshot.phase;
    account.failure = snapshot.failure;
    if (!optionalEql(account.identity, snapshot.identity)) {
        if (account.identity) |value| allocator.free(value);
        account.identity = if (snapshot.identity) |value| allocator.dupe(u8, value) catch null else null;
        changed = true;
    }
    if (!machinesEqual(account.machines.items, snapshot.runtimes) or account.machines_truncated != snapshot.runtimes_truncated) {
        clearMachines(account, allocator);
        for (snapshot.runtimes) |row| {
            var copy = Machine.clone(allocator, row) catch break;
            account.machines.append(allocator, copy) catch {
                copy.deinit(allocator);
                break;
            };
        }
        account.machines_truncated = snapshot.runtimes_truncated;
        changed = true;
    }
    if (account.link != null) changed = pollLink(host, account) or changed;
    return changed;
}

fn pollLink(host: anytype, account: *Account) bool {
    const allocator = host.allocator;
    const session = account.session orelse return false;
    var job = account.link.?;
    if (session.takeBootstrapResult()) |owned| {
        var result = owned;
        defer result.deinit();
        account.link = null;
        defer job.deinit(allocator);
        // An integration backend verifies its signed grant first and supplies
        // the selection; commit it right before the device credential.
        if (result.selection) |selection| {
            host.selectMachine(job.profile_id, .{
                .link_id = selection.link_id,
                .runtime_id = result.runtime_id,
                .instance_id = result.instance_id,
                .https_url = selection.https_url,
                .wss_url = selection.wss_url,
                .spki_sha256 = selection.spki_sha256,
            }) catch |err| {
                log.warn("connect account selection failed: {s}", .{@errorName(err)});
                host.removeMachineProfile(job.profile_id);
                host.notice("Could not save that machine's verified endpoint. Try Connect again.");
                return true;
            };
        }
        const durable = host.commitMachine(job.profile_id, .{
            .runtime_id = result.runtime_id,
            .instance_id = result.instance_id,
            .device_id = result.device_id,
            .device_credential = result.device_credential,
        }) catch |err| {
            log.warn("connect account device commit failed: {s}", .{@errorName(err)});
            host.removeMachineProfile(job.profile_id);
            host.notice("Could not store that machine's device credential. Try Connect again.");
            return true;
        };
        host.machineLinked(job.profile_id, job.thread_id);
        host.notice(if (durable)
            "Machine connected. Its device credential is in the OS credential store."
        else
            "Machine connected, but its device credential is kept in memory only on this platform.");
        return true;
    }
    switch (account.phase) {
        .bootstrapping, .bootstrap_ready => return false,
        else => {},
    }
    // The bootstrap ended without a result: drop the profile it created so
    // a refused machine leaves no half-linked row behind.
    account.link = null;
    host.removeMachineProfile(job.profile_id);
    host.notice(if (account.failure) |failure| failure.message() else "Could not connect that machine. Try again.");
    job.deinit(allocator);
    return true;
}

/// Starts linking machine `machine_index` of account `account_index`: creates
/// its profile, commits a generic selection, and requests the signed
/// bootstrap. `thread_id` selects the machine for that draft when done.
pub fn linkMachine(host: anytype, state: *State, account_index: usize, machine_index: usize, thread_id: ?[]const u8) bool {
    const allocator = host.allocator;
    if (account_index >= state.accounts.items.len) return false;
    const account = &state.accounts.items[account_index];
    const session = account.session orelse {
        host.notice("Sign in to this account first.");
        return false;
    };
    if (account.lent) {
        host.notice("Finish or close the connection dialog first.");
        return false;
    }
    if (account.link != null) {
        host.notice("Another machine is still connecting.");
        return false;
    }
    if (!account.signedIn()) {
        host.notice("Sign in to this account first.");
        return false;
    }
    const machine = account.machineAt(machine_index) orelse return false;
    if (linkedProfileIndex(host, account, machine) != null) {
        host.notice("That machine is already connected on this desktop.");
        return false;
    }
    const name = machineName(machine.label, null, "", machine.https_url);
    const label = if (profile.validateLabel(name)) |_| name else |_| FALLBACK_MACHINE_NAME;
    const profile_id = host.createMachineProfile(label, account.control_plane_url) catch |err| {
        log.warn("connect account profile create failed: {s}", .{@errorName(err)});
        host.notice("Could not save a connection for that machine.");
        return false;
    };
    var owned_profile = true;
    defer if (owned_profile) allocator.free(profile_id);
    if (machine.selection_key == null) {
        host.selectMachine(profile_id, .{
            .link_id = machine.link_id,
            .runtime_id = machine.runtime_id,
            .instance_id = machine.instance_id,
            .https_url = machine.https_url,
            .wss_url = machine.wss_url,
            .spki_sha256 = machine.spki_sha256,
        }) catch |err| {
            log.warn("connect account selection failed: {s}", .{@errorName(err)});
            host.removeMachineProfile(profile_id);
            host.notice("Could not save that machine's endpoint.");
            return false;
        };
    }
    const runtime_id = allocator.dupe(u8, machine.runtime_id) catch {
        host.removeMachineProfile(profile_id);
        return false;
    };
    const thread = if (thread_id) |value| allocator.dupe(u8, value) catch null else null;
    var device_buffer: [access_protocol.MAX_DEVICE_LABEL_BYTES]u8 = undefined;
    if (!session.bootstrap(machine_index, localDeviceLabel(&device_buffer))) {
        allocator.free(runtime_id);
        if (thread) |value| allocator.free(value);
        host.removeMachineProfile(profile_id);
        host.notice("Could not start the signed bootstrap. Refresh the account and try again.");
        return false;
    }
    account.link = .{ .profile_id = profile_id, .runtime_id = runtime_id, .thread_id = thread };
    owned_profile = false;
    account.phase = .bootstrapping;
    host.notice("Requesting a signed grant and creating this machine's device credential\u{2026}");
    return true;
}

/// How the runtime lists this computer: the local hostname when valid.
fn localDeviceLabel(buffer: []u8) []const u8 {
    if (comptime builtin.os.tag == .windows) return FALLBACK_DEVICE_LABEL;
    var host_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = std.posix.gethostname(&host_buffer) catch return FALLBACK_DEVICE_LABEL;
    access_protocol.validateDeviceLabel(name) catch return FALLBACK_DEVICE_LABEL;
    if (name.len > buffer.len) return FALLBACK_DEVICE_LABEL;
    @memcpy(buffer[0..name.len], name);
    return buffer[0..name.len];
}

pub fn signIn(host: anytype, state: *State, account_index: usize) bool {
    if (account_index >= state.accounts.items.len) return false;
    const account = &state.accounts.items[account_index];
    if (account.session_unavailable or account.phase == .failed) return retry(host, state, account_index);
    const session = account.session orelse return false;
    if (account.lent or !session.signIn()) return false;
    account.phase = .signing_in;
    account.failure = null;
    return true;
}

/// Refreshes the account's machines (an admin may have assigned one).
pub fn refresh(host: anytype, state: *State, account_index: usize) bool {
    if (account_index >= state.accounts.items.len) return false;
    const account = &state.accounts.items[account_index];
    if (account.session_unavailable or account.phase == .failed) return retry(host, state, account_index);
    const session = account.session orelse return false;
    if (account.lent or !session.loadInventory()) return false;
    account.phase = .loading_inventory;
    return true;
}

/// Replaces a failed or unavailable session with a fresh one.
pub fn retry(host: anytype, state: *State, account_index: usize) bool {
    if (account_index >= state.accounts.items.len) return false;
    const account = &state.accounts.items[account_index];
    if (account.lent or account.link != null) return false;
    if (account.session) |session| session.destroy();
    account.session = null;
    account.session_unavailable = false;
    clearMachines(account, host.allocator);
    ensureSession(host, account);
    return true;
}

/// Ends the account session. Linked machines keep their profiles and
/// device credentials; they reconnect after the next sign-in.
pub fn signOut(host: anytype, state: *State, account_index: usize) bool {
    _ = host;
    if (account_index >= state.accounts.items.len) return false;
    const account = &state.accounts.items[account_index];
    const session = account.session orelse return false;
    if (account.lent) return false;
    session.signOut();
    return true;
}

/// Hands the account's session to the connection wizard so one account has
/// exactly one session. Returns null when no account or session exists.
pub fn lendSession(host: anytype, state: *State, control_plane_url: []const u8) ?*connect_client.Session {
    const index = state.accountIndex(control_plane_url) orelse return null;
    const account = &state.accounts.items[index];
    if (account.lent or account.link != null) return null;
    ensureSession(host, account);
    if (account.session == null) return null;
    account.lent = true;
    return account.session;
}

/// Takes back a session the wizard borrowed or created. Returns false when
/// no account owns `control_plane_url`; the caller then destroys it.
pub fn returnSession(state: *State, control_plane_url: []const u8, session: *connect_client.Session) bool {
    const index = state.accountIndex(control_plane_url) orelse return false;
    const account = &state.accounts.items[index];
    if (account.session) |held| {
        if (held != session) {
            if (account.lent) return false;
            held.destroy();
        }
    }
    account.session = session;
    account.lent = false;
    account.session_unavailable = false;
    return true;
}

/// Adds an account for a control plane the wizard just saved a profile for,
/// so the wizard's session can be returned to it.
pub fn ensureAccount(allocator: std.mem.Allocator, state: *State, control_plane_url: []const u8) ?usize {
    if (state.accountIndex(control_plane_url)) |index| return index;
    if (state.accounts.items.len >= MAX_ACCOUNTS) return null;
    const url = allocator.dupe(u8, normalizedUrl(control_plane_url)) catch return null;
    state.accounts.append(allocator, .{ .control_plane_url = url }) catch {
        allocator.free(url);
        return null;
    };
    return state.accounts.items.len - 1;
}

// ---------------------------------------------------------------------------
// Labels and picker rows
// ---------------------------------------------------------------------------

fn rebuildLabels(host: anytype, state: *State) bool {
    const allocator = host.allocator;
    const next = labelSignature(host, state);
    if (next == state.signature) return false;
    state.signature = next;
    clearLabels(state, allocator);
    state.available.clearRetainingCapacity();
    for (0..host.profileCount()) |index| {
        const ref = host.profileAt(index) orelse continue;
        const account_index = state.accountIndex(ref.control_plane_url) orelse continue;
        const account = &state.accounts.items[account_index];
        const title = account.title();
        const inventory_label = if (matchMachine(account.machines.items, ref.runtime_id, ref.https_url)) |machine|
            account.machines.items[machine].label
        else
            null;
        const name = machineName(inventory_label, ref.label, title, ref.https_url);
        const text = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ title, SEPARATOR, name }) catch continue;
        const id = allocator.dupe(u8, ref.profile_id) catch {
            allocator.free(text);
            continue;
        };
        state.labels.append(allocator, .{ .profile_id = id, .text = text, .account = account_index }) catch {
            allocator.free(text);
            allocator.free(id);
        };
    }
    for (state.accounts.items, 0..) |*account, account_index| {
        if (!account.signedIn()) continue;
        for (account.machines.items, 0..) |*machine, machine_index| {
            if (linkedProfileIndex(host, account, machine) != null) continue;
            var entry: Available = .{ .account = account_index, .machine = machine_index };
            const text = std.fmt.bufPrint(&entry.label_buf, "{s}{s}{s}", .{ account.title(), SEPARATOR, machine.name() }) catch
                entry.label_buf[0..0];
            entry.label_len = text.len;
            state.available.append(allocator, entry) catch break;
        }
    }
    return true;
}

fn labelSignature(host: anytype, state: *const State) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (0..host.profileCount()) |index| {
        const ref = host.profileAt(index) orelse continue;
        hasher.update(ref.profile_id);
        hasher.update(ref.label);
        hasher.update(ref.control_plane_url);
        hasher.update(ref.runtime_id orelse "-");
        hasher.update(ref.https_url orelse "-");
    }
    for (state.accounts.items) |account| {
        hasher.update(account.control_plane_url);
        hasher.update(if (account.signedIn()) "1" else "0");
        for (account.machines.items) |machine| {
            hasher.update(machine.runtime_id);
            hasher.update(machine.https_url);
            hasher.update(machine.label orelse "-");
        }
    }
    return hasher.final() | 1;
}

fn clearLabels(state: *State, allocator: std.mem.Allocator) void {
    for (state.labels.items) |entry| {
        allocator.free(entry.profile_id);
        allocator.free(entry.text);
    }
    state.labels.clearRetainingCapacity();
}

fn clearMachines(account: *Account, allocator: std.mem.Allocator) void {
    for (account.machines.items) |*machine| machine.deinit(allocator);
    account.machines.clearRetainingCapacity();
    account.machines_truncated = 0;
}

fn machinesEqual(previous: []const Machine, current: []const connect_client.RuntimeRow) bool {
    if (previous.len != current.len) return false;
    for (previous, current) |old, fresh| {
        if (!optionalEql(old.selection_key, fresh.selection_key) or
            !optionalEql(old.label, fresh.label) or
            !std.mem.eql(u8, old.link_id, fresh.link_id) or
            !std.mem.eql(u8, old.runtime_id, fresh.runtime_id) or
            !std.mem.eql(u8, old.instance_id, fresh.instance_id) or
            !std.mem.eql(u8, old.https_url, fresh.https_url) or
            !std.mem.eql(u8, old.wss_url, fresh.wss_url) or
            !std.mem.eql(u8, old.spki_sha256, fresh.spki_sha256)) return false;
    }
    return true;
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "accounts group by control plane and name machines without a network" {
    try std.testing.expect(sameControlPlane("https://cloud.verdeai.dev", "HTTPS://Cloud.VerdeAI.dev/"));
    try std.testing.expect(!sameControlPlane("https://cloud.verdeai.dev", "https://connect.example"));
    try std.testing.expectEqualStrings("Verde Cloud", accountTitle("https://cloud.verdeai.dev/"));
    try std.testing.expectEqualStrings("connect.example:8443", accountTitle("https://connect.example:8443"));
    try std.testing.expectEqualStrings("w-pilot-02", hostName("https://w-pilot-02.bhs.cloud.verdeai.dev"));
    // Inventory label wins; an account-named profile label is not a machine name.
    try std.testing.expectEqualStrings("pilot-02", machineName("pilot-02", "Verde Cloud", "Verde Cloud", "https://w-pilot-02.example"));
    try std.testing.expectEqualStrings("w-pilot-02", machineName(null, "Verde Cloud", "Verde Cloud", "https://w-pilot-02.example"));
    try std.testing.expectEqualStrings("pilot-03", machineName(null, "pilot-03", "Verde Cloud", "https://w-pilot-03.example"));
    try std.testing.expectEqualStrings(FALLBACK_MACHINE_NAME, machineName(null, null, "Verde Cloud", null));
}

/// In-memory Connect backend: a signed-in account whose inventory and
/// bootstrap results the test scripts. No worker, socket or keyring.
const FakeBackend = struct {
    allocator: std.mem.Allocator,
    phase: connect_client.Phase = .inventory_loaded,
    failure: ?connect_client.Failure = null,
    rows: []const connect_client.RuntimeRow = &.{},
    result: ?connect_client.BootstrapResult = null,
    bootstrapped: ?usize = null,
    refuse_next: bool = false,
    signed_out: bool = false,
    destroyed: *bool,

    fn backend(self: *FakeBackend) connect_client.SessionBackend {
        return .{ .context = self, .poll = pollFn, .sign_in = signInFn, .load_inventory = inventoryFn, .bootstrap = bootstrapFn, .take_bootstrap_result = takeFn, .sign_out = signOutFn, .destroy = destroyFn };
    }
    fn pollFn(raw: *anyopaque) connect_client.Snapshot {
        const self: *FakeBackend = @ptrCast(@alignCast(raw));
        return .{ .phase = self.phase, .failure = self.failure, .issuer = VERDE_CLOUD_URL, .device_flow_advertised = false, .login_url_open = false, .runtimes = self.rows, .runtimes_truncated = 0, .identity = "org-fixture" };
    }
    fn signInFn(raw: *anyopaque) bool {
        const self: *FakeBackend = @ptrCast(@alignCast(raw));
        self.phase = .inventory_loaded;
        return true;
    }
    fn inventoryFn(raw: *anyopaque) bool {
        const self: *FakeBackend = @ptrCast(@alignCast(raw));
        self.phase = .inventory_loaded;
        return true;
    }
    fn bootstrapFn(raw: *anyopaque, index: usize, label: []const u8) bool {
        const self: *FakeBackend = @ptrCast(@alignCast(raw));
        std.debug.assert(label.len > 0);
        if (index >= self.rows.len) return false;
        self.bootstrapped = index;
        self.phase = .bootstrapping;
        return true;
    }
    fn takeFn(raw: *anyopaque) ?connect_client.BootstrapResult {
        const self: *FakeBackend = @ptrCast(@alignCast(raw));
        const result = self.result orelse return null;
        self.result = null;
        self.phase = .inventory_loaded;
        return result;
    }
    fn signOutFn(raw: *anyopaque) void {
        const self: *FakeBackend = @ptrCast(@alignCast(raw));
        self.signed_out = true;
        self.phase = .discovered;
    }
    fn destroyFn(raw: *anyopaque) void {
        const self: *FakeBackend = @ptrCast(@alignCast(raw));
        self.destroyed.* = true;
    }

    /// Completes the pending bootstrap as an integration backend would:
    /// device plus the verified selection for row `index`.
    fn deliver(self: *FakeBackend, index: usize) !void {
        const a = self.allocator;
        const row = self.rows[index];
        self.result = .{
            .allocator = a,
            .runtime_id = try a.dupe(u8, row.runtime_id),
            .instance_id = try a.dupe(u8, row.instance_id),
            .device_id = try a.dupe(u8, "d" ** 32),
            .device_credential = try a.dupe(u8, "c" ** 64),
            .selection = .{
                .link_id = try a.dupe(u8, "lnk_" ++ "9" ** 32),
                .https_url = try a.dupe(u8, row.https_url),
                .wss_url = try a.dupe(u8, row.wss_url),
                .spki_sha256 = try a.dupe(u8, row.spki_sha256),
            },
        };
        self.phase = .bootstrap_ready;
    }
};

const FakeProfile = struct {
    id: []u8,
    label: []u8,
    url: []u8,
    runtime_id: ?[]u8 = null,
    https_url: ?[]u8 = null,
    device_committed: bool = false,
};

/// Host stand-in: an in-memory profile list. Records what production would
/// persist so tests can assert on per-machine profiles and credentials.
const FakeHost = struct {
    allocator: std.mem.Allocator,
    profiles: std.ArrayList(FakeProfile) = .empty,
    backend: *FakeBackend,
    sessions_created: usize = 0,
    linked: ?[]u8 = null,
    linked_thread: ?[]u8 = null,
    last_notice: []const u8 = "",
    next_id: u8 = 'a',

    fn deinit(self: *FakeHost) void {
        for (self.profiles.items) |*item| freeProfile(self.allocator, item);
        self.profiles.deinit(self.allocator);
        if (self.linked) |value| self.allocator.free(value);
        if (self.linked_thread) |value| self.allocator.free(value);
    }
    fn freeProfile(a: std.mem.Allocator, item: *FakeProfile) void {
        a.free(item.id);
        a.free(item.label);
        a.free(item.url);
        if (item.runtime_id) |value| a.free(value);
        if (item.https_url) |value| a.free(value);
    }
    fn add(self: *FakeHost, label: []const u8, url: []const u8, runtime_id: ?[]const u8, https_url: ?[]const u8) ![]u8 {
        const a = self.allocator;
        const id = try std.fmt.allocPrint(a, "profile-{c}", .{self.next_id});
        self.next_id += 1;
        try self.profiles.append(a, .{
            .id = id,
            .label = try a.dupe(u8, label),
            .url = try a.dupe(u8, url),
            .runtime_id = if (runtime_id) |value| try a.dupe(u8, value) else null,
            .https_url = if (https_url) |value| try a.dupe(u8, value) else null,
        });
        return a.dupe(u8, id);
    }
    fn find(self: *FakeHost, id: []const u8) ?*FakeProfile {
        for (self.profiles.items) |*item| if (std.mem.eql(u8, item.id, id)) return item;
        return null;
    }

    pub fn profileCount(self: *FakeHost) usize {
        return self.profiles.items.len;
    }
    pub fn profileAt(self: *FakeHost, index: usize) ?ProfileRef {
        if (index >= self.profiles.items.len) return null;
        const item = self.profiles.items[index];
        return .{ .profile_id = item.id, .label = item.label, .control_plane_url = item.url, .runtime_id = item.runtime_id, .https_url = item.https_url };
    }
    pub fn createSession(self: *FakeHost, url: []const u8) !*connect_client.Session {
        self.sessions_created += 1;
        return connect_client.Session.startWithBackend(self.allocator, url, self.backend.backend());
    }
    pub fn createMachineProfile(self: *FakeHost, label: []const u8, url: []const u8) ![]u8 {
        return self.add(label, url, null, null);
    }
    pub fn selectMachine(self: *FakeHost, id: []const u8, selection: Selection) !void {
        const item = self.find(id) orelse return error.UnknownRuntimeProfile;
        if (item.runtime_id) |value| self.allocator.free(value);
        if (item.https_url) |value| self.allocator.free(value);
        item.runtime_id = try self.allocator.dupe(u8, selection.runtime_id);
        item.https_url = try self.allocator.dupe(u8, selection.https_url);
    }
    pub fn commitMachine(self: *FakeHost, id: []const u8, commit: Commit) !bool {
        const item = self.find(id) orelse return error.UnknownRuntimeProfile;
        try std.testing.expectEqualStrings(item.runtime_id.?, commit.runtime_id);
        item.device_committed = true;
        return true;
    }
    pub fn removeMachineProfile(self: *FakeHost, id: []const u8) void {
        for (self.profiles.items, 0..) |*item, index| {
            if (!std.mem.eql(u8, item.id, id)) continue;
            freeProfile(self.allocator, item);
            _ = self.profiles.orderedRemove(index);
            return;
        }
    }
    pub fn machineLinked(self: *FakeHost, id: []const u8, thread_id: ?[]const u8) void {
        if (self.linked) |value| self.allocator.free(value);
        self.linked = self.allocator.dupe(u8, id) catch null;
        if (thread_id) |value| {
            if (self.linked_thread) |previous| self.allocator.free(previous);
            self.linked_thread = self.allocator.dupe(u8, value) catch null;
        }
    }
    pub fn notice(self: *FakeHost, text: []const u8) void {
        self.last_notice = text;
    }
};

fn fixtureRow(comptime n: u8, label: []const u8) connect_client.RuntimeRow {
    return .{
        .selection_key = @constCast("ws-" ++ [_]u8{n}),
        .link_id = @constCast(""),
        .runtime_id = @constCast(&([_]u8{n} ** 32)),
        .instance_id = @constCast("e" ** 32),
        .https_url = @constCast("https://w-pilot-0" ++ [_]u8{n} ++ ".example"),
        .wss_url = @constCast("wss://w-pilot-0" ++ [_]u8{n} ++ ".example/ws"),
        .spki_sha256 = @constCast("A" ** 43),
        .label = @constCast(label),
    };
}

test "an existing Connect profile becomes one account; its other machines link without a second account" {
    const a = std.testing.allocator;
    var destroyed = false;
    const rows = [_]connect_client.RuntimeRow{ fixtureRow('2', "pilot-02"), fixtureRow('3', "pilot-03") };
    var backend: FakeBackend = .{ .allocator = a, .rows = &rows, .destroyed = &destroyed };
    var host: FakeHost = .{ .allocator = a, .backend = &backend };
    defer host.deinit();
    // Migration: today's single profile bound to pilot-02, labeled for the account.
    const existing = try host.add("Verde Cloud", "https://cloud.verdeai.dev", &([_]u8{'2'} ** 32), "https://w-pilot-02.example");
    defer a.free(existing);
    a.free(try host.add("Home lab", "https://connect.example", null, null));

    var state: State = .{};
    defer state.deinit(a);
    try std.testing.expect(poll(&host, &state));
    try std.testing.expectEqual(@as(usize, 2), state.accounts.items.len);
    try std.testing.expectEqual(@as(usize, 2), host.sessions_created);
    const cloud = state.accountIndex("https://cloud.verdeai.dev/").?;
    try std.testing.expect(state.accounts.items[cloud].signedIn());
    try std.testing.expectEqualStrings("org-fixture", state.accounts.items[cloud].identity.?);
    try std.testing.expectEqualStrings("Verde Cloud \u{00B7} pilot-02", state.displayLabel(existing).?);
    try std.testing.expectEqualStrings("pilot-02", state.machineLabel(existing).?);
    // pilot-03 (both accounts share the fake inventory, so the self-hosted
    // account offers its two machines too) is available, not a new account.
    var cloud_available: usize = 0;
    for (state.available.items) |entry| {
        if (entry.account != cloud) continue;
        cloud_available += 1;
        try std.testing.expectEqualStrings("Verde Cloud \u{00B7} pilot-03", entry.label());
        try std.testing.expectEqual(@as(usize, 1), entry.machine);
    }
    try std.testing.expectEqual(@as(usize, 1), cloud_available);

    // Linking pilot-03 creates its own profile and device, under the same account.
    try std.testing.expect(linkMachine(&host, &state, cloud, 1, "thread-7"));
    try std.testing.expect(!linkMachine(&host, &state, cloud, 1, null));
    try std.testing.expectEqual(@as(?usize, 1), backend.bootstrapped);
    try std.testing.expectEqual(@as(usize, 3), host.profiles.items.len);
    _ = poll(&host, &state);
    try std.testing.expect(state.accounts.items[cloud].link != null);
    try backend.deliver(1);
    try std.testing.expect(poll(&host, &state));
    try std.testing.expect(state.accounts.items[cloud].link == null);
    const linked = host.find(host.linked.?).?;
    try std.testing.expect(linked.device_committed);
    try std.testing.expectEqualStrings("pilot-03", linked.label);
    try std.testing.expectEqualStrings("thread-7", host.linked_thread.?);
    try std.testing.expectEqual(@as(usize, 2), state.accounts.items.len);
    try std.testing.expectEqual(@as(usize, 2), state.accounts.items[cloud].profile_count);
    try std.testing.expectEqualStrings("Verde Cloud \u{00B7} pilot-03", state.displayLabel(linked.id).?);
    for (state.available.items) |entry| try std.testing.expect(entry.account != cloud);
    // The original profile is untouched.
    try std.testing.expectEqualStrings("https://w-pilot-02.example", host.find(existing).?.https_url.?);
}

test "a refused bootstrap removes the profile it created and the wizard can borrow the account session" {
    const a = std.testing.allocator;
    var destroyed = false;
    const rows = [_]connect_client.RuntimeRow{ fixtureRow('2', "pilot-02"), fixtureRow('3', "pilot-03") };
    var backend: FakeBackend = .{ .allocator = a, .rows = &rows, .destroyed = &destroyed };
    var host: FakeHost = .{ .allocator = a, .backend = &backend };
    defer host.deinit();
    const existing = try host.add("Verde Cloud", "https://cloud.verdeai.dev", &([_]u8{'2'} ** 32), "https://w-pilot-02.example");
    defer a.free(existing);
    var state: State = .{};
    defer state.deinit(a);
    _ = poll(&host, &state);
    try std.testing.expect(linkMachine(&host, &state, 0, 1, null));
    try std.testing.expectEqual(@as(usize, 2), host.profiles.items.len);
    backend.phase = .inventory_loaded;
    backend.failure = .bootstrap_rejected;
    try std.testing.expect(poll(&host, &state));
    try std.testing.expectEqual(@as(usize, 1), host.profiles.items.len);
    try std.testing.expectEqualStrings(connect_client.Failure.bootstrap_rejected.message(), host.last_notice);
    backend.failure = null;

    // One session per account: the wizard borrows it and gives it back.
    const borrowed = lendSession(&host, &state, "https://cloud.verdeai.dev").?;
    try std.testing.expect(lendSession(&host, &state, "https://cloud.verdeai.dev") == null);
    try std.testing.expect(!linkMachine(&host, &state, 0, 1, null));
    _ = poll(&host, &state);
    try std.testing.expectEqual(@as(usize, 1), host.sessions_created);
    try std.testing.expect(returnSession(&state, "https://cloud.verdeai.dev/", borrowed));
    try std.testing.expect(!state.accounts.items[0].lent);
    // Sign-out keeps profiles; removing the last profile drops the account.
    try std.testing.expect(signOut(&host, &state, 0));
    try std.testing.expect(backend.signed_out);
    _ = poll(&host, &state);
    try std.testing.expect(!state.accounts.items[0].signedIn());
    try std.testing.expectEqual(@as(usize, 0), state.available.items.len);
    host.removeMachineProfile(existing);
    _ = poll(&host, &state);
    try std.testing.expectEqual(@as(usize, 0), state.accounts.items.len);
    try std.testing.expect(destroyed);
}

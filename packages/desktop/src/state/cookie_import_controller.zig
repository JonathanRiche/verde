//! GUI-side controller for the "Import cookies…" flow. Loads source browsers
//! and their per-domain cookie counts from the daemon (off the UI thread),
//! lets the user pick domains, then exports the selected cookies and injects
//! them into Verde's browser store via the browser runtime controller.
//!
//! Security: this flow hands real logins to agents that drive the Verde
//! browser, so import is per-site and gated behind an explicit warning. Cookie
//! values are never logged and never persisted by this controller. It is not
//! reachable from MCP tools — only the toolbar overflow menu and the command
//! palette open it.

const std = @import("std");

const loop_wakeup = @import("loop_wakeup");
const daemon_client = @import("../daemon/client.zig");
const headless = @import("headless");
const store_protocol = headless.store_protocol;

const Mutex = std.atomic.Mutex;
const page = std.heap.page_allocator;

pub const AGENT_WARNING: []const u8 =
    "Agents driving the Verde browser will be signed in on the sites you import.";

pub const Status = enum { idle, pending, completed };

pub const Source = struct {
    id: []const u8,
    label: []const u8,
    family: []const u8,
    browser_id: []const u8,

    fn deinit(self: Source) void {
        page.free(self.id);
        page.free(self.label);
        page.free(self.family);
        page.free(self.browser_id);
    }
};

pub const Domain = struct {
    domain: []const u8,
    count: usize,
    selected: bool = false,

    fn deinit(self: Domain) void {
        page.free(self.domain);
    }
};

const Phase = enum { sources, domains, export_cookies };

const WorkerRequest = struct {
    phase: Phase,
    pref_path: []u8,
    source_id: ?[]u8 = null,
    domains_json: ?[]u8 = null,

    fn deinit(self: *WorkerRequest) void {
        page.free(self.pref_path);
        if (self.source_id) |value| page.free(value);
        if (self.domains_json) |value| page.free(value);
        page.destroy(self);
    }
};

const WorkerResult = struct {
    phase: Phase,
    failed: bool = false,
    message: ?[]u8 = null,
    sources: ?[]Source = null,
    domains: ?[]Domain = null,
    total_cookies: usize = 0,
    /// For export: the JSON array of cookies to inject (owned, page alloc).
    cookies_json: ?[]u8 = null,
};

pub const State = struct {
    mutex: Mutex = .unlocked,
    open: bool = false,
    status: Status = .idle,
    worker: ?std.Thread = null,
    request: ?*WorkerRequest = null,
    result: ?WorkerResult = null,

    sources: std.ArrayList(Source) = .empty,
    domains: std.ArrayList(Domain) = .empty,
    selected_source_index: ?usize = null,
    hover_index: ?usize = null,
    source_hover_index: ?usize = null,
    domain_scroll: f32 = 0,
    total_cookies: usize = 0,

    /// Fixed notice buffer so the UI can show status without allocation churn.
    notice_buf: [160]u8 = undefined,
    notice_len: usize = 0,

    search_storage: [129]u8 = [_]u8{0} ** 129,
    search_cursor: usize = 0,

    pub fn deinit(self: *State) void {
        if (self.worker) |w| {
            w.join();
            self.worker = null;
        }
        self.clearSources();
        self.clearDomains();
        self.sources.deinit(page);
        self.domains.deinit(page);
        if (self.result) |*res| freeWorkerResult(res);
    }

    fn clearSources(self: *State) void {
        for (self.sources.items) |source| source.deinit();
        self.sources.clearRetainingCapacity();
    }

    fn clearDomains(self: *State) void {
        for (self.domains.items) |domain| domain.deinit();
        self.domains.clearRetainingCapacity();
    }

    pub fn notice(self: *const State) []const u8 {
        return self.notice_buf[0..self.notice_len];
    }

    fn setNotice(self: *State, text: []const u8) void {
        const len = @min(text.len, self.notice_buf.len);
        @memcpy(self.notice_buf[0..len], text[0..len]);
        self.notice_len = len;
    }

    pub fn searchQuery(self: *const State) []const u8 {
        return std.mem.sliceTo(self.search_storage[0..], 0);
    }

    pub fn searchBuffer(self: *State) [:0]u8 {
        return self.search_storage[0 .. self.search_storage.len - 1 :0];
    }
};

fn freeWorkerResult(result: *WorkerResult) void {
    if (result.message) |m| page.free(m);
    if (result.sources) |list| {
        for (list) |source| source.deinit();
        page.free(list);
    }
    if (result.domains) |list| {
        for (list) |domain| domain.deinit();
        page.free(list);
    }
    if (result.cookies_json) |json| {
        std.crypto.secureZero(u8, json);
        page.free(json);
    }
    result.* = undefined;
}

// ------------------------------------------------------------------
// Worker
// ------------------------------------------------------------------

fn worker(state: *State, request: *WorkerRequest) void {
    var transport: daemon_client.HeadlessTransport = .{ .allocator = page, .pref_path = request.pref_path };
    var client = daemon_client.headlessClient(page, &transport);

    var result: WorkerResult = .{ .phase = request.phase };
    switch (request.phase) {
        .sources => runSources(&client, &result),
        .domains => runDomains(&client, request, &result),
        .export_cookies => runExport(&client, request, &result),
    }

    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
    state.result = result;
    state.status = .completed;
    state.mutex.unlock();
    loop_wakeup.notify();
}

fn callError(result: *WorkerResult, message: []const u8) void {
    result.failed = true;
    result.message = page.dupe(u8, message) catch null;
}

fn runSources(client: *headless.Client, result: *WorkerResult) void {
    var parsed = client.call(store_protocol.METHOD_BROWSER_COOKIE_SOURCES_LIST, .{}) catch {
        callError(result, "Could not reach the daemon to list browsers.");
        return;
    };
    defer parsed.deinit();
    if (parsed.response.err) |err| {
        callError(result, err.message);
        return;
    }
    const value = parsed.response.result orelse {
        callError(result, "The daemon returned no browser list.");
        return;
    };
    const arr = jsonField(value, "sources") orelse {
        result.sources = page.alloc(Source, 0) catch null;
        return;
    };
    if (arr != .array) return;
    var list = page.alloc(Source, arr.array.items.len) catch {
        callError(result, "Out of memory listing browsers.");
        return;
    };
    var n: usize = 0;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const id = dupField(item, "id") orelse continue;
        const label = dupField(item, "label") orelse "";
        list[n] = .{
            .id = id,
            .label = page.dupe(u8, label) catch id,
            .family = page.dupe(u8, jsonStr(item, "family") orelse "") catch &.{},
            .browser_id = page.dupe(u8, jsonStr(item, "browser_id") orelse "") catch &.{},
        };
        n += 1;
    }
    result.sources = list[0..n];
}

fn runDomains(client: *headless.Client, request: *WorkerRequest, result: *WorkerResult) void {
    const source_id = request.source_id orelse return;
    var parsed = client.call(store_protocol.METHOD_BROWSER_COOKIE_DOMAINS_LIST, .{
        .source_id = source_id,
    }) catch {
        callError(result, "Could not read cookies from the selected browser.");
        return;
    };
    defer parsed.deinit();
    if (parsed.response.err) |err| {
        callError(result, err.message);
        return;
    }
    const value = parsed.response.result orelse return;
    result.total_cookies = @intCast(jsonInt(value, "total_cookies") orelse 0);
    const arr = jsonField(value, "domains") orelse return;
    if (arr != .array) return;
    var list = page.alloc(Domain, arr.array.items.len) catch {
        callError(result, "Out of memory reading cookies.");
        return;
    };
    var n: usize = 0;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const domain = dupField(item, "domain") orelse continue;
        list[n] = .{ .domain = domain, .count = @intCast(jsonInt(item, "count") orelse 0) };
        n += 1;
    }
    result.domains = list[0..n];
}

fn runExport(client: *headless.Client, request: *WorkerRequest, result: *WorkerResult) void {
    const source_id = request.source_id orelse return;
    const domains_json = request.domains_json orelse "[]";
    var domains_parsed = std.json.parseFromSlice(std.json.Value, page, domains_json, .{}) catch {
        callError(result, "Invalid domain selection.");
        return;
    };
    defer domains_parsed.deinit();
    var parsed = client.call(store_protocol.METHOD_BROWSER_COOKIE_EXPORT, .{
        .source_id = source_id,
        .domains = domains_parsed.value,
    }) catch {
        callError(result, "Could not export cookies from the selected browser.");
        return;
    };
    defer parsed.deinit();
    if (parsed.response.err) |err| {
        callError(result, err.message);
        return;
    }
    const value = parsed.response.result orelse return;
    const arr = jsonField(value, "cookies") orelse return;
    result.cookies_json = std.json.Stringify.valueAlloc(page, arr, .{}) catch {
        callError(result, "Out of memory preparing cookies.");
        return;
    };
}

fn jsonField(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn jsonStr(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = jsonField(value, name) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

fn dupField(value: std.json.Value, name: []const u8) ?[]u8 {
    const s = jsonStr(value, name) orelse return null;
    return page.dupe(u8, s) catch null;
}

fn jsonInt(value: std.json.Value, name: []const u8) ?i64 {
    const field = jsonField(value, name) orelse return null;
    return switch (field) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

// ------------------------------------------------------------------
// AppState-facing API (self is *AppState)
// ------------------------------------------------------------------

/// Opens the import modal and kicks off source discovery.
pub fn beginCookieImport(self: anytype) void {
    const state = &self.cookie_import;
    state.open = true;
    state.selected_source_index = null;
    state.hover_index = null;
    state.search_cursor = 0;
    state.search_storage[0] = 0;
    state.clearDomains();
    state.setNotice("Finding installed browsers…");
    spawnCookiePhase(self, .sources, null, null);
    self.markDirty();
}

/// Closes the modal and clears any transient state (keeps caches minimal).
pub fn cancelCookieImport(self: anytype) void {
    const state = &self.cookie_import;
    state.open = false;
    state.selected_source_index = null;
    state.hover_index = null;
    state.setNotice("");
    if (self.palette_modal_text_focus == .cookie_import_search) self.palette_modal_text_focus = .none;
    self.markDirty();
}

pub fn cookieImportOpen(self: anytype) bool {
    return self.cookie_import.open;
}

/// Selects a source browser/profile and loads its per-domain cookie counts.
pub fn selectCookieImportSource(self: anytype, index: usize) void {
    const state = &self.cookie_import;
    if (index >= state.sources.items.len) return;
    state.selected_source_index = index;
    state.clearDomains();
    state.setNotice("Reading cookies…");
    const source_id = page.dupe(u8, state.sources.items[index].id) catch return;
    spawnCookiePhase(self, .domains, source_id, null);
    self.markDirty();
}

/// Toggles a domain's selection in the filtered/full list.
pub fn toggleCookieImportDomain(self: anytype, index: usize) void {
    const state = &self.cookie_import;
    if (index >= state.domains.items.len) return;
    state.domains.items[index].selected = !state.domains.items[index].selected;
    self.markDirty();
}

/// Exports the selected domains' cookies and injects them into the browser.
pub fn submitCookieImport(self: anytype) void {
    const state = &self.cookie_import;
    const source_index = state.selected_source_index orelse {
        state.setNotice("Pick a browser first.");
        self.markDirty();
        return;
    };
    if (source_index >= state.sources.items.len) return;

    // Build the JSON array of selected domains.
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(page);
    buffer.append(page, '[') catch return;
    var count: usize = 0;
    for (state.domains.items) |domain| {
        if (!domain.selected) continue;
        if (count != 0) buffer.append(page, ',') catch return;
        buffer.append(page, '"') catch return;
        // Domains are hostnames (letters, digits, dots, hyphens); no escaping needed.
        for (domain.domain) |ch| {
            if (ch == '"' or ch == '\\') buffer.append(page, '\\') catch return;
            buffer.append(page, ch) catch return;
        }
        buffer.append(page, '"') catch return;
        count += 1;
    }
    buffer.append(page, ']') catch return;
    if (count == 0) {
        state.setNotice("Select at least one site to import.");
        self.markDirty();
        return;
    }

    const source_id = page.dupe(u8, state.sources.items[source_index].id) catch return;
    const domains_json = page.dupe(u8, buffer.items) catch {
        page.free(source_id);
        return;
    };
    state.setNotice("Importing cookies…");
    spawnCookiePhase(self, .export_cookies, source_id, domains_json);
    self.markDirty();
}

fn spawnCookiePhase(self: anytype, phase: Phase, source_id: ?[]u8, domains_json: ?[]u8) void {
    const state = &self.cookie_import;
    pollCookieImport(self);
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
    defer state.mutex.unlock();
    if (state.status == .pending) {
        if (source_id) |value| page.free(value);
        if (domains_json) |value| page.free(value);
        return;
    }
    const request = page.create(WorkerRequest) catch {
        if (source_id) |value| page.free(value);
        if (domains_json) |value| page.free(value);
        return;
    };
    request.* = .{
        .phase = phase,
        .pref_path = page.dupe(u8, self.storage.pref_path) catch {
            page.destroy(request);
            if (source_id) |value| page.free(value);
            if (domains_json) |value| page.free(value);
            return;
        },
        .source_id = source_id,
        .domains_json = domains_json,
    };
    state.request = request;
    state.status = .pending;
    state.worker = std.Thread.spawn(.{}, worker, .{ state, request }) catch {
        state.request = null;
        state.status = .idle;
        request.deinit();
        return;
    };
}

/// Drains a completed worker on the UI thread. Call from the main poll loop.
pub fn pollCookieImport(self: anytype) void {
    const state = &self.cookie_import;
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
    if (state.status != .completed) {
        state.mutex.unlock();
        return;
    }
    const w = state.worker.?;
    const request = state.request.?;
    var result = state.result.?;
    state.worker = null;
    state.request = null;
    state.result = null;
    state.status = .idle;
    state.mutex.unlock();
    w.join();
    request.deinit();

    if (result.failed) {
        state.setNotice(result.message orelse "Import failed.");
        freeWorkerResult(&result);
        self.markDirty();
        return;
    }

    switch (result.phase) {
        .sources => {
            state.clearSources();
            if (result.sources) |list| {
                state.sources.appendSlice(page, list) catch {};
                page.free(list); // slice container freed; elements now owned by list items
                result.sources = null;
            }
            if (state.sources.items.len == 0) {
                state.setNotice("No supported browsers with cookies were found.");
            } else {
                state.setNotice(AGENT_WARNING);
            }
        },
        .domains => {
            state.clearDomains();
            if (result.domains) |list| {
                state.domains.appendSlice(page, list) catch {};
                page.free(list);
                result.domains = null;
            }
            state.total_cookies = result.total_cookies;
            state.setNotice(AGENT_WARNING);
        },
        .export_cookies => {
            if (result.cookies_json) |json| {
                self.browser_controller.runtime.controller.importCookies(json) catch {
                    state.setNotice("Could not inject cookies into the browser.");
                };
            }
            freeWorkerResult(&result);
            self.markDirty();
            return;
        },
    }
    freeWorkerResult(&result);
    self.markDirty();
}

/// Called when the browser reports the injection completed.
pub fn noteCookieImportCompleted(self: anytype, count: u32) void {
    const state = &self.cookie_import;
    var buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "Imported {d} cookies into the Verde browser.", .{count}) catch "Cookies imported.";
    state.setNotice(text);
    state.open = false;
    if (self.palette_modal_text_focus == .cookie_import_search) self.palette_modal_text_focus = .none;
    self.setSidebarNotice(text);
    self.markDirty();
}

/// Domains matching the current search filter (indices into the full list).
pub fn cookieImportFilteredIndices(self: anytype, out: *std.ArrayList(usize)) void {
    const state = &self.cookie_import;
    const query = state.searchQuery();
    for (state.domains.items, 0..) |domain, i| {
        if (query.len == 0 or std.mem.indexOf(u8, domain.domain, query) != null) {
            out.append(page, i) catch return;
        }
    }
}

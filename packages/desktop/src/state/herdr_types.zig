//! Herdr workspace-link ownership and persisted pane-link metadata.

const std = @import("std");
const db_types = @import("../db/types.zig");
const platform_runtime = @import("platform_runtime");
const workspace_layout = @import("workspace_layout.zig");

const PersistedHerdrWorkspaceLink = db_types.PersistedHerdrWorkspaceLink;
const WorkspacePaneId = workspace_layout.WorkspacePaneId;

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

pub const HerdrPanePresentation = enum(u8) {
    gui_chat,
    tui_agent,
    terminal,
    browser_link,
    unknown,
};

pub const HerdrPaneProvider = enum(u8) {
    codex,
    claude,
    opencode,
    cursor,
    terminal,
    browser,
    unknown,
};

pub const ProviderExecutionTarget = union(enum) {
    local: []const u8,
    remote_ssh: struct {
        host: []const u8,
        cwd: []const u8,
    },

    pub fn cwd(self: ProviderExecutionTarget) []const u8 {
        return switch (self) {
            .local => |path| path,
            .remote_ssh => |remote| remote.cwd,
        };
    }

    pub fn remoteHost(self: ProviderExecutionTarget) ?[]const u8 {
        return switch (self) {
            .local => null,
            .remote_ssh => |remote| remote.host,
        };
    }
};

pub const HerdrPaneLink = struct {
    verde_pane_id: WorkspacePaneId = 0,
    herdr_tab_id: ?[]u8 = null,
    herdr_pane_id: ?[]u8 = null,
    provider: HerdrPaneProvider = .unknown,
    presentation: HerdrPanePresentation = .unknown,
    provider_thread_id: ?[]u8 = null,
    provider_session_ref: ?[]u8 = null,
    cwd: ?[]u8 = null,
    title: ?[]u8 = null,
    updated_at_ms: i64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        verde_pane_id: WorkspacePaneId,
        herdr_tab_id: ?[]const u8,
        herdr_pane_id: ?[]const u8,
        provider: HerdrPaneProvider,
        presentation: HerdrPanePresentation,
        provider_thread_id: ?[]const u8,
        provider_session_ref: ?[]const u8,
        cwd: ?[]const u8,
        title: ?[]const u8,
    ) !HerdrPaneLink {
        return .{
            .verde_pane_id = verde_pane_id,
            .herdr_tab_id = if (herdr_tab_id) |value| try allocator.dupe(u8, value) else null,
            .herdr_pane_id = if (herdr_pane_id) |value| try allocator.dupe(u8, value) else null,
            .provider = provider,
            .presentation = presentation,
            .provider_thread_id = if (provider_thread_id) |value| try allocator.dupe(u8, value) else null,
            .provider_session_ref = if (provider_session_ref) |value| try allocator.dupe(u8, value) else null,
            .cwd = if (cwd) |value| try allocator.dupe(u8, value) else null,
            .title = if (title) |value| try allocator.dupe(u8, value) else null,
            .updated_at_ms = unixTimestampMs(),
        };
    }

    pub fn deinit(self: *HerdrPaneLink, allocator: std.mem.Allocator) void {
        if (self.herdr_tab_id) |value| allocator.free(value);
        if (self.herdr_pane_id) |value| allocator.free(value);
        if (self.provider_thread_id) |value| allocator.free(value);
        if (self.provider_session_ref) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.title) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const HerdrWorkspaceLink = struct {
    remote_alias: []u8,
    session_name: []u8,
    workspace_id: []u8,
    local_dir: []u8,
    remote_cwd: ?[]u8 = null,
    last_pane_id: ?[]u8 = null,
    attach_dock_id: ?u32 = null,
    attach_pane_id: ?WorkspacePaneId = null,
    pane_links: std.ArrayList(HerdrPaneLink) = .empty,
    updated_at_ms: i64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        remote_alias: []const u8,
        session_name: []const u8,
        workspace_id: []const u8,
        local_dir: []const u8,
        remote_cwd: ?[]const u8,
        last_pane_id: ?[]const u8,
        attach_dock_id: ?u32,
        attach_pane_id: ?WorkspacePaneId,
    ) !HerdrWorkspaceLink {
        const remote_copy = try allocator.dupe(u8, remote_alias);
        errdefer allocator.free(remote_copy);
        const session_copy = try allocator.dupe(u8, session_name);
        errdefer allocator.free(session_copy);
        const workspace_copy = try allocator.dupe(u8, workspace_id);
        errdefer allocator.free(workspace_copy);
        const local_dir_copy = try allocator.dupe(u8, local_dir);
        errdefer allocator.free(local_dir_copy);
        var remote_cwd_copy: ?[]u8 = null;
        errdefer if (remote_cwd_copy) |value| allocator.free(value);
        remote_cwd_copy = if (remote_cwd) |value| try allocator.dupe(u8, value) else null;
        var last_pane_copy: ?[]u8 = null;
        errdefer if (last_pane_copy) |value| allocator.free(value);
        last_pane_copy = if (last_pane_id) |value| try allocator.dupe(u8, value) else null;
        return .{
            .remote_alias = remote_copy,
            .session_name = session_copy,
            .workspace_id = workspace_copy,
            .local_dir = local_dir_copy,
            .remote_cwd = remote_cwd_copy,
            .last_pane_id = last_pane_copy,
            .attach_dock_id = attach_dock_id,
            .attach_pane_id = attach_pane_id,
            .pane_links = .empty,
            .updated_at_ms = unixTimestampMs(),
        };
    }

    pub fn initFromPersisted(allocator: std.mem.Allocator, persisted: PersistedHerdrWorkspaceLink) !HerdrWorkspaceLink {
        var link = try init(
            allocator,
            persisted.remote_alias,
            persisted.session_name,
            persisted.workspace_id,
            persisted.local_dir,
            persisted.remote_cwd,
            persisted.last_pane_id,
            persisted.attach_dock_id,
            persisted.attach_pane_id,
        );
        errdefer link.deinit(allocator);
        link.updated_at_ms = persisted.updated_at_ms;
        if (persisted.pane_links_json) |json| try link.applyPaneLinksJson(allocator, json);
        return link;
    }

    pub fn deinit(self: *HerdrWorkspaceLink, allocator: std.mem.Allocator) void {
        allocator.free(self.remote_alias);
        allocator.free(self.session_name);
        allocator.free(self.workspace_id);
        allocator.free(self.local_dir);
        if (self.remote_cwd) |value| allocator.free(value);
        if (self.last_pane_id) |value| allocator.free(value);
        for (self.pane_links.items) |*pane_link| pane_link.deinit(allocator);
        self.pane_links.deinit(allocator);
        self.* = undefined;
    }

    pub fn toPersisted(self: *const HerdrWorkspaceLink, allocator: std.mem.Allocator) !PersistedHerdrWorkspaceLink {
        return .{
            .remote_alias = try allocator.dupe(u8, self.remote_alias),
            .session_name = try allocator.dupe(u8, self.session_name),
            .workspace_id = try allocator.dupe(u8, self.workspace_id),
            .local_dir = try allocator.dupe(u8, self.local_dir),
            .remote_cwd = if (self.remote_cwd) |value| try allocator.dupe(u8, value) else null,
            .last_pane_id = if (self.last_pane_id) |value| try allocator.dupe(u8, value) else null,
            .attach_dock_id = self.attach_dock_id,
            .attach_pane_id = self.attach_pane_id,
            .pane_links_json = try self.paneLinksJsonAlloc(allocator),
            .updated_at_ms = self.updated_at_ms,
        };
    }

    pub fn replacePaneLinks(self: *HerdrWorkspaceLink, allocator: std.mem.Allocator, next_links: *std.ArrayList(HerdrPaneLink)) void {
        for (self.pane_links.items) |*pane_link| pane_link.deinit(allocator);
        self.pane_links.deinit(allocator);
        self.pane_links = next_links.*;
        next_links.* = .empty;
        self.updated_at_ms = unixTimestampMs();
    }

    pub fn paneLinkForVerdePane(self: *const HerdrWorkspaceLink, pane_id: WorkspacePaneId) ?HerdrPaneLink {
        for (self.pane_links.items) |pane_link| {
            if (pane_link.verde_pane_id == pane_id) return pane_link;
        }
        return null;
    }

    pub fn removePaneLinkForVerdePane(self: *HerdrWorkspaceLink, allocator: std.mem.Allocator, pane_id: WorkspacePaneId) bool {
        for (self.pane_links.items, 0..) |*pane_link, index| {
            if (pane_link.verde_pane_id != pane_id) continue;
            var removed = self.pane_links.orderedRemove(index);
            removed.deinit(allocator);
            self.updated_at_ms = unixTimestampMs();
            return true;
        }
        return false;
    }

    pub fn paneLinksJsonAlloc(self: *const HerdrWorkspaceLink, allocator: std.mem.Allocator) !?[]u8 {
        if (self.pane_links.items.len == 0) return null;
        var writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer writer.deinit();
        var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try stringify.beginArray();
        for (self.pane_links.items) |pane_link| {
            try stringify.beginObject();
            try stringify.objectField("verde_pane_id");
            try stringify.write(pane_link.verde_pane_id);
            try stringify.objectField("herdr_tab_id");
            if (pane_link.herdr_tab_id) |value| try stringify.write(value) else try stringify.write(null);
            try stringify.objectField("herdr_pane_id");
            if (pane_link.herdr_pane_id) |value| try stringify.write(value) else try stringify.write(null);
            try stringify.objectField("provider");
            try stringify.write(@tagName(pane_link.provider));
            try stringify.objectField("presentation");
            try stringify.write(@tagName(pane_link.presentation));
            try stringify.objectField("provider_thread_id");
            if (pane_link.provider_thread_id) |value| try stringify.write(value) else try stringify.write(null);
            try stringify.objectField("provider_session_ref");
            if (pane_link.provider_session_ref) |value| try stringify.write(value) else try stringify.write(null);
            try stringify.objectField("cwd");
            if (pane_link.cwd) |value| try stringify.write(value) else try stringify.write(null);
            try stringify.objectField("title");
            if (pane_link.title) |value| try stringify.write(value) else try stringify.write(null);
            try stringify.objectField("updated_at_ms");
            try stringify.write(pane_link.updated_at_ms);
            try stringify.endObject();
        }
        try stringify.endArray();
        return try writer.toOwnedSlice();
    }

    pub fn applyPaneLinksJson(self: *HerdrWorkspaceLink, allocator: std.mem.Allocator, json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |entry| {
            if (entry != .object) continue;
            const pane_id: WorkspacePaneId = @intCast(herdrJsonInt(entry.object.get("verde_pane_id") orelse .null) orelse continue);
            var link = try HerdrPaneLink.init(
                allocator,
                pane_id,
                herdrJsonString(entry.object.get("herdr_tab_id") orelse .null),
                herdrJsonString(entry.object.get("herdr_pane_id") orelse .null),
                herdrPaneProviderFromLabel(herdrJsonString(entry.object.get("provider") orelse .null) orelse "unknown"),
                herdrPanePresentationFromLabel(herdrJsonString(entry.object.get("presentation") orelse .null) orelse "unknown"),
                herdrJsonString(entry.object.get("provider_thread_id") orelse .null),
                herdrJsonString(entry.object.get("provider_session_ref") orelse .null),
                herdrJsonString(entry.object.get("cwd") orelse .null),
                herdrJsonString(entry.object.get("title") orelse .null),
            );
            link.updated_at_ms = herdrJsonInt(entry.object.get("updated_at_ms") orelse .null) orelse link.updated_at_ms;
            errdefer link.deinit(allocator);
            try self.pane_links.append(allocator, link);
        }
    }
};

fn herdrJsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn herdrJsonInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn herdrPaneProviderFromLabel(label: []const u8) HerdrPaneProvider {
    if (std.mem.eql(u8, label, "codex")) return .codex;
    if (std.mem.eql(u8, label, "claude")) return .claude;
    if (std.mem.eql(u8, label, "opencode")) return .opencode;
    if (std.mem.eql(u8, label, "cursor")) return .cursor;
    if (std.mem.eql(u8, label, "terminal")) return .terminal;
    if (std.mem.eql(u8, label, "browser")) return .browser;
    return .unknown;
}

fn herdrPanePresentationFromLabel(label: []const u8) HerdrPanePresentation {
    if (std.mem.eql(u8, label, "gui_chat")) return .gui_chat;
    if (std.mem.eql(u8, label, "tui_agent")) return .tui_agent;
    if (std.mem.eql(u8, label, "terminal")) return .terminal;
    if (std.mem.eql(u8, label, "browser_link")) return .browser_link;
    return .unknown;
}

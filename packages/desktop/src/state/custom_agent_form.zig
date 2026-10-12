//! Add/edit form for user-defined ACP agents (Settings > Providers).
//!
//! The user names the agent, gives the stdio command line that starts its
//! ACP server (for example `gemini --acp`), and optional `KEY=VALUE`
//! environment pairs.
//! Saving writes `chat.custom_acp_agents` in verde.json immediately; the
//! daemon resolves the entry on each turn. Rendering lives in
//! `ui/custom_agent_form.zig`.

const std = @import("std");
const app_config = @import("../app/config.zig");
const custom_agents = app_config.custom_acp_agents;

const log = std.log.scoped(.custom_agent_form);

pub const NAME_CAPACITY: usize = 64;
pub const COMMAND_CAPACITY: usize = 1024;
pub const ENV_CAPACITY: usize = 2048;

pub const Field = enum {
    name,
    command,
    env,

    pub const all = [_]Field{ .name, .command, .env };
};

pub const Form = struct {
    open: bool = false,
    /// Index into `AppConfig.custom_acp_agents` being edited; null adds.
    editing_index: ?usize = null,
    name_storage: [NAME_CAPACITY + 1]u8 = [_]u8{0} ** (NAME_CAPACITY + 1),
    command_storage: [COMMAND_CAPACITY + 1]u8 = [_]u8{0} ** (COMMAND_CAPACITY + 1),
    env_storage: [ENV_CAPACITY + 1]u8 = [_]u8{0} ** (ENV_CAPACITY + 1),
    name_cursor: usize = 0,
    command_cursor: usize = 0,
    env_cursor: usize = 0,
    /// Static validation message shown in the footer; empty when none.
    notice: []const u8 = "",

    pub fn value(self: *const Form, field: Field) []const u8 {
        return switch (field) {
            .name => std.mem.sliceTo(&self.name_storage, 0),
            .command => std.mem.sliceTo(&self.command_storage, 0),
            .env => std.mem.sliceTo(&self.env_storage, 0),
        };
    }

    pub fn buffer(self: *Form, field: Field) [:0]u8 {
        return switch (field) {
            .name => self.name_storage[0..NAME_CAPACITY :0],
            .command => self.command_storage[0..COMMAND_CAPACITY :0],
            .env => self.env_storage[0..ENV_CAPACITY :0],
        };
    }

    pub fn cursor(self: *Form, field: Field) *usize {
        return switch (field) {
            .name => &self.name_cursor,
            .command => &self.command_cursor,
            .env => &self.env_cursor,
        };
    }

    pub fn setValue(self: *Form, field: Field, text: []const u8) void {
        const target = self.buffer(field);
        @memset(target[0..target.len], 0);
        const len = @min(text.len, target.len);
        @memcpy(target[0..len], text[0..len]);
        self.cursor(field).* = len;
    }

    pub fn reset(self: *Form) void {
        self.* = .{};
    }
};

/// Opens an empty form for a new agent.
pub fn openAdd(self: anytype) void {
    const form = &self.custom_agent_form;
    form.reset();
    form.open = true;
    self.palette_modal_text_focus = .custom_agent_name;
    self.modal_text_selection_anchor = null;
    self.markDirty();
}

/// Opens the form prefilled from the agent at `index`.
pub fn openEdit(self: anytype, index: usize) void {
    const agents = self.app_config.custom_acp_agents;
    if (index >= agents.len) return;
    const agent = agents[index];
    const form = &self.custom_agent_form;
    form.reset();
    form.open = true;
    form.editing_index = index;
    form.setValue(.name, agent.name);
    const command_line = custom_agents.joinCommandLineAlloc(self.allocator, agent.command, agent.args) catch null;
    defer if (command_line) |line| self.allocator.free(line);
    form.setValue(.command, command_line orelse agent.command);
    const env_line = custom_agents.joinEnvLineAlloc(self.allocator, agent.env) catch null;
    defer if (env_line) |line| self.allocator.free(line);
    form.setValue(.env, env_line orelse "");
    self.palette_modal_text_focus = .custom_agent_name;
    self.modal_text_selection_anchor = null;
    self.markDirty();
}

pub fn close(self: anytype) void {
    self.custom_agent_form.reset();
    if (focusedField(self.palette_modal_text_focus) != null) self.palette_modal_text_focus = .none;
    self.modal_text_selection_anchor = null;
    self.markDirty();
}

/// Maps a modal text focus to its form field, or null for other modals.
pub fn focusedField(focus: anytype) ?Field {
    return switch (focus) {
        .custom_agent_name => .name,
        .custom_agent_command => .command,
        .custom_agent_env => .env,
        else => null,
    };
}

pub fn focusForField(comptime Focus: type, field: Field) Focus {
    return switch (field) {
        .name => .custom_agent_name,
        .command => .custom_agent_command,
        .env => .custom_agent_env,
    };
}

pub fn cycleField(self: anytype, backwards: bool) void {
    const current = focusedField(self.palette_modal_text_focus) orelse .name;
    const index = std.mem.indexOfScalar(Field, &Field.all, current).?;
    const next = if (backwards)
        (index + Field.all.len - 1) % Field.all.len
    else
        (index + 1) % Field.all.len;
    self.palette_modal_text_focus = focusForField(@TypeOf(self.palette_modal_text_focus), Field.all[next]);
    self.modal_text_selection_anchor = null;
    self.markDirty();
}

/// Validates the form and writes the agent list. Leaves the form open with a
/// notice when the input is invalid.
pub fn submit(self: anytype) void {
    const form = &self.custom_agent_form;
    const result = buildAgent(self.allocator, form, self.app_config.custom_acp_agents) catch |err| {
        form.notice = switch (err) {
            error.MissingName => "Give the agent a name.",
            error.MissingCommand => "Enter the command that starts the agent's ACP server.",
            error.UnterminatedQuote => "The command has an unmatched quote.",
            error.InvalidEnv => "Environment entries must look like KEY=VALUE.",
            else => "Could not save the agent.",
        };
        self.markDirty();
        return;
    };
    var agent = result;
    var committed = false;
    defer if (!committed) agent.deinit(self.allocator);

    const current = self.app_config.custom_acp_agents;
    if (form.editing_index) |index| {
        if (index >= current.len) {
            form.notice = "That agent was removed; close the form and add it again.";
            self.markDirty();
            return;
        }
        // Editing keeps the stable id so existing threads stay bound to it.
        const kept_id = self.allocator.dupe(u8, current[index].id) catch {
            form.notice = "Could not save the agent.";
            self.markDirty();
            return;
        };
        self.allocator.free(agent.id);
        agent.id = kept_id;
        current[index].deinit(self.allocator);
        current[index] = agent;
        committed = true;
    } else {
        if (current.len >= custom_agents.MAX_AGENTS) {
            form.notice = "Too many custom agents; remove one first.";
            self.markDirty();
            return;
        }
        const next = self.allocator.alloc(custom_agents.Agent, current.len + 1) catch {
            form.notice = "Could not save the agent.";
            self.markDirty();
            return;
        };
        @memcpy(next[0..current.len], current);
        next[current.len] = agent;
        self.allocator.free(current);
        self.app_config.custom_acp_agents = next;
        committed = true;
    }
    persist(self);
    close(self);
}

/// Removes the agent at `index` and saves. Threads already bound to it fail
/// their next turn with a "no longer configured" message.
pub fn remove(self: anytype, index: usize) void {
    const current = self.app_config.custom_acp_agents;
    if (index >= current.len) return;
    // Allocate the shorter list first so a failure leaves the config intact.
    const next = self.allocator.alloc(custom_agents.Agent, current.len - 1) catch {
        self.setSidebarNotice("Could not remove the custom agent.");
        self.markDirty();
        return;
    };
    @memcpy(next[0..index], current[0..index]);
    @memcpy(next[index..], current[index + 1 ..]);
    current[index].deinit(self.allocator);
    self.allocator.free(current);
    self.app_config.custom_acp_agents = next;
    if (self.custom_agent_form.open) close(self);
    persist(self);
}

fn persist(self: anytype) void {
    self.syncCustomAcpModelOptions();
    if (!self.settings_controller.persist_to_disk) {
        self.markDirty();
        return;
    }
    app_config.saveAppConfig(self.allocator, &self.app_config) catch |err| {
        log.warn("failed to save custom ACP agents: {s}", .{@errorName(err)});
        self.setSidebarNotice("Could not save custom agents to Verde settings.");
        self.markDirty();
        return;
    };
    self.app_config_file_mtime = app_config.configFileMtime(self.allocator) catch self.app_config_file_mtime;
    self.startProviderReadinessCheck();
    self.markDirty();
}

/// Builds an owned agent from the form. The id is derived from the name and
/// made unique against `existing`.
pub fn buildAgent(allocator: std.mem.Allocator, form: *const Form, existing: []const custom_agents.Agent) !custom_agents.Agent {
    const name = std.mem.trim(u8, form.value(.name), &std.ascii.whitespace);
    if (name.len == 0) return error.MissingName;
    const words = try custom_agents.splitCommandLineAlloc(allocator, form.value(.command));
    defer {
        for (words) |word| allocator.free(word);
        allocator.free(words);
    }
    if (words.len == 0) return error.MissingCommand;
    const env = try custom_agents.parseEnvLineAlloc(allocator, form.value(.env));
    var env_owned = true;
    defer if (env_owned) {
        for (env) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        allocator.free(env);
    };

    const id = try custom_agents.uniqueIdAlloc(allocator, name, existing);
    errdefer allocator.free(id);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const command = try allocator.dupe(u8, words[0]);
    errdefer allocator.free(command);
    const args = try allocator.alloc([]u8, words.len - 1);
    var filled: usize = 0;
    errdefer {
        for (args[0..filled]) |arg| allocator.free(arg);
        allocator.free(args);
    }
    for (words[1..], 0..) |word, index| {
        args[index] = try allocator.dupe(u8, word);
        filled += 1;
    }
    env_owned = false;
    return .{ .id = id, .name = owned_name, .command = command, .args = args, .env = env };
}

test "buildAgent splits the command line and env pairs" {
    const allocator = std.testing.allocator;
    var form: Form = .{};
    form.setValue(.name, "  Gemini CLI ");
    form.setValue(.command, "gemini --experimental-acp --model 'gemini 3'");
    form.setValue(.env, "GEMINI_API_KEY=abc");
    var agent = try buildAgent(allocator, &form, &.{});
    defer agent.deinit(allocator);
    try std.testing.expectEqualStrings("gemini-cli", agent.id);
    try std.testing.expectEqualStrings("Gemini CLI", agent.name);
    try std.testing.expectEqualStrings("gemini", agent.command);
    try std.testing.expectEqual(@as(usize, 3), agent.args.len);
    try std.testing.expectEqualStrings("gemini 3", agent.args[2]);
    try std.testing.expectEqualStrings("GEMINI_API_KEY", agent.env[0].name);

    form.setValue(.command, "   ");
    try std.testing.expectError(error.MissingCommand, buildAgent(allocator, &form, &.{}));
    form.setValue(.command, "x");
    form.setValue(.name, "");
    try std.testing.expectError(error.MissingName, buildAgent(allocator, &form, &.{}));
}

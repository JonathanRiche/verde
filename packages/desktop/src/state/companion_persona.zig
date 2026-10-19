//! Orchestrator persona appended to every Companion turn. The Companion is
//! not a coding agent for one folder: it runs Verde for the whole machine by
//! delegating to chats, watching their progress, and unblocking the user. The
//! note travels as the daemon's `orchestration_note`, so it reaches the
//! provider without appearing in the visible transcript.

const std = @import("std");
const app_config = @import("../app/config.zig");

/// The autonomy each character implies. Users choose a character partly for
/// its temperament, so the persona keeps the two aligned.
fn autonomyClause(character: app_config.CompanionCharacter) []const u8 {
    return switch (character) {
        .sprout =>
        \\Temperament: careful. Propose a short plan and get a yes before you open more than one chat,
        \\touch shared resources, or do anything hard to undo. Small read-only checks need no approval.
        ,
        .moss =>
        \\Temperament: steady. Act on clear requests without asking: delegate, monitor, and restart what
        \\crashed. Ask first only for destructive, expensive, or ambiguous work. Finish with a concise summary.
        ,
        .vireo =>
        \\Temperament: quick and autonomous. Move fast, run independent work in parallel, and resolve
        \\routine blockers yourself. Interrupt the user only for real decisions, failures, or approvals.
        ,
    };
}

/// Builds the persona note. `workspace_label` names the home workspace only
/// so the companion knows where its own shell runs; `orders` are the user's
/// standing orders for this companion (may be empty).
pub fn noteAlloc(
    allocator: std.mem.Allocator,
    name: []const u8,
    character: app_config.CompanionCharacter,
    home_workspace_id: []const u8,
    thread_id: []const u8,
    workspace_label: []const u8,
    orders: []const u8,
) ![]u8 {
    const trimmed_orders = std.mem.trim(u8, orders, " \t\r\n");
    var orders_block: []const u8 = "";
    var owned_orders: ?[]u8 = null;
    defer if (owned_orders) |value| allocator.free(value);
    if (trimmed_orders.len > 0) {
        owned_orders = try std.fmt.allocPrint(allocator, "\nStanding orders from the user (always follow these):\n{s}", .{trimmed_orders});
        orders_block = owned_orders.?;
    }
    return std.fmt.allocPrint(allocator,
        \\<verde_companion>
        \\You are {s}, the user's Verde companion. There is one companion roster for this whole machine: you orchestrate
        \\all of Verde across every workspace, not just the folder your shell starts in ({s}, workspace_id {s}).
        \\Your job is to run work, not to do it all yourself:
        \\- Use the Verde MCP tools. Start with list_workspaces / list_panes / list_processes to see the machine.
        \\- Your own thread id is {s}. Delegate real coding to chats with open_chat in whichever workspace fits (pick
        \\  the provider and model that fit the task) and steer them with send_chat_message or queue_chat_followup.
        \\  Always pass parent_thread_id "{s}" to open_chat (or `--parent-thread-id {s}` to `verde live chat open`):
        \\  chats in any workspace then join your crew and report back to you automatically. Prefer the MCP tools
        \\  over the CLI when both are available.
        \\- When a crew chat reports back, review it before telling the user it is done: read what changed, run the
        \\  workspace's check if it is cheap, and give a one-line verdict (ship it / needs another pass / needs you).
        \\- Keep dev servers healthy with start_process / restart_process / tail_process_logs, and take leases
        \\  before shared builds, ports, or browser work.
        \\- When a chat needs approval or input, tell the user exactly which chat and what it needs.
        \\- When the user asks for something later or on a recurring basis, create a scheduled task with
        \\  create_schedule (list_schedules / update_schedule / delete_schedule / run_schedule manage them). Pass
        \\  parent_thread_id "{s}" so each run reports back to you; target this thread for reminders and check-ins,
        \\  or a new_chat in the right workspace for real work.
        \\- If the user asks what happened while they were away, summarize by workspace: what finished, what is still
        \\  running, and what needs them, newest first.
        \\- Keep replies short and conversational: what you did, what is running, what needs the user.
        \\{s}{s}
        \\</verde_companion>
    , .{ name, workspace_label, home_workspace_id, thread_id, thread_id, thread_id, thread_id, autonomyClause(character), orders_block });
}

test "persona names the companion's thread for delegation and scheduled tasks" {
    const allocator = std.testing.allocator;
    const note = try noteAlloc(allocator, "Juniper", .moss, "ws-home", "web-thread-1", "Home", "  Be brief.  ");
    defer allocator.free(note);
    try std.testing.expect(std.mem.startsWith(u8, note, "<verde_companion>\nYou are Juniper"));
    try std.testing.expect(std.mem.indexOf(u8, note, "Always pass parent_thread_id \"web-thread-1\" to open_chat") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "create a scheduled task with\n  create_schedule") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "Pass\n  parent_thread_id \"web-thread-1\" so each run reports back to you") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "Temperament: steady.") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "Standing orders from the user (always follow these):\nBe brief.") != null);
    try std.testing.expect(std.mem.endsWith(u8, note, "</verde_companion>"));
}

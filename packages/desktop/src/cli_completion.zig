const std = @import("std");

const output = @import("cli_output.zig");
const spec = @import("cli_spec.zig");

pub fn print(allocator: std.mem.Allocator, out: output.Output, shell: []const u8) !bool {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    if (std.mem.eql(u8, shell, "bash")) {
        try writeBash(&writer.writer);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try writeZsh(&writer.writer);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try writeFish(&writer.writer);
    } else {
        return false;
    }

    try out.stdout("{s}", .{writer.written()});
    return true;
}

fn writeWords(w: *std.Io.Writer, words: []const []const u8) !void {
    for (words, 0..) |word, index| {
        if (index > 0) try w.writeByte(' ');
        try w.writeAll(word);
    }
}

fn writeBash(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\# bash completion for verde
        \\_verde_completion() {
        \\  local cur prev root sub third fourth
        \\  COMPREPLY=()
        \\  cur="${COMP_WORDS[COMP_CWORD]}"
        \\  prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\  root="${COMP_WORDS[1]}"
        \\  sub="${COMP_WORDS[2]}"
        \\  third="${COMP_WORDS[3]}"
        \\  fourth="${COMP_WORDS[4]}"
        \\
        \\  local top="
    );
    try writeWords(w, &spec.top_level_commands);
    try w.writeAll("\"\n  local shells=\"");
    try writeWords(w, &spec.shells);
    try w.writeAll("\"\n  local state=\"");
    try writeWords(w, &spec.state_commands);
    try w.writeAll("\"\n  local herdr=\"");
    try writeWords(w, &spec.herdr_commands);
    try w.writeAll("\"\n  local integrations=\"");
    try writeWords(w, &spec.integration_commands);
    try w.writeAll("\"\n  local integration_providers=\"");
    try writeWords(w, &spec.integration_providers);
    try w.writeAll("\"\n  local session=\"");
    try writeWords(w, &spec.session_commands);
    try w.writeAll("\"\n  local live=\"");
    try writeWords(w, &spec.live_commands);
    try w.writeAll("\"\n  local workspace=\"");
    try writeWords(w, &spec.workspace_commands);
    try w.writeAll("\"\n  local pane=\"");
    try writeWords(w, &spec.pane_commands);
    try w.writeAll("\"\n  local chat=\"");
    try writeWords(w, &spec.chat_commands);
    try w.writeAll("\"\n  local draft=\"");
    try writeWords(w, &spec.chat_draft_commands);
    try w.writeAll("\"\n  local browser=\"");
    try writeWords(w, &spec.browser_commands);
    try w.writeAll("\"\n  local palette=\"");
    try writeWords(w, &spec.palette_commands);
    try w.writeAll("\"\n  local terminal=\"");
    try writeWords(w, &spec.terminal_commands);
    try w.writeAll("\"\n  local process=\"");
    try writeWords(w, &spec.process_commands);
    try w.writeAll("\"\n  local agent=\"");
    try writeWords(w, &spec.agent_commands);
    try w.writeAll("\"\n  local stack=\"");
    try writeWords(w, &spec.stack_commands);
    try w.writeAll("\"\n  local all_flags=\"");
    try writeWords(w, &spec.all_flags);
    try w.writeAll("\"\n  local json_flags=\"");
    try writeWords(w, &spec.json_flags);
    try w.writeAll("\"\n  local project_json_flags=\"");
    try writeWords(w, &spec.project_json_flags);
    try w.writeAll("\"\n  local herdr_profiles=\"");
    try writeWords(w, &spec.herdr_profile_commands);
    try w.writeAll("\"\n  local herdr_open_flags=\"");
    try writeWords(w, &spec.herdr_open_flags);
    try w.writeAll("\"\n  local herdr_handoff_flags=\"");
    try writeWords(w, &spec.herdr_handoff_flags);
    try w.writeAll("\"\n  local herdr_unlink_flags=\"");
    try writeWords(w, &spec.herdr_unlink_flags);
    try w.writeAll("\"\n  local herdr_profile_add_flags=\"");
    try writeWords(w, &spec.herdr_profile_add_flags);
    try w.writeAll("\"\n  local herdr_profile_name_flags=\"");
    try writeWords(w, &spec.herdr_profile_name_flags);
    try w.writeAll("\"\n  local pane_flags=\"");
    try writeWords(w, &spec.pane_flags);
    try w.writeAll("\"\n  local pane_split_flags=\"");
    try writeWords(w, &spec.pane_split_flags);
    try w.writeAll("\"\n  local pane_resize_flags=\"");
    try writeWords(w, &spec.pane_resize_flags);
    try w.writeAll("\"\n  local pane_move_flags=\"");
    try writeWords(w, &spec.pane_move_flags);
    try w.writeAll("\"\n  local workspace_select_flags=\"");
    try writeWords(w, &spec.workspace_select_flags);
    try w.writeAll("\"\n  local workspace_create_flags=\"");
    try writeWords(w, &spec.workspace_create_flags);
    try w.writeAll("\"\n  local workspace_rename_flags=\"");
    try writeWords(w, &spec.workspace_rename_flags);
    try w.writeAll("\"\n  local workspace_close_flags=\"");
    try writeWords(w, &spec.workspace_close_flags);
    try w.writeAll("\"\n  local workspace_reopen_flags=\"");
    try writeWords(w, &spec.workspace_reopen_flags);
    try w.writeAll("\"\n  local workspace_archive_flags=\"");
    try writeWords(w, &spec.workspace_archive_flags);
    try w.writeAll("\"\n  local chat_draft_flags=\"");
    try writeWords(w, &spec.chat_draft_flags);
    try w.writeAll("\"\n  local chat_send_flags=\"");
    try writeWords(w, &spec.chat_send_flags);
    try w.writeAll("\"\n  local chat_approve_flags=\"");
    try writeWords(w, &spec.chat_approve_flags);
    try w.writeAll("\"\n  local browser_open_flags=\"");
    try writeWords(w, &spec.browser_open_flags);
    try w.writeAll("\"\n  local browser_navigate_flags=\"");
    try writeWords(w, &spec.browser_navigate_flags);
    try w.writeAll("\"\n  local browser_eval_flags=\"");
    try writeWords(w, &spec.browser_eval_flags);
    try w.writeAll("\"\n  local browser_post_json_flags=\"");
    try writeWords(w, &spec.browser_post_json_flags);
    try w.writeAll("\"\n  local browser_toolbar_hit_flags=\"");
    try writeWords(w, &spec.browser_toolbar_hit_flags);
    try w.writeAll("\"\n  local browser_paste_text_flags=\"");
    try writeWords(w, &spec.browser_paste_text_flags);
    try w.writeAll("\"\n  local browser_inspector_mode_flags=\"");
    try writeWords(w, &spec.browser_inspector_mode_flags);
    try w.writeAll("\"\n  local palette_run_flags=\"");
    try writeWords(w, &spec.palette_run_flags);
    try w.writeAll("\"\n  local terminal_write_flags=\"");
    try writeWords(w, &spec.terminal_write_flags);
    try w.writeAll("\"\n  local terminal_tail_flags=\"");
    try writeWords(w, &spec.terminal_tail_flags);
    try w.writeAll("\"\n  local process_flags=\"");
    try writeWords(w, &spec.process_flags);
    try w.writeAll("\"\n  local agent_flags=\"");
    try writeWords(w, &spec.agent_flags);
    try w.writeAll("\"\n  local kind_values=\"");
    try writeWords(w, &spec.kind_values);
    try w.writeAll("\"\n  local axis_values=\"");
    try writeWords(w, &spec.axis_values);
    try w.writeAll("\"\n  local direction_values=\"");
    try writeWords(w, &spec.direction_values);
    try w.writeAll("\"\n  local decision_values=\"");
    try writeWords(w, &spec.decision_values);
    try w.writeAll("\"\n  local provider_values=\"");
    try writeWords(w, &spec.provider_values);
    try w.writeAll("\"\n  local inspector_mode_values=\"");
    try writeWords(w, &spec.inspector_mode_values);
    try w.writeAll(
        \\"
        \\
        \\  case "$prev" in
        \\    --kind) COMPREPLY=( $(compgen -W "$kind_values" -- "$cur") ); return 0 ;;
        \\    --axis) COMPREPLY=( $(compgen -W "$axis_values" -- "$cur") ); return 0 ;;
        \\    --direction) COMPREPLY=( $(compgen -W "$direction_values" -- "$cur") ); return 0 ;;
        \\    --decision) COMPREPLY=( $(compgen -W "$decision_values" -- "$cur") ); return 0 ;;
        \\    --provider) COMPREPLY=( $(compgen -W "$provider_values" -- "$cur") ); return 0 ;;
        \\    --mode) COMPREPLY=( $(compgen -W "$inspector_mode_values" -- "$cur") ); return 0 ;;
        \\    --workspace|--herdr-workspace|--project|--thread|--id|--pane|--first|--second|--ratio|--path|--url|--text|--target|--script|--json-payload|--prompt|--call|--name|--lines|--command|--label|--profile|--remote|--cwd|--remote-cwd|--local-dir) return 0 ;;
        \\  esac
        \\
        \\  if [[ "$cur" == -* ]]; then
        \\    case "$root" in
        \\      "")
        \\        COMPREPLY=( $(compgen -W "--help -h" -- "$cur") )
        \\        ;;
        \\      version|capabilities)
        \\        COMPREPLY=( $(compgen -W "$json_flags" -- "$cur") )
        \\        ;;
        \\      state)
        \\        case "$sub" in
        \\          panes|threads) COMPREPLY=( $(compgen -W "$project_json_flags" -- "$cur") ) ;;
        \\          transcript) COMPREPLY=( $(compgen -W "--workspace --thread --json" -- "$cur") ) ;;
        \\          *) COMPREPLY=( $(compgen -W "$json_flags" -- "$cur") ) ;;
        \\        esac
        \\        ;;
        \\      herdr)
        \\        case "$sub" in
        \\          open) COMPREPLY=( $(compgen -W "$herdr_open_flags" -- "$cur") ) ;;
        \\          handoff) COMPREPLY=( $(compgen -W "$herdr_handoff_flags" -- "$cur") ) ;;
        \\          unlink) COMPREPLY=( $(compgen -W "$herdr_unlink_flags" -- "$cur") ) ;;
        \\          profiles)
        \\            case "$third" in
        \\              add) COMPREPLY=( $(compgen -W "$herdr_profile_add_flags" -- "$cur") ) ;;
        \\              remove|rm|test) COMPREPLY=( $(compgen -W "$herdr_profile_name_flags" -- "$cur") ) ;;
        \\              list) COMPREPLY=( $(compgen -W "$json_flags" -- "$cur") ) ;;
        \\              *) COMPREPLY=( $(compgen -W "$herdr_profiles" -- "$cur") ) ;;
        \\            esac ;;
        \\          *) COMPREPLY=( $(compgen -W "$json_flags" -- "$cur") ) ;;
        \\        esac
        \\        ;;
        \\      integrations)
        \\        case "$sub" in
        \\          list|doctor) COMPREPLY=( $(compgen -W "$json_flags" -- "$cur") ) ;;
        \\          *) COMPREPLY=( $(compgen -W "--help -h" -- "$cur") ) ;;
        \\        esac
        \\        ;;
        \\      session)
        \\        case "$sub" in
        \\          inspect|screen) COMPREPLY=( $(compgen -W "--id --json" -- "$cur") ) ;;
        \\          new) COMPREPLY=( $(compgen -W "--workspace --name --json" -- "$cur") ) ;;
        \\          attach) COMPREPLY=( $(compgen -W "--id --workspace --pane" -- "$cur") ) ;;
        \\          write) COMPREPLY=( $(compgen -W "--id --text --json" -- "$cur") ) ;;
        \\          tail) COMPREPLY=( $(compgen -W "--id --lines --json" -- "$cur") ) ;;
        \\          kill) COMPREPLY=( $(compgen -W "--id --json" -- "$cur") ) ;;
        \\          *) COMPREPLY=( $(compgen -W "$json_flags" -- "$cur") ) ;;
        \\        esac
        \\        ;;
        \\      live)
        \\        case "$sub" in
        \\          panes|threads|terminals) COMPREPLY=( $(compgen -W "$project_json_flags" -- "$cur") ) ;;
        \\          inspect) COMPREPLY=( $(compgen -W "$pane_flags" -- "$cur") ) ;;
        \\          workspace)
        \\            case "$third" in
        \\              select) COMPREPLY=( $(compgen -W "$workspace_select_flags" -- "$cur") ) ;;
        \\              create) COMPREPLY=( $(compgen -W "$workspace_create_flags" -- "$cur") ) ;;
        \\              rename) COMPREPLY=( $(compgen -W "$workspace_rename_flags" -- "$cur") ) ;;
        \\              close) COMPREPLY=( $(compgen -W "$workspace_close_flags" -- "$cur") ) ;;
        \\              reopen) COMPREPLY=( $(compgen -W "$workspace_reopen_flags" -- "$cur") ) ;;
        \\              archive) COMPREPLY=( $(compgen -W "$workspace_archive_flags" -- "$cur") ) ;;
        \\              *) COMPREPLY=( $(compgen -W "$json_flags" -- "$cur") ) ;;
        \\            esac
        \\            ;;
        \\          pane)
        \\            case "$third" in
        \\              split) COMPREPLY=( $(compgen -W "$pane_split_flags" -- "$cur") ) ;;
        \\              resize) COMPREPLY=( $(compgen -W "$pane_resize_flags" -- "$cur") ) ;;
        \\              move) COMPREPLY=( $(compgen -W "$pane_move_flags" -- "$cur") ) ;;
        \\              *) COMPREPLY=( $(compgen -W "$pane_flags" -- "$cur") ) ;;
        \\            esac
        \\            ;;
        \\          chat)
        \\            case "$third" in
        \\              draft) COMPREPLY=( $(compgen -W "$chat_draft_flags" -- "$cur") ) ;;
        \\              send|followup) COMPREPLY=( $(compgen -W "$chat_send_flags" -- "$cur") ) ;;
        \\              approve) COMPREPLY=( $(compgen -W "$chat_approve_flags" -- "$cur") ) ;;
        \\              *) COMPREPLY=( $(compgen -W "$pane_flags" -- "$cur") ) ;;
        \\            esac
        \\            ;;
        \\          browser)
        \\            case "$third" in
        \\              open) COMPREPLY=( $(compgen -W "$browser_open_flags" -- "$cur") ) ;;
        \\              navigate) COMPREPLY=( $(compgen -W "$browser_navigate_flags" -- "$cur") ) ;;
        \\              eval) COMPREPLY=( $(compgen -W "$browser_eval_flags" -- "$cur") ) ;;
        \\              post-json) COMPREPLY=( $(compgen -W "$browser_post_json_flags" -- "$cur") ) ;;
        \\              toolbar-hit) COMPREPLY=( $(compgen -W "$browser_toolbar_hit_flags" -- "$cur") ) ;;
        \\              paste-text) COMPREPLY=( $(compgen -W "$browser_paste_text_flags" -- "$cur") ) ;;
        \\              inspector-mode) COMPREPLY=( $(compgen -W "$browser_inspector_mode_flags" -- "$cur") ) ;;
        \\              *) COMPREPLY=( $(compgen -W "$json_flags" -- "$cur") ) ;;
        \\            esac
        \\            ;;
        \\          palette)
        \\            case "$third" in
        \\              run) COMPREPLY=( $(compgen -W "$palette_run_flags" -- "$cur") ) ;;
        \\              *) COMPREPLY=( $(compgen -W "$json_flags" -- "$cur") ) ;;
        \\            esac
        \\            ;;
        \\          terminal)
        \\            case "$third" in
        \\              write) COMPREPLY=( $(compgen -W "$terminal_write_flags" -- "$cur") ) ;;
        \\              tail) COMPREPLY=( $(compgen -W "$terminal_tail_flags" -- "$cur") ) ;;
        \\              *) COMPREPLY=( $(compgen -W "$pane_flags" -- "$cur") ) ;;
        \\            esac
        \\            ;;
        \\          process) COMPREPLY=( $(compgen -W "$process_flags" -- "$cur") ) ;;
        \\          agent) COMPREPLY=( $(compgen -W "$agent_flags" -- "$cur") ) ;;
        \\          stack) COMPREPLY=( $(compgen -W "$project_json_flags" -- "$cur") ) ;;
        \\          *) COMPREPLY=( $(compgen -W "$json_flags" -- "$cur") ) ;;
        \\        esac
        \\        ;;
        \\      *) COMPREPLY=( $(compgen -W "$all_flags" -- "$cur") ) ;;
        \\    esac
        \\    return 0
        \\  fi
        \\
        \\  case "$COMP_CWORD:$root:$sub:$third" in
        \\    1:*) COMPREPLY=( $(compgen -W "$top --help -h" -- "$cur") ) ;;
        \\    2:completion:*) COMPREPLY=( $(compgen -W "$shells" -- "$cur") ) ;;
        \\    2:state:*) COMPREPLY=( $(compgen -W "$state" -- "$cur") ) ;;
        \\    2:herdr:*) COMPREPLY=( $(compgen -W "$herdr" -- "$cur") ) ;;
        \\    2:integrations:*) COMPREPLY=( $(compgen -W "$integrations" -- "$cur") ) ;;
        \\    2:session:*) COMPREPLY=( $(compgen -W "$session" -- "$cur") ) ;;
        \\    2:live:*) COMPREPLY=( $(compgen -W "$live" -- "$cur") ) ;;
        \\    3:integrations:install:|3:integrations:remove:|3:integrations:disable:) COMPREPLY=( $(compgen -W "$integration_providers" -- "$cur") ) ;;
        \\    3:live:workspace:*) COMPREPLY=( $(compgen -W "$workspace" -- "$cur") ) ;;
        \\    3:live:pane:*) COMPREPLY=( $(compgen -W "$pane" -- "$cur") ) ;;
        \\    3:live:chat:*) COMPREPLY=( $(compgen -W "$chat" -- "$cur") ) ;;
        \\    3:live:browser:*) COMPREPLY=( $(compgen -W "$browser" -- "$cur") ) ;;
        \\    3:live:terminal:*) COMPREPLY=( $(compgen -W "$terminal" -- "$cur") ) ;;
        \\    3:live:process:*) COMPREPLY=( $(compgen -W "$process" -- "$cur") ) ;;
        \\    3:live:agent:*) COMPREPLY=( $(compgen -W "$agent" -- "$cur") ) ;;
        \\    3:live:stack:*) COMPREPLY=( $(compgen -W "$stack" -- "$cur") ) ;;
        \\    4:live:chat:draft) COMPREPLY=( $(compgen -W "$draft" -- "$cur") ) ;;
        \\  esac
        \\}
        \\complete -F _verde_completion verde
        \\
    );
}

fn writeZsh(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\#compdef verde
        \\# zsh completion for verde
        \\_verde() {
        \\  local cur prev root sub third fourth
        \\  cur="${words[CURRENT]}"
        \\  prev="${words[CURRENT-1]}"
        \\  root="${words[2]}"
        \\  sub="${words[3]}"
        \\  third="${words[4]}"
        \\  fourth="${words[5]}"
        \\
        \\  local top="
    );
    try writeWords(w, &spec.top_level_commands);
    try w.writeAll("\"\n  local shells=\"");
    try writeWords(w, &spec.shells);
    try w.writeAll("\"\n  local state=\"");
    try writeWords(w, &spec.state_commands);
    try w.writeAll("\"\n  local herdr=\"");
    try writeWords(w, &spec.herdr_commands);
    try w.writeAll("\"\n  local integrations=\"");
    try writeWords(w, &spec.integration_commands);
    try w.writeAll("\"\n  local integration_providers=\"");
    try writeWords(w, &spec.integration_providers);
    try w.writeAll("\"\n  local session=\"");
    try writeWords(w, &spec.session_commands);
    try w.writeAll("\"\n  local live=\"");
    try writeWords(w, &spec.live_commands);
    try w.writeAll("\"\n  local workspace=\"");
    try writeWords(w, &spec.workspace_commands);
    try w.writeAll("\"\n  local pane=\"");
    try writeWords(w, &spec.pane_commands);
    try w.writeAll("\"\n  local chat=\"");
    try writeWords(w, &spec.chat_commands);
    try w.writeAll("\"\n  local draft=\"");
    try writeWords(w, &spec.chat_draft_commands);
    try w.writeAll("\"\n  local browser=\"");
    try writeWords(w, &spec.browser_commands);
    try w.writeAll("\"\n  local palette=\"");
    try writeWords(w, &spec.palette_commands);
    try w.writeAll("\"\n  local terminal=\"");
    try writeWords(w, &spec.terminal_commands);
    try w.writeAll("\"\n  local process=\"");
    try writeWords(w, &spec.process_commands);
    try w.writeAll("\"\n  local agent=\"");
    try writeWords(w, &spec.agent_commands);
    try w.writeAll("\"\n  local stack=\"");
    try writeWords(w, &spec.stack_commands);
    try w.writeAll("\"\n  local all_flags=\"");
    try writeWords(w, &spec.all_flags);
    try w.writeAll("\"\n  local json_flags=\"");
    try writeWords(w, &spec.json_flags);
    try w.writeAll("\"\n  local project_json_flags=\"");
    try writeWords(w, &spec.project_json_flags);
    try w.writeAll("\"\n  local herdr_profiles=\"");
    try writeWords(w, &spec.herdr_profile_commands);
    try w.writeAll("\"\n  local herdr_open_flags=\"");
    try writeWords(w, &spec.herdr_open_flags);
    try w.writeAll("\"\n  local herdr_handoff_flags=\"");
    try writeWords(w, &spec.herdr_handoff_flags);
    try w.writeAll("\"\n  local herdr_unlink_flags=\"");
    try writeWords(w, &spec.herdr_unlink_flags);
    try w.writeAll("\"\n  local herdr_profile_add_flags=\"");
    try writeWords(w, &spec.herdr_profile_add_flags);
    try w.writeAll("\"\n  local herdr_profile_name_flags=\"");
    try writeWords(w, &spec.herdr_profile_name_flags);
    try w.writeAll("\"\n  local pane_flags=\"");
    try writeWords(w, &spec.pane_flags);
    try w.writeAll("\"\n  local pane_split_flags=\"");
    try writeWords(w, &spec.pane_split_flags);
    try w.writeAll("\"\n  local pane_resize_flags=\"");
    try writeWords(w, &spec.pane_resize_flags);
    try w.writeAll("\"\n  local pane_move_flags=\"");
    try writeWords(w, &spec.pane_move_flags);
    try w.writeAll("\"\n  local workspace_select_flags=\"");
    try writeWords(w, &spec.workspace_select_flags);
    try w.writeAll("\"\n  local workspace_create_flags=\"");
    try writeWords(w, &spec.workspace_create_flags);
    try w.writeAll("\"\n  local workspace_rename_flags=\"");
    try writeWords(w, &spec.workspace_rename_flags);
    try w.writeAll("\"\n  local workspace_close_flags=\"");
    try writeWords(w, &spec.workspace_close_flags);
    try w.writeAll("\"\n  local workspace_reopen_flags=\"");
    try writeWords(w, &spec.workspace_reopen_flags);
    try w.writeAll("\"\n  local workspace_archive_flags=\"");
    try writeWords(w, &spec.workspace_archive_flags);
    try w.writeAll("\"\n  local chat_draft_flags=\"");
    try writeWords(w, &spec.chat_draft_flags);
    try w.writeAll("\"\n  local chat_send_flags=\"");
    try writeWords(w, &spec.chat_send_flags);
    try w.writeAll("\"\n  local chat_approve_flags=\"");
    try writeWords(w, &spec.chat_approve_flags);
    try w.writeAll("\"\n  local browser_open_flags=\"");
    try writeWords(w, &spec.browser_open_flags);
    try w.writeAll("\"\n  local browser_navigate_flags=\"");
    try writeWords(w, &spec.browser_navigate_flags);
    try w.writeAll("\"\n  local browser_eval_flags=\"");
    try writeWords(w, &spec.browser_eval_flags);
    try w.writeAll("\"\n  local browser_post_json_flags=\"");
    try writeWords(w, &spec.browser_post_json_flags);
    try w.writeAll("\"\n  local browser_toolbar_hit_flags=\"");
    try writeWords(w, &spec.browser_toolbar_hit_flags);
    try w.writeAll("\"\n  local browser_paste_text_flags=\"");
    try writeWords(w, &spec.browser_paste_text_flags);
    try w.writeAll("\"\n  local browser_inspector_mode_flags=\"");
    try writeWords(w, &spec.browser_inspector_mode_flags);
    try w.writeAll("\"\n  local palette_run_flags=\"");
    try writeWords(w, &spec.palette_run_flags);
    try w.writeAll("\"\n  local terminal_write_flags=\"");
    try writeWords(w, &spec.terminal_write_flags);
    try w.writeAll("\"\n  local terminal_tail_flags=\"");
    try writeWords(w, &spec.terminal_tail_flags);
    try w.writeAll("\"\n  local process_flags=\"");
    try writeWords(w, &spec.process_flags);
    try w.writeAll("\"\n  local agent_flags=\"");
    try writeWords(w, &spec.agent_flags);
    try w.writeAll("\"\n  local kind_values=\"");
    try writeWords(w, &spec.kind_values);
    try w.writeAll("\"\n  local axis_values=\"");
    try writeWords(w, &spec.axis_values);
    try w.writeAll("\"\n  local direction_values=\"");
    try writeWords(w, &spec.direction_values);
    try w.writeAll("\"\n  local decision_values=\"");
    try writeWords(w, &spec.decision_values);
    try w.writeAll("\"\n  local provider_values=\"");
    try writeWords(w, &spec.provider_values);
    try w.writeAll("\"\n  local inspector_mode_values=\"");
    try writeWords(w, &spec.inspector_mode_values);
    try w.writeAll(
        \\"
        \\
        \\  case "$prev" in
        \\    --kind) compadd -- ${(s: :)kind_values}; return ;;
        \\    --axis) compadd -- ${(s: :)axis_values}; return ;;
        \\    --direction) compadd -- ${(s: :)direction_values}; return ;;
        \\    --decision) compadd -- ${(s: :)decision_values}; return ;;
        \\    --provider) compadd -- ${(s: :)provider_values}; return ;;
        \\    --mode) compadd -- ${(s: :)inspector_mode_values}; return ;;
        \\    --workspace|--herdr-workspace|--project|--thread|--id|--pane|--first|--second|--ratio|--path|--url|--text|--target|--script|--json-payload|--prompt|--call|--name|--lines|--command|--label|--profile|--remote|--cwd|--remote-cwd|--local-dir) return ;;
        \\  esac
        \\
        \\  if [[ "$cur" == -* ]]; then
        \\    case "$root" in
        \\      "")
        \\        compadd -- --help -h
        \\        ;;
        \\      version|capabilities)
        \\        compadd -- ${(s: :)json_flags}
        \\        ;;
        \\      state)
        \\        case "$sub" in
        \\          panes|threads) compadd -- ${(s: :)project_json_flags} ;;
        \\          transcript) compadd -- --workspace --thread --json ;;
        \\          *) compadd -- ${(s: :)json_flags} ;;
        \\        esac
        \\        ;;
        \\      herdr)
        \\        case "$sub" in
        \\          open) compadd -- ${(s: :)herdr_open_flags} ;;
        \\          handoff) compadd -- ${(s: :)herdr_handoff_flags} ;;
        \\          unlink) compadd -- ${(s: :)herdr_unlink_flags} ;;
        \\          profiles)
        \\            case "$third" in
        \\              add) compadd -- ${(s: :)herdr_profile_add_flags} ;;
        \\              remove|rm|test) compadd -- ${(s: :)herdr_profile_name_flags} ;;
        \\              list) compadd -- ${(s: :)json_flags} ;;
        \\              *) compadd -- ${(s: :)herdr_profiles} ;;
        \\            esac ;;
        \\          *) compadd -- ${(s: :)json_flags} ;;
        \\        esac
        \\        ;;
        \\      integrations)
        \\        case "$sub" in
        \\          list|doctor) compadd -- ${(s: :)json_flags} ;;
        \\          *) compadd -- --help -h ;;
        \\        esac
        \\        ;;
        \\      session)
        \\        case "$sub" in
        \\          inspect|screen) compadd -- --id --json ;;
        \\          new) compadd -- --workspace --name --json ;;
        \\          attach) compadd -- --id --workspace --pane ;;
        \\          write) compadd -- --id --text --json ;;
        \\          tail) compadd -- --id --lines --json ;;
        \\          kill) compadd -- --id --json ;;
        \\          *) compadd -- ${(s: :)json_flags} ;;
        \\        esac
        \\        ;;
        \\      live)
        \\        case "$sub" in
        \\          panes|threads|terminals) compadd -- ${(s: :)project_json_flags} ;;
        \\          inspect) compadd -- ${(s: :)pane_flags} ;;
        \\          workspace)
        \\            case "$third" in
        \\              select) compadd -- ${(s: :)workspace_select_flags} ;;
        \\              create) compadd -- ${(s: :)workspace_create_flags} ;;
        \\              rename) compadd -- ${(s: :)workspace_rename_flags} ;;
        \\              close) compadd -- ${(s: :)workspace_close_flags} ;;
        \\              reopen) compadd -- ${(s: :)workspace_reopen_flags} ;;
        \\              archive) compadd -- ${(s: :)workspace_archive_flags} ;;
        \\              *) compadd -- ${(s: :)json_flags} ;;
        \\            esac
        \\            ;;
        \\          pane)
        \\            case "$third" in
        \\              split) compadd -- ${(s: :)pane_split_flags} ;;
        \\              resize) compadd -- ${(s: :)pane_resize_flags} ;;
        \\              move) compadd -- ${(s: :)pane_move_flags} ;;
        \\              *) compadd -- ${(s: :)pane_flags} ;;
        \\            esac
        \\            ;;
        \\          chat)
        \\            case "$third" in
        \\              draft) compadd -- ${(s: :)chat_draft_flags} ;;
        \\              send|followup) compadd -- ${(s: :)chat_send_flags} ;;
        \\              approve) compadd -- ${(s: :)chat_approve_flags} ;;
        \\              *) compadd -- ${(s: :)pane_flags} ;;
        \\            esac
        \\            ;;
        \\          browser)
        \\            case "$third" in
        \\              open) compadd -- ${(s: :)browser_open_flags} ;;
        \\              navigate) compadd -- ${(s: :)browser_navigate_flags} ;;
        \\              eval) compadd -- ${(s: :)browser_eval_flags} ;;
        \\              post-json) compadd -- ${(s: :)browser_post_json_flags} ;;
        \\              toolbar-hit) compadd -- ${(s: :)browser_toolbar_hit_flags} ;;
        \\              paste-text) compadd -- ${(s: :)browser_paste_text_flags} ;;
        \\              inspector-mode) compadd -- ${(s: :)browser_inspector_mode_flags} ;;
        \\              *) compadd -- ${(s: :)json_flags} ;;
        \\            esac
        \\            ;;
        \\          palette)
        \\            case "$third" in
        \\              run) compadd -- ${(s: :)palette_run_flags} ;;
        \\              *) compadd -- ${(s: :)json_flags} ;;
        \\            esac
        \\            ;;
        \\          terminal)
        \\            case "$third" in
        \\              write) compadd -- ${(s: :)terminal_write_flags} ;;
        \\              tail) compadd -- ${(s: :)terminal_tail_flags} ;;
        \\              *) compadd -- ${(s: :)pane_flags} ;;
        \\            esac
        \\            ;;
        \\          process) compadd -- ${(s: :)process_flags} ;;
        \\          agent) compadd -- ${(s: :)agent_flags} ;;
        \\          stack) compadd -- ${(s: :)project_json_flags} ;;
        \\          *) compadd -- ${(s: :)json_flags} ;;
        \\        esac
        \\        ;;
        \\      *) compadd -- ${(s: :)all_flags} ;;
        \\    esac
        \\    return
        \\  fi
        \\
        \\  case "$CURRENT:$root:$sub:$third" in
        \\    2:*) compadd -- ${(s: :)top} --help -h ;;
        \\    3:completion:*) compadd -- ${(s: :)shells} ;;
        \\    3:state:*) compadd -- ${(s: :)state} ;;
        \\    3:herdr:*) compadd -- ${(s: :)herdr} ;;
        \\    3:integrations:*) compadd -- ${(s: :)integrations} ;;
        \\    3:session:*) compadd -- ${(s: :)session} ;;
        \\    3:live:*) compadd -- ${(s: :)live} ;;
        \\    4:integrations:install:|4:integrations:remove:|4:integrations:disable:) compadd -- ${(s: :)integration_providers} ;;
        \\    4:live:workspace:*) compadd -- ${(s: :)workspace} ;;
        \\    4:live:pane:*) compadd -- ${(s: :)pane} ;;
        \\    4:live:chat:*) compadd -- ${(s: :)chat} ;;
        \\    4:live:browser:*) compadd -- ${(s: :)browser} ;;
        \\    4:live:terminal:*) compadd -- ${(s: :)terminal} ;;
        \\    4:live:process:*) compadd -- ${(s: :)process} ;;
        \\    4:live:agent:*) compadd -- ${(s: :)agent} ;;
        \\    4:live:stack:*) compadd -- ${(s: :)stack} ;;
        \\    5:live:chat:draft) compadd -- ${(s: :)draft} ;;
        \\  esac
        \\}
        \\_verde "$@"
        \\
    );
}

fn writeFish(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\# fish completion for verde
        \\complete -c verde -f
        \\
        \\function __verde_complete_after
        \\    set -l tokens (commandline -opc)
        \\    set -l expected $argv
        \\    test (count $tokens) -eq (math (count $expected) + 1); or return 1
        \\    test "$tokens[1]" = verde; or return 1
        \\    for i in (seq (count $expected))
        \\        set -l token_index (math $i + 1)
        \\        test "$tokens[$token_index]" = "$expected[$i]"; or return 1
        \\    end
        \\end
        \\
        \\function __verde_prev_is
        \\    set -l tokens (commandline -opc)
        \\    test (count $tokens) -gt 1; and test "$tokens[-1]" = "$argv[1]"
        \\end
        \\
        \\complete -c verde -n '__verde_complete_after' -a '
    );
    try writeWords(w, &spec.top_level_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after completion' -a '");
    try writeWords(w, &spec.shells);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after state' -a '");
    try writeWords(w, &spec.state_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after herdr' -a '");
    try writeWords(w, &spec.herdr_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after herdr profiles' -a '");
    try writeWords(w, &spec.herdr_profile_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after integrations' -a '");
    try writeWords(w, &spec.integration_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after integrations install' -a '");
    try writeWords(w, &spec.integration_providers);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after integrations remove' -a '");
    try writeWords(w, &spec.integration_providers);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after integrations disable' -a '");
    try writeWords(w, &spec.integration_providers);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after session' -a '");
    try writeWords(w, &spec.session_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live' -a '");
    try writeWords(w, &spec.live_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live workspace' -a '");
    try writeWords(w, &spec.workspace_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live pane' -a '");
    try writeWords(w, &spec.pane_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live chat' -a '");
    try writeWords(w, &spec.chat_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live chat draft' -a '");
    try writeWords(w, &spec.chat_draft_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live browser' -a '");
    try writeWords(w, &spec.browser_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live palette' -a '");
    try writeWords(w, &spec.palette_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live terminal' -a '");
    try writeWords(w, &spec.terminal_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live process' -a '");
    try writeWords(w, &spec.process_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live agent' -a '");
    try writeWords(w, &spec.agent_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live stack' -a '");
    try writeWords(w, &spec.stack_commands);
    try w.writeAll("'\n\ncomplete -c verde -l json -d 'Print JSON output'\n");
    try w.writeAll(
        \\complete -c verde -l id -r -d 'Persistent session id'
        \\complete -c verde -l workspace -r -d 'Workspace id, index, path, or current'
        \\complete -c verde -l herdr-workspace -r -d 'Herdr workspace id'
        \\complete -c verde -l ssh-target -r -d 'SSH config alias for a Herdr remote profile'
        \\complete -c verde -l profile -r -d 'Named Herdr remote profile'
        \\complete -c verde -l remote -r -d 'Herdr SSH remote alias'
        \\complete -c verde -l cwd -r -d 'Local Herdr workspace cwd'
        \\complete -c verde -l remote-cwd -r -d 'Remote Herdr workspace cwd'
        \\complete -c verde -l local-dir -r -d 'Local shadow workspace directory'
        \\complete -c verde -l all -d 'Target all workspaces'
        \\complete -c verde -l dry-run -d 'Show planned changes without modifying Herdr'
        \\complete -c verde -l thread -r -d 'Thread index or provider id'
        \\complete -c verde -l pane -r -d 'Workspace pane id'
        \\complete -c verde -l focused -d 'Use the focused pane'
        \\complete -c verde -l first -r -d 'First sibling pane id'
        \\complete -c verde -l second -r -d 'Second sibling pane id'
        \\complete -c verde -l ratio -r -d 'Split ratio'
        \\complete -c verde -l direction -r -d 'Pane move direction'
        \\complete -c verde -l path -r -d 'Workspace path'
        \\complete -c verde -l url -r -d 'Browser URL'
        \\complete -c verde -l text -r -d 'Text argument'
        \\complete -c verde -l target -r -d 'Browser toolbar target'
        \\complete -c verde -l prompt -r -d 'Prompt text'
        \\complete -c verde -l call -r -d 'Approval call id'
        \\complete -c verde -l name -r -d 'Configured process name'
        \\complete -c verde -l provider -r -d 'Provider name'
        \\complete -c verde -l lines -r -d 'Number of output lines'
        \\complete -c verde -l mode -r -d 'Browser inspector mode'
        \\complete -c verde -l command -r -d 'Command palette id'
        \\complete -c verde -l label -r -d 'Workspace label'
        \\complete -c verde -s h -l help -d 'Show help'
        \\
        \\complete -c verde -n '__verde_prev_is --kind' -a '
    );
    try writeWords(w, &spec.kind_values);
    try w.writeAll("'\ncomplete -c verde -n '__verde_prev_is --axis' -a '");
    try writeWords(w, &spec.axis_values);
    try w.writeAll("'\ncomplete -c verde -n '__verde_prev_is --direction' -a '");
    try writeWords(w, &spec.direction_values);
    try w.writeAll("'\ncomplete -c verde -n '__verde_prev_is --decision' -a '");
    try writeWords(w, &spec.decision_values);
    try w.writeAll("'\ncomplete -c verde -n '__verde_prev_is --provider' -a '");
    try writeWords(w, &spec.provider_values);
    try w.writeAll("'\ncomplete -c verde -n '__verde_prev_is --mode' -a '");
    try writeWords(w, &spec.inspector_mode_values);
    try w.writeAll("'\n");
}

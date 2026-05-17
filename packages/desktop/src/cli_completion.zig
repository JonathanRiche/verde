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
    try w.writeAll("\"\n  local live=\"");
    try writeWords(w, &spec.live_commands);
    try w.writeAll("\"\n  local pane=\"");
    try writeWords(w, &spec.pane_commands);
    try w.writeAll("\"\n  local chat=\"");
    try writeWords(w, &spec.chat_commands);
    try w.writeAll("\"\n  local draft=\"");
    try writeWords(w, &spec.chat_draft_commands);
    try w.writeAll("\"\n  local terminal=\"");
    try writeWords(w, &spec.terminal_commands);
    try w.writeAll("\"\n  local process=\"");
    try writeWords(w, &spec.process_commands);
    try w.writeAll("\"\n  local stack=\"");
    try writeWords(w, &spec.stack_commands);
    try w.writeAll("\"\n  local all_flags=\"");
    try writeWords(w, &spec.all_flags);
    try w.writeAll("\"\n  local json_flags=\"");
    try writeWords(w, &spec.json_flags);
    try w.writeAll("\"\n  local project_json_flags=\"");
    try writeWords(w, &spec.project_json_flags);
    try w.writeAll("\"\n  local pane_flags=\"");
    try writeWords(w, &spec.pane_flags);
    try w.writeAll("\"\n  local pane_split_flags=\"");
    try writeWords(w, &spec.pane_split_flags);
    try w.writeAll("\"\n  local pane_resize_flags=\"");
    try writeWords(w, &spec.pane_resize_flags);
    try w.writeAll("\"\n  local chat_draft_flags=\"");
    try writeWords(w, &spec.chat_draft_flags);
    try w.writeAll("\"\n  local chat_send_flags=\"");
    try writeWords(w, &spec.chat_send_flags);
    try w.writeAll("\"\n  local chat_approve_flags=\"");
    try writeWords(w, &spec.chat_approve_flags);
    try w.writeAll("\"\n  local terminal_write_flags=\"");
    try writeWords(w, &spec.terminal_write_flags);
    try w.writeAll("\"\n  local terminal_tail_flags=\"");
    try writeWords(w, &spec.terminal_tail_flags);
    try w.writeAll("\"\n  local process_flags=\"");
    try writeWords(w, &spec.process_flags);
    try w.writeAll("\"\n  local kind_values=\"");
    try writeWords(w, &spec.kind_values);
    try w.writeAll("\"\n  local axis_values=\"");
    try writeWords(w, &spec.axis_values);
    try w.writeAll("\"\n  local decision_values=\"");
    try writeWords(w, &spec.decision_values);
    try w.writeAll(
        \\"
        \\
        \\  case "$prev" in
        \\    --kind) COMPREPLY=( $(compgen -W "$kind_values" -- "$cur") ); return 0 ;;
        \\    --axis) COMPREPLY=( $(compgen -W "$axis_values" -- "$cur") ); return 0 ;;
        \\    --decision) COMPREPLY=( $(compgen -W "$decision_values" -- "$cur") ); return 0 ;;
        \\    --project|--thread|--pane|--first|--second|--ratio|--text|--prompt|--call|--name|--lines) return 0 ;;
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
        \\          transcript) COMPREPLY=( $(compgen -W "--project --thread --json" -- "$cur") ) ;;
        \\          *) COMPREPLY=( $(compgen -W "$json_flags" -- "$cur") ) ;;
        \\        esac
        \\        ;;
        \\      live)
        \\        case "$sub" in
        \\          panes|threads|terminals) COMPREPLY=( $(compgen -W "$project_json_flags" -- "$cur") ) ;;
        \\          inspect) COMPREPLY=( $(compgen -W "$pane_flags" -- "$cur") ) ;;
        \\          pane)
        \\            case "$third" in
        \\              split) COMPREPLY=( $(compgen -W "$pane_split_flags" -- "$cur") ) ;;
        \\              resize) COMPREPLY=( $(compgen -W "$pane_resize_flags" -- "$cur") ) ;;
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
        \\          terminal)
        \\            case "$third" in
        \\              write) COMPREPLY=( $(compgen -W "$terminal_write_flags" -- "$cur") ) ;;
        \\              tail) COMPREPLY=( $(compgen -W "$terminal_tail_flags" -- "$cur") ) ;;
        \\              *) COMPREPLY=( $(compgen -W "$pane_flags" -- "$cur") ) ;;
        \\            esac
        \\            ;;
        \\          process) COMPREPLY=( $(compgen -W "$process_flags" -- "$cur") ) ;;
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
        \\    2:live:*) COMPREPLY=( $(compgen -W "$live" -- "$cur") ) ;;
        \\    3:live:pane:*) COMPREPLY=( $(compgen -W "$pane" -- "$cur") ) ;;
        \\    3:live:chat:*) COMPREPLY=( $(compgen -W "$chat" -- "$cur") ) ;;
        \\    3:live:terminal:*) COMPREPLY=( $(compgen -W "$terminal" -- "$cur") ) ;;
        \\    3:live:process:*) COMPREPLY=( $(compgen -W "$process" -- "$cur") ) ;;
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
    try w.writeAll("\"\n  local live=\"");
    try writeWords(w, &spec.live_commands);
    try w.writeAll("\"\n  local pane=\"");
    try writeWords(w, &spec.pane_commands);
    try w.writeAll("\"\n  local chat=\"");
    try writeWords(w, &spec.chat_commands);
    try w.writeAll("\"\n  local draft=\"");
    try writeWords(w, &spec.chat_draft_commands);
    try w.writeAll("\"\n  local terminal=\"");
    try writeWords(w, &spec.terminal_commands);
    try w.writeAll("\"\n  local process=\"");
    try writeWords(w, &spec.process_commands);
    try w.writeAll("\"\n  local stack=\"");
    try writeWords(w, &spec.stack_commands);
    try w.writeAll("\"\n  local all_flags=\"");
    try writeWords(w, &spec.all_flags);
    try w.writeAll("\"\n  local json_flags=\"");
    try writeWords(w, &spec.json_flags);
    try w.writeAll("\"\n  local project_json_flags=\"");
    try writeWords(w, &spec.project_json_flags);
    try w.writeAll("\"\n  local pane_flags=\"");
    try writeWords(w, &spec.pane_flags);
    try w.writeAll("\"\n  local pane_split_flags=\"");
    try writeWords(w, &spec.pane_split_flags);
    try w.writeAll("\"\n  local pane_resize_flags=\"");
    try writeWords(w, &spec.pane_resize_flags);
    try w.writeAll("\"\n  local chat_draft_flags=\"");
    try writeWords(w, &spec.chat_draft_flags);
    try w.writeAll("\"\n  local chat_send_flags=\"");
    try writeWords(w, &spec.chat_send_flags);
    try w.writeAll("\"\n  local chat_approve_flags=\"");
    try writeWords(w, &spec.chat_approve_flags);
    try w.writeAll("\"\n  local terminal_write_flags=\"");
    try writeWords(w, &spec.terminal_write_flags);
    try w.writeAll("\"\n  local terminal_tail_flags=\"");
    try writeWords(w, &spec.terminal_tail_flags);
    try w.writeAll("\"\n  local process_flags=\"");
    try writeWords(w, &spec.process_flags);
    try w.writeAll("\"\n  local kind_values=\"");
    try writeWords(w, &spec.kind_values);
    try w.writeAll("\"\n  local axis_values=\"");
    try writeWords(w, &spec.axis_values);
    try w.writeAll("\"\n  local decision_values=\"");
    try writeWords(w, &spec.decision_values);
    try w.writeAll(
        \\"
        \\
        \\  case "$prev" in
        \\    --kind) compadd -- ${(s: :)kind_values}; return ;;
        \\    --axis) compadd -- ${(s: :)axis_values}; return ;;
        \\    --decision) compadd -- ${(s: :)decision_values}; return ;;
        \\    --project|--thread|--pane|--first|--second|--ratio|--text|--prompt|--call|--name|--lines) return ;;
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
        \\          transcript) compadd -- --project --thread --json ;;
        \\          *) compadd -- ${(s: :)json_flags} ;;
        \\        esac
        \\        ;;
        \\      live)
        \\        case "$sub" in
        \\          panes|threads|terminals) compadd -- ${(s: :)project_json_flags} ;;
        \\          inspect) compadd -- ${(s: :)pane_flags} ;;
        \\          pane)
        \\            case "$third" in
        \\              split) compadd -- ${(s: :)pane_split_flags} ;;
        \\              resize) compadd -- ${(s: :)pane_resize_flags} ;;
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
        \\          terminal)
        \\            case "$third" in
        \\              write) compadd -- ${(s: :)terminal_write_flags} ;;
        \\              tail) compadd -- ${(s: :)terminal_tail_flags} ;;
        \\              *) compadd -- ${(s: :)pane_flags} ;;
        \\            esac
        \\            ;;
        \\          process) compadd -- ${(s: :)process_flags} ;;
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
        \\    3:live:*) compadd -- ${(s: :)live} ;;
        \\    4:live:pane:*) compadd -- ${(s: :)pane} ;;
        \\    4:live:chat:*) compadd -- ${(s: :)chat} ;;
        \\    4:live:terminal:*) compadd -- ${(s: :)terminal} ;;
        \\    4:live:process:*) compadd -- ${(s: :)process} ;;
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
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live' -a '");
    try writeWords(w, &spec.live_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live pane' -a '");
    try writeWords(w, &spec.pane_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live chat' -a '");
    try writeWords(w, &spec.chat_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live chat draft' -a '");
    try writeWords(w, &spec.chat_draft_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live terminal' -a '");
    try writeWords(w, &spec.terminal_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live process' -a '");
    try writeWords(w, &spec.process_commands);
    try w.writeAll("'\ncomplete -c verde -n '__verde_complete_after live stack' -a '");
    try writeWords(w, &spec.stack_commands);
    try w.writeAll("'\n\ncomplete -c verde -l json -d 'Print JSON output'\n");
    try w.writeAll(
        \\complete -c verde -l project -r -d 'Project id, index, path, or current'
        \\complete -c verde -l thread -r -d 'Thread index or provider id'
        \\complete -c verde -l pane -r -d 'Workspace pane id'
        \\complete -c verde -l focused -d 'Use the focused pane'
        \\complete -c verde -l first -r -d 'First sibling pane id'
        \\complete -c verde -l second -r -d 'Second sibling pane id'
        \\complete -c verde -l ratio -r -d 'Split ratio'
        \\complete -c verde -l text -r -d 'Text argument'
        \\complete -c verde -l prompt -r -d 'Prompt text'
        \\complete -c verde -l call -r -d 'Approval call id'
        \\complete -c verde -l name -r -d 'Configured process name'
        \\complete -c verde -l lines -r -d 'Number of output lines'
        \\complete -c verde -s h -l help -d 'Show help'
        \\
        \\complete -c verde -n '__verde_prev_is --kind' -a '
    );
    try writeWords(w, &spec.kind_values);
    try w.writeAll("'\ncomplete -c verde -n '__verde_prev_is --axis' -a '");
    try writeWords(w, &spec.axis_values);
    try w.writeAll("'\ncomplete -c verde -n '__verde_prev_is --decision' -a '");
    try writeWords(w, &spec.decision_values);
    try w.writeAll("'\n");
}

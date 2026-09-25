//! Desktop compatibility exports for the shared remote client.

const remote = @import("verde_remote").slash_commands;

pub const LocalSlashCommandId = remote.LocalSlashCommandId;
pub const LocalSlashCommand = remote.LocalSlashCommand;
pub const LOCAL_COMMANDS = remote.LOCAL_COMMANDS;
pub const ParsedSlashCommand = remote.ParsedSlashCommand;
pub const parse = remote.parse;
pub const isSlashInput = remote.isSlashInput;
pub const findLocalCommand = remote.findLocalCommand;
pub const findProviderCommand = remote.findProviderCommand;

test {
    _ = remote;
}

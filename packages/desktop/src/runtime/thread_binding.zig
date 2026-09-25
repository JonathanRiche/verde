//! Desktop compatibility exports for the shared remote client.

const remote = @import("verde_remote").thread_binding;

pub const MAX_ROUTE_ID_BYTES = remote.MAX_ROUTE_ID_BYTES;
pub const MAX_RELATIVE_CWD_BYTES = remote.MAX_RELATIVE_CWD_BYTES;
pub const RUNTIME_ID_BYTES = remote.RUNTIME_ID_BYTES;
pub const LOCAL_PROFILE_ID = remote.LOCAL_PROFILE_ID;
pub const Selection = remote.Selection;
pub const Pinned = remote.Pinned;
pub const SelectResult = remote.SelectResult;
pub const ThreadBinding = remote.ThreadBinding;
pub const validateSelection = remote.validateSelection;
pub const validateRuntimeId = remote.validateRuntimeId;

test {
    _ = remote;
}

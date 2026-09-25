//! Desktop compatibility exports for the shared remote client.

const remote = @import("verde_remote").connection;

pub const RECONNECT_BASE_DELAY_MS = remote.RECONNECT_BASE_DELAY_MS;
pub const RECONNECT_MAX_DELAY_MS = remote.RECONNECT_MAX_DELAY_MS;
pub const RECONNECT_MAX_JITTER_MS = remote.RECONNECT_MAX_JITTER_MS;
pub const MAX_SERVER_VERSION_BYTES = remote.MAX_SERVER_VERSION_BYTES;
pub const MAX_RUNTIME_CAPABILITIES = remote.MAX_RUNTIME_CAPABILITIES;
pub const MAX_RUNTIME_CAPABILITY_BYTES = remote.MAX_RUNTIME_CAPABILITY_BYTES;
pub const MAX_ADVERTISED_ATTACHMENT_BYTES = remote.MAX_ADVERTISED_ATTACHMENT_BYTES;
pub const MAX_ADVERTISED_PARK_MS = remote.MAX_ADVERTISED_PARK_MS;
pub const Phase = remote.Phase;
pub const FailureKind = remote.FailureKind;
pub const Retry = remote.Retry;
pub const State = remote.State;
pub const ApplyResult = remote.ApplyResult;
pub const IdentityPinAdoption = remote.IdentityPinAdoption;
pub const TransportError = remote.TransportError;
pub const TransportFn = remote.TransportFn;
pub const OwnedRuntimeMetadata = remote.OwnedRuntimeMetadata;
pub const HandshakeOutcome = remote.HandshakeOutcome;
pub const performHandshakeAlloc = remote.performHandshakeAlloc;
pub const validateRuntimeStatus = remote.validateRuntimeStatus;
pub const reconnectDelayMs = remote.reconnectDelayMs;
pub const validateRuntimeId = remote.validateRuntimeId;
pub const Connection = remote.Connection;

test {
    _ = remote;
}

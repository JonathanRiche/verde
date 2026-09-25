//! Desktop compatibility exports for the shared remote client.

const remote = @import("verde_remote").profile;

pub const CURRENT_VERSION = remote.CURRENT_VERSION;
pub const DEFAULT_SSH_PORT = remote.DEFAULT_SSH_PORT;
pub const DEFAULT_REMOTE_GATEWAY_PORT = remote.DEFAULT_REMOTE_GATEWAY_PORT;
pub const MAX_PROFILES = remote.MAX_PROFILES;
pub const MAX_CREDENTIAL_REF_BYTES = remote.MAX_CREDENTIAL_REF_BYTES;
pub const MAX_URL_BYTES = remote.MAX_URL_BYTES;
pub const SPKI_SHA256_BASE64URL_BYTES = remote.SPKI_SHA256_BASE64URL_BYTES;
pub const SshTunnelInput = remote.SshTunnelInput;
pub const SshTunnel = remote.SshTunnel;
pub const ConnectTransport = remote.ConnectTransport;
pub const DirectTransport = remote.DirectTransport;
pub const Transport = remote.Transport;
pub const AccessKind = remote.AccessKind;
pub const PairedDevice = remote.PairedDevice;
pub const ConnectLink = remote.ConnectLink;
pub const Access = remote.Access;
pub const Profile = remote.Profile;
pub const OwnedProfiles = remote.OwnedProfiles;
pub const generateIdAlloc = remote.generateIdAlloc;
pub const encodeAlloc = remote.encodeAlloc;
pub const decodeAlloc = remote.decodeAlloc;
pub const redactedErrorMessage = remote.redactedErrorMessage;
pub const validateDeviceId = remote.validateDeviceId;
pub const validateCredentialRef = remote.validateCredentialRef;
pub const validateHttpsUrl = remote.validateHttpsUrl;
pub const validateWssUrl = remote.validateWssUrl;
pub const validateRuntimeHttpsOrigin = remote.validateRuntimeHttpsOrigin;
pub const validateRuntimeWssUrl = remote.validateRuntimeWssUrl;
pub const validateRuntimeEndpointPair = remote.validateRuntimeEndpointPair;
pub const validateSpkiSha256 = remote.validateSpkiSha256;
pub const validateLinkId = remote.validateLinkId;
pub const sanitizedHttpsUrlAlloc = remote.sanitizedHttpsUrlAlloc;
pub const sanitizedRuntimeHttpsOriginAlloc = remote.sanitizedRuntimeHttpsOriginAlloc;
pub const validateLabel = remote.validateLabel;
pub const validateSshHost = remote.validateSshHost;
pub const validateSshUser = remote.validateSshUser;
pub const validatePort = remote.validatePort;

test {
    _ = remote;
}

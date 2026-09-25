//! Desktop compatibility exports for the shared remote client.

const remote = @import("verde_remote").threads;

pub const providerLabel = remote.providerLabel;
pub const harnessLabel = remote.harnessLabel;
pub const accessModeLabel = remote.accessModeLabel;
pub const modelOptions = remote.modelOptions;
pub const selectedModelLabel = remote.selectedModelLabel;
pub const selectedReasoningLabel = remote.selectedReasoningLabel;
pub const selectedCommittedThreadIndex = remote.selectedCommittedThreadIndex;
pub const makeThreadTitle = remote.makeThreadTitle;
pub const isPlaceholderThreadTitle = remote.isPlaceholderThreadTitle;
pub const makeGeneratedThreadTitle = remote.makeGeneratedThreadTitle;
pub const makeTitleGenerationPrompt = remote.makeTitleGenerationPrompt;
pub const sanitizeEnum = remote.sanitizeEnum;
pub const discardHydratedTimelineEvents = remote.discardHydratedTimelineEvents;
pub const transcriptSyncGeneration = remote.transcriptSyncGeneration;

test {
    _ = remote;
}

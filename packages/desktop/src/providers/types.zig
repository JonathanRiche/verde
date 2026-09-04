//! Compatibility re-export for provider-neutral headless types.

const provider_types = @import("headless").provider_types;

pub const Provider = provider_types.Provider;
pub const ProviderSlashCommandId = provider_types.ProviderSlashCommandId;
pub const SlashCommandAvailability = provider_types.SlashCommandAvailability;
pub const ProviderSlashCommand = provider_types.ProviderSlashCommand;
pub const HarnessKind = provider_types.HarnessKind;
pub const AuthState = provider_types.AuthState;
pub const MessageRole = provider_types.MessageRole;
pub const ChatMessage = provider_types.ChatMessage;
pub const ImageAttachment = provider_types.ImageAttachment;
pub const ChatThreadSummary = provider_types.ChatThreadSummary;
pub const ModelInfo = provider_types.ModelInfo;
pub const freeModelInfos = provider_types.freeModelInfos;
pub const ReadThreadResult = provider_types.ReadThreadResult;
pub const ReasoningEffort = provider_types.ReasoningEffort;
pub const ApprovalPolicy = provider_types.ApprovalPolicy;
pub const SandboxMode = provider_types.SandboxMode;
pub const ServiceTier = provider_types.ServiceTier;
pub const ApprovalDecision = provider_types.ApprovalDecision;
pub const ApprovalRequest = provider_types.ApprovalRequest;
pub const StreamDiffFile = provider_types.StreamDiffFile;
pub const StreamDiffScope = provider_types.StreamDiffScope;
pub const StreamDiffUpdate = provider_types.StreamDiffUpdate;
pub const ToolCallKind = provider_types.ToolCallKind;
pub const isSubagentToolName = provider_types.isSubagentToolName;
pub const ToolCallStatus = provider_types.ToolCallStatus;
pub const ToolCallUpdate = provider_types.ToolCallUpdate;
pub const StreamEvent = provider_types.StreamEvent;
pub const SendPromptRequest = provider_types.SendPromptRequest;
pub const SendPromptResult = provider_types.SendPromptResult;
pub const RunSlashCommandRequest = provider_types.RunSlashCommandRequest;
pub const RunSlashCommandResult = provider_types.RunSlashCommandResult;
pub const InterruptThreadRequest = provider_types.InterruptThreadRequest;
pub const SteerThreadRequest = provider_types.SteerThreadRequest;

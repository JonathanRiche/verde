//! Desktop compatibility exports for the shared remote client.

const remote = @import("verde_remote").transcript_apply;

pub const ChatEvent = remote.ChatEvent;
pub const Event = remote.Event;
pub const WorkerStatus = remote.WorkerStatus;
pub const WorkerOutcome = remote.WorkerOutcome;
pub const Outcome = remote.Outcome;
pub const FinalWorkerOutcome = remote.FinalWorkerOutcome;
pub const apply = remote.apply;
pub const applyEvents = remote.applyEvents;
pub const freeMessages = remote.freeMessages;

test {
    _ = remote;
}

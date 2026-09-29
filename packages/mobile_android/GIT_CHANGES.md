# Per-chat git changes on Android

`GitChangesClient` is the presentation boundary. `CoreGitChangesClient` adapts the
shared core selectors, intents, and operation receipts. `GitChangesBinding` supplies
a host-scoped client around the app shell and retires it on host changes.
No fixture data, daemon RPC bypass, or local git commands are used in production.

The Compose header, sheet, confirmations, snackbar, settings section, and row
markers consume this boundary. The model freezes the returned review, tracks
file/hunk selections, and keeps typed text separate from generated suggestions.
Shared, unclear, and unassigned files start unticked. File checkboxes are always
visible; tapping a row toggles whole-file selection. Independent chevrons and
Show diffs / Hide diffs control hunk previews. Changed selections discard stale
generated messages; an empty message regenerates on commit or Hide diffs. Header
quick actions commit only mine files; no-mine reviews open the sheet. Commit & push
confirms default branches holding mine files. Branch creation uses the generated suggestion when present.

## Core integration

- Map the shared git-changes selector to `GitSnapshot`, scoped to the selected
  host; clear prior host data and in-flight presentation models on host changes.
- Supply `LocalGitChangesClient` around the app shell, so thread and drawer
  markers, chat headers, and settings share one snapshot.
- Refresh on focus/foreground, chat-turn changes, and successful commits.
  Coalesce event refreshes; do not poll. Core owns journal invalidation.
- Use only core review/message/commit/push/pull-push intents and receipt outcomes.
  Message generation and commit operations need the core's long timeouts.
- One UI commit call represents one user intent. For uncertain delivery, core
  resends the same review id, consumes `in_progress`, and resolves the stored
  result. The adapter invokes `onChecking` and keeps `commit` suspended until a terminal result;
  never throw `in_progress` as a terminal failure or create a fresh review to retry.
  Android shows “Checking commit…” and keeps new mutations disabled during recovery.
  When core exposes `can_retry`, “Check again” sends `git_retry` for the original
  operation; it does not submit another commit.
- Automatically refresh reviews only for `review_expired` or
  `changed_since_review`. A refreshed review requires a new user confirmation.
- Map access from chat:write + repository:read (Chat and Full). Monitor can review
  but cannot mutate. Remote-runtime chats remain unavailable.
- Forward immutable review ids, selected roots/files/hunk indices, new_branch,
  and optional branch_name. Missing hunk lists mean whole file. Truncated/binary
  previews remain eligible for whole-file commits. Request a bounded hunk budget.
- Map status/review branch facts (default branch, upstream, ahead, behind, remote)
  and plain push. Preserve each push request_id through core recovery. Pull & push
  appears only after rejection; a rejected push preserves the successful commit.
- Read commit settings from config; paired devices cannot change them.
- Render system/git/git-commit-* transcript rows as compact commit cards, with optional subject/branch metadata and a backward-compatible one-line receipt parser.
- The sheet offers the alternate Commit / Commit & push action (push requires a remote), using the same selection-aware message generation. Footer controls wrap on phone widths and show progress on the tapped action.

Create PR remains hidden. This lane does not change daemon protocol, generated
models, or shared core. It is based on shared-core commit `2bf18894`. The updated
daemon protocol must be relaunched by the owner before live verification.

## Checks

`GitChangesTest` uses synthetic `/scratch` fixtures for selection, main-branch
confirmation, feature-branch quick commit, mixed ownership and no-mine fallback, branch
creation, uncertain-delivery presentation, rejected push, error mapping, scope
gating, settings, transcript notices, and row markers.

Run `mise run mobile-android-build` and `mise run mobile-android-test` from the
worktree root with the required build lease. After the owner's daemon
relaunch, device checks must use a scratch workspace/repository and a disposable
local bare remote only, never an owner repository or real remote.

Git results use bottom cards for progress, success (five-second dismissal), and persistent errors. Rejected pushes expose Pull & push. Commit cards parse positional subject/branch/remote lines, open validated HTTPS commit URLs, and offer Push only with write access and ahead commits. Body-keyed parsing updates the card when the daemon rewrites a receipt. Standalone push counts/upstream labels come from the pre-action status snapshot; its receipt does not supply a commit subject or SHA.

Header quick actions select only whole files owned by this chat (mine). Commit saves directly; Commit & push confirms only selected repos flagged is_default_branch. Empty reviews show No uncommitted changes; reviews without mine files open the sheet. Quick results lead with any shared/unclear files left out. Header counts subtract summary attention. Review requests retain the daemon include_unassigned=true default.

# NativeAgent architecture

NativeAgent keeps the UI, coordination, provider protocol, process ownership, workspace services, and persistence separate.

```text
SwiftUI/AppKit views
        │ actions / view state
WorkspaceViewModel (@MainActor)
   ┌────┼───────────────┐
CodexProvider       DatabaseActor       FileService / GitService
   │                         SQLite          selected workspace only
RPCClient (actor)
   │ bounded newline JSON
ProcessTransport (actor)
   │ owned stdin/stdout/stderr
provider app-server (only after Connect)
```

## Invariants

- `WorkspaceViewModel` and its main-actor `WorkspaceFeaturesController` own UI-visible state; disk work is delegated to actors.
- `ProcessTransport` owns only processes it started and never searches for or terminates unrelated processes.
- `RPCClient` serializes writes, allows at most 64 pending requests, times metadata calls out, distinguishes notifications from server requests, and does not retry mutating requests.
- `JSONLineFramer` treats read chunks as arbitrary byte chunks, preserving split UTF-8 sequences until a complete newline-delimited frame exists. Frames are limited to 16 MiB and the raw buffer to 32 MiB.
- Approval cards originate only from provider server requests. Answering a card sends exactly one response to that request ID.
- The display database is not treated as provider session truth. Remote thread IDs remain opaque and are resumed through the provider.
- SQLite writes are serialized by `DatabaseActor`; foreign keys and WAL are enabled before first use, and migration 1 is transactional.
- File previews are capped at 2 MiB by default, reject binary data, and reject paths whose resolved target leaves the selected project.
- Git commands use argument arrays and NUL-delimited status output. P0 issues read-only Git operations only.
- Explicit connection probes the executable version. Codex also generates and checks its own v2 request schemas before starting App Server. Login, account mode and model discovery must complete before native tasks are enabled.
- Claude's unmodified official program owns its interactive terminal session. A temporary invocation of this same Swift executable provides terminal I/O and the selected child environment, with API keys read from Keychain only when explicitly selected. There is no Node/Python bridge or private OAuth implementation. Native controls remain disabled until verified; historical native Claude records remain intact.
- NativeAgent removes inherited credential overrides from child environments. Shared provider credentials are never copied. Authentication/cancellation/usage-limit states do not trigger API-billing fallback.
- Pipe and RPC queues are bounded. EOF or protocol overflow closes pending requests; disconnect and app shutdown stop owned provider processes. User-opened Claude conversation windows are explicitly owned by Terminal.
- Conversation details contain provider/application facts, not inferred progress or extracted links from prose. Plan and tool lifecycle updates retain one local UUID per provider item/turn. Facts persist as typed timeline records without changing existing message identities. Shared approvals are exposed only for their active conversation.
- Prompt navigation queries UUIDs, order and 240-character excerpts, not full historical messages. Seeking verifies conversation ownership and loads at most 60 neighboring records. Geometry preferences track the visible prompt; lazy minimap rows, pointer/focus events and finite animations do no idle polling. Reduce Motion disables the new animations.

## State and recovery

Turns use explicit `idle`, `starting`, `running`, `awaitingApproval`, `awaitingUserInput`, `interrupting`, `completed`, `interrupted`, `failed`, and `stateUnknown` states. Connection state is separate. A failed connection or interruption is reported without silently retrying mutating actions; a provider failure does not imply its commands had no effect. Sending claims the active-turn state before suspension. Chat-creation requests and timeline writes each have an ordered task chain, and selection generations discard stale asynchronous navigation results.

Projects and group metadata are restored from SQLite; chat metadata is requested in indexed 50-row pages. Conversation selection restores the latest 40 timeline entries and its draft. Older history loads in 40-row pages with a 200-entry memory window. SQLite returns 8,000-character previews; full text is loaded separately on request. Streaming UI deltas are coalesced to 10 Hz (about 3 Hz under power/thermal constraints), with ordered one-second persistence checkpoints and immediate final saves.

Local conversation identity is independent of provider identity. The current remote session belongs to exactly one provider. A provider change creates a fresh session with an explicit, bounded visible-history handoff; a same-provider model change keeps the session. No hidden reasoning or provider credentials are read for this handoff.

Schema migration 4 adds nullable `archived_at` and archive/pagination indices transactionally. Migration 6 adds a persisted `stored_bytes` counter per conversation, backfills existing payload sizes inside SQLite, and maintains counters with explicit insert/update/delete triggers. Archive rows read metadata and counters only, using archive-date keyset pages and database search/date predicates. Backup validation accepts versions 5–6 and permits only the exact known accounting triggers in version 6.

Recovery normally lasts 30 days. When more than 30 unexpired chats are archived, the oldest excess chats with at least 10 MiB of stored content expire after 20 days. Listing, counts, restore checks, and cleanup use the same candidate subset; this size rule stops at 30 remaining archives. Manual deletion requires a row still to be archived. Purging cascades timeline, drafts, turns, and feature records and explicitly removes related context, approval, and attachment metadata in a transaction. SQLite secure-delete is enabled, but original files, backups, and provider-side data remain outside the archive’s scope. Maintenance runs in bounded transactions on startup, archive opening, archiving, and hourly; queries never load full histories or perform a whole-database vacuum. Freed pages remain reusable without immediately shrinking the file.

## UI composition

- Left: remembered projects and project conversations.
- Center: typed timeline, real approvals, streaming output, draft-aware composer, and bounded diagnostics.
- Right: lazy file tree, AppKit code preview with line numbers, Git status, and unified diff.
- Toolbar: selected project, discovered model, connection state, connect/disconnect, and the conversation-details popover.
- Conversation right edge: a prompt navigation rail with distance-based hover sizing and keyboard navigation.

The app uses system fonts/colors, selectable text, native controls, dark mode, keyboard shortcuts, and status labels that do not rely on color alone.

## Workspace tools

The toolbar tools menu and Command-K palette share `WorkspaceCommand`. Native panels provide an account/usage dashboard, project profiles, editable global/project templates, explicit next-request context, serial tasks, completion reports, change comparisons, and paged local search. Project and recent-chat switching are available in the palette; older records remain reachable through global search.

Migration 5 adds scoped, indexed `feature_records` in a transaction. Profiles, templates, queue snapshots, reports, checkpoints, branches, per-conversation context and session state use typed Codable payloads. Existing project, conversation, draft and provider-session IDs are preserved. Foreign keys cascade conversation-owned feature data when a chat is permanently purged.

Queue execution is explicitly started and serial. A task captures project, provider authentication method/runtime profile, model, effective settings and selected context. It creates a separate conversation/session, uses the existing trust/send/approval path, and does not launch another task while a decision is pending. Failures and unknown states pause execution; restored active tasks become `needsReview`, never automatically retried. Provider account credentials are not duplicated in queue records.

Branching creates a new local ID with no reused remote session. The editable earlier prompt is saved separately; up to 24 prior messages, truncated to 2,000 characters each, are attached as clearly labeled selected context. Native provider forking is not asserted by this integration.

Task reports distinguish provider summaries, command output/exit codes, provider-reported changes, proposals, and byte changes observed between bounded checkpoints. A configured test is verified only by an exactly matching command event with an actual exit code. Reports can be copied/exported as Markdown. Report list queries retrieve summaries, not command bodies; full reports/checkpoints load on selection.

Rollback is per existing text file, against the exact pre-task bytes (including pre-existing edits). `NSFileCoordinator` coordinates replacement, paths reject symlinks/escapes, and current bytes/hash must equal the saved post-task bytes. Conflicts, missing baselines and deleted/binary/new files require manual review. No reset or untracked-file deletion occurs. External programs that ignore file coordination can still race filesystem operations; keep external writers stopped during rollback.

`UNUserNotificationCenter` is opt-in, with per-event preferences, foreground suppression, bounded deduplication, and conversation/task deep links. Question cards originate only from provider requests; Codex answers require a matching runtime-generated response schema. Unverified question requests are rejected without guessed responses and pause the queue. Secret answers are not written to local conversation/report history. Notification delivery/permission depends on running the app bundle and macOS settings.

Session saves are event-driven/debounced and also flushed on shutdown. Drafts, selection, file, inspector, feature panel, reading marker and AppKit window frame restore without starting tasks. Optional reconnect is asynchronous. Interrupted task state remains unknown until reviewed; reconnect does not claim that a task completed.

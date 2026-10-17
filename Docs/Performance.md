# Performance record

Date: 2026-10-11

## Build host

- Architecture: x86_64
- macOS SDK: 26.4
- Xcode: 26.4.1
- Swift: 6.3.1
- Deployment target: macOS 14

## Enforced resource bounds

| Resource | Bound |
|---|---:|
| One provider frame | 16 MiB |
| Raw provider input buffer | 32 MiB |
| Concurrent pending RPCs | 64 |
| Displayed command output | 2 MiB per entry |
| Direct file preview | 2 MiB |
| Git command output | 8 MiB |
| Chat library page | 50 metadata rows per group / search / archive page |
| Initially restored timeline | 40 entries |
| Older-history page | 40 entries |
| Retained timeline window | 200 entries |
| Initial text per stored timeline entry | 8,000 characters; full text on demand |
| Cross-provider context | 24 visible messages, 2,000 characters each |
| Streaming UI flush interval | 100 ms; 300 ms in Low Power Mode / serious or critical thermal state |
| Streaming database checkpoint | At most once per second during deltas, plus immediate final save |
| Archive purge transaction | At most 100 chats per maintenance batch |
| Large archived chat retention | 20 days for at least 10 MiB stored content while more than 30 unexpired archived chats remain; otherwise 30 days |
| Archive size lookup | Persisted per-chat byte counter; listing/search does not read message or attachment bodies |
| Retained diagnostic messages | 100 |
| Active P0 provider processes | 1 |
| Explicit context | 24 items / 1 MiB copied text total |
| Task rollback checkpoint | 128 existing text files; 1 MiB each / 8 MiB total baseline |
| Task report | 200 commands (24,000 output characters each), 200 changes/proposals, 24,000-character summary |
| Task report list | 30 summary-only rows per page |
| Task queue | 200 saved tasks, serial execution |
| Global feature search | 40 results/page, 200 ms debounce, SQLite cancellation progress handler |
| Project-content search | Separate mode; 2,000 candidate files, 1 MiB each, hidden/generated/dependency paths excluded |
| Report event checkpoint | Coalesced to one second, immediate completion save |
| Code highlighting | Background lexical pass, capped at 50,000 tokens; stale work is cancelled |
| File tabs | Text loaded for the selected preview; other tabs retain path, selection and viewport metadata |
| GitHub lists | 50 repositories per page, 100 commits and 100 open pull requests per refresh |
| AI review | At most two simultaneous requests; 180 KB input limit, no automatic provider request |
| Saved-answer comparison | Latest 200 messages plus loaded timeline; 2–6 selected answers, 160 KB combined limit |
| Storage listing | 50 metadata rows per page; upcoming deletion preview capped at 20 chats |
| Managed-file inventory | 10,000 inspected entries with a partial-results notice at the limit |

The GitHub workspace refreshes on explicit actions and project selection, with no background polling. Commands drain both output streams concurrently and enforce output limits, cancellation and timeouts. Storage statistics use persisted chat sizes; attachment totals are scanned in batches that yield between queries. Backup and cache cleanup only traverses the app's known directories. Neither opening the storage manager nor reviewing GitHub changes sends content to an AI provider.

The provider starts through account/connection/model selection or the once-per-launch saved-account connection below. Browsing history does not itself start a provider. File/Git scans are deferred until the inspector opens, cached for the selected project, and Git refreshes once at turn completion rather than on every file-change event. Search is debounced by 250 ms. List pages use indexed keyset cursors rather than offsets. History uses indexed received-order cursors. Large-message expansion uses a native text viewport with noncontiguous layout. Library metadata pages accumulate only as requested; timeline payloads remain windowed.

Automatic connection is enabled by default and can be disabled in Configuration. It attempts the selected saved authorization once per launch; it never starts sign-in or resends work. Restored backups stay offline for review. History opens newest-first; user scrolling near a window boundary fetches one 40-entry page, with static skeletons only while loading. The 200-entry window evicts the opposite edge and supports paging back in either direction. The minimap fetch is bounded to the latest 200 short prompt previews, augmented by the loaded window. Starting a native task additionally captures a bounded rollback baseline on `TaskFileService`, then compares it at completion. Global feature search uses paged SQL offsets (unlike the existing chat-library keyset cursors); full-text matching remains a scan and can become slower on very large databases. Superseded SQL scans are interrupted. New controls have no idle animation, filesystem watcher, or polling process.

## Measurements

- Debug offline SQLite fixture, 10,000 messages: two 40-row pages in approximately 0.6 ms.
- Debug offline SQLite fixture, 10,000 chats: two 50-row pages and two title searches in approximately 8.7 ms.
- These are local warm-database query measurements from the 2026-10-11 test run, not end-to-end UI latency, cold-start benchmarks, temperature measurements, or performance guarantees.

`Scripts/build-release.sh` produces the optimized app bundle and reports its size. UI startup, idle CPU/RAM, provider-process RAM, and time-to-first-provider-output require launching the graphical app and, for provider totals, an authenticated turn. They are deliberately marked unmeasured until those actions are authorized and performed; no target value is reported as an observed value.

Use Instruments with a Release build and record these separately:

1. NativeAgent from launch until the window accepts input.
2. NativeAgent for 60 seconds idle with one project and no connection.
3. Provider child process after Connect but before a turn.
4. NativeAgent and the child process during a two-minute streaming turn.
5. Any compiler/test subprocesses separately from both.

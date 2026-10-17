# NativeAgent

NativeAgent is a native macOS client for local coding-agent runtimes. It is written in Swift and SwiftUI, uses AppKit for large selectable code views, stores local UI history in SQLite, and does not include a cloud backend.

## Requirements

- macOS 14 or later
- Xcode 16 or later (validated here with Xcode 26.4.1)
- An agent provider executable only when you choose to connect one

The app never starts a provider at launch. **ChatGPT account sign-in opens the default browser directly**, using NativeAgent's own OAuth registration, loopback callback and Keychain credentials. Chat uses native HTTPS Responses streaming; it never launches Codex. Independent Claude/Grok subscription authorization is not configured, so their account buttons cannot launch a CLI. The separately selected, legacy API-key integrations still require their respective command-line runtimes.

## Build and run

Open `Package.swift` in Xcode, select the `NativeAgent` scheme, and run it. The Swift package is the Xcode project definition, so no project generator or third-party package manager is required.

From Terminal:

```sh
swift build
swift test
swift run NativeAgent
```

To create a local release app bundle without launching it:

```sh
./Scripts/build-release.sh
```

The result is `.build/release/NativeAgent.app`. Local builds are ad-hoc signed unless a Developer ID identity is supplied.

## Publishing updates

Releases are built and signed on the maintainer's Mac. Apple and Sparkle private keys never go to GitHub Actions. After incrementing `CFBundleVersion` in `NativeAgent/Resources/Info.plist` and committing on `main`, run:

```sh
bash Scripts/publish-release.sh --publish
```

This tests a committed snapshot, builds for Apple Silicon and Intel, Developer ID-signs, notarizes and staples the app, signs the archive/feed with Sparkle, pushes source and a version tag, and publishes a GitHub release. GitHub Actions verifies the public signatures and deploys the update site/feed to Pages. Ordinary pushes run tests only.

Use `--check` for preflight or `--dry-run` to complete signing and Apple notarization without publishing to GitHub. See [Releasing.md](Docs/Releasing.md) for one-time setup and recovery.

## First use

Download the `.dmg` from [GitHub Pages](https://phoenix1485.github.io/NativeAgent/), double-click it, and drag NativeAgent onto the Applications shortcut. Launch it from Applications, then eject the disk image. If replacing an older app, quit it first and choose Replace; chats and settings are kept. Future releases install through Settings → Updates, without another manual download. The ZIP release asset is only for the automatic updater.

1. In welcome setup, choose **ChatGPT → Account sign-in**. No executable is required.
2. Choose **Continue with ChatGPT**, authorize NativeAgent in the browser, and return to the app. Saved registrations appear in the account picker; select **Add another account or workspace** for a new registration. **Reconnect saved account** uses only NativeAgent's saved session. Provider eligibility applies; sign-in is not proof of commercial distribution approval. API billing is never selected automatically.
3. Under **Models**, enable/disable models, star favorites, choose the default, and select supported thinking levels for native providers. Codex discovers its catalog; Grok publishes its session catalog after a workspace session is created. Claude models are chosen using **/model** in the official terminal. A listed model does not prove entitlement.
4. Set workspace access and custom instructions in **Configuration**, then choose a theme, accent color, message size, and timestamps in **Appearance**. You can skip setup and return through **Settings** (`⌘,`); **Configuration → Run welcome setup again** reopens it.
5. Create a standalone chat with **New chat** (`⌘N`), or a group with **+** next to **Groups**. Choose a working folder (`⌘O`) for coding-runtime tasks. Saved accounts connect automatically on launch unless disabled in Configuration.
6. For native providers, choose a model in the composer, enter a task, and send it with `⌘Return`. Favorites sort first; disabled models cannot be used. New chats use the saved default. `⌘.` requests interruption. You can create multiple independent chats; only one native provider turn runs at a time. For Claude, open its official terminal as described below.

Claude Code uses a clearly identified **official Terminal session** until native interactive controls are verified against a working installed version. Choose a folder and press **Open Claude Code**; use its own model selection, permissions, /resume and Ctrl-C. Terminal conversations are separate from NativeAgent's local timeline, and existing drafts/history are preserved. Codex uses sandboxing and native approval requests. Grok uses ACP permission requests; **Read only** requires an advertised plan mode. Switching providers never sends an existing provider's thread ID to a different runtime.

Direct ChatGPT supports text chat, image/PDF inputs, reviewed edits to permitted text attachments, trusted local MCP tools and rolling conversation memory. Recent messages use a 24-message / 48,000-character window; older user/assistant messages are summarized chronologically using the selected model. The summary is lossy, saved locally and never replaces original messages. It has no general shell access and does not claim native remote thread resume. Models come from the account-specific catalog. Cancel closes the local listener; sign-in expires after five minutes. Disconnect preserves NativeAgent's authorization; sign-out attempts session revocation and clears its tokens without touching Codex. Account settings link to ChatGPT for plan details; percentages are never invented. The runtime-specific controls described above apply only to the explicit legacy API-key connections.

## API connections and multiple AIs

**Settings → API connections** stores up to ten API tokens in device-only Keychain entries, including legacy keys saved in Accounts. Account sign-ins do not consume API-token slots. Add a provider name, HTTPS API base URL, exact model ID and token. Presets cover OpenAI, Claude, Grok and DeepSeek; custom endpoints must support OpenAI-compatible Chat Completions or Anthropic Messages. Saving a connection does not send a test request or prove entitlement. Changing the destination requires entering its token again.

Type `@` at the end of the draft, or click **@** above the text editor. Select one AI for a reply or several for independent, labeled reviews in the same chat. The menu also offers attachments, read-only plan mode and templates. Click Done to return to your question. Review recipients and destinations in the confirmation before sending. Each receives up to 24 recent visible text messages (2,000 characters each), the prompt, pinned instructions, and explicit text attachments. This mode does not send images/PDFs, execute API tools, summarize the entire history, or automatically synthesize a consensus. API billing applies separately. At most two requests run concurrently; failures remain visible per AI and are never automatically retried. Stop cancels pending requests; a remote provider may still bill already-started work.

ChatGPT accounts use NativeAgent’s existing browser authorization. Grok account sign-in uses the installed official Grok Build runtime; reviews require its advertised read-only plan mode and a trusted chosen folder, which the runtime may read. Runtime permission requests are denied during review. Claude subscription sign-in remains in unmodified Claude Code and its Terminal conversation; it is **not** a Claude.ai OAuth integration in NativeAgent’s shared chat. Add a Claude API connection for Claude replies alongside the other AIs. See [provider compatibility](Docs/ProviderCompatibility.md) for sources and limitations.

## Agents

**Settings → Agents** includes ChatGPT, Claude, Grok, Planner, Code reviewer and Writer presets. These are editable NativeAgent specialists, not imported GPTs or Claude projects. Create or duplicate an agent, choose its saved account/API connection and optional model override, then configure its instructions, response style, reference text and context-sharing preferences. Claude agents require a Claude API connection; the separate Claude Code Terminal session is not used. Grok runtime agents additionally require explicit project-read permission and a trusted folder.

Use **@ → Agents** or type `@handle` in a prompt. A checked chip confirms an accepted, connected agent; unavailable agents show a setup message and block sending. Mentions persist with the draft and can be removed using their chips. Up to six agents/AIs can answer a request, with separately labeled replies and at most two concurrent requests. Reference files are imported as text snapshots, not continuously watched files. Agent profiles can be exported/imported as JSON without credentials; imports start disabled and mention-only. Profiles are separate from chat backups.

The main direct ChatGPT assistant can also call configured agents through its `delegate_agent` tool. Each profile supports **Mention only**, **Ask before delegating** (default), or **Automatic**. The global switch and per-turn limit (1–6, default 3) control delegation. Automatic mode authorizes sending model-selected tasks to that agent without another approval; tasks can contain context supplied by the main assistant even when automatic history/attachment sharing is off. Calls appear in tool activity and provider-reported tokens are recorded under the agent handle in Usage. Other tools retain their existing approvals.

Specialists return text advice using the selected connection. They do not independently edit files, run shell/MCP tools, or delegate recursively. Automatic delegation is available only in direct ChatGPT turns; other supported connections can answer explicit mentions. API charges remain separate, and stopping a request cannot undo work already accepted by a provider.

## Token usage and context

**Settings → Usage** shows locally recorded tokens for today, the past 7, 30 or 90 calendar days, all time, or a custom date range. Filter by provider and model, inspect daily input/output charts and provider/model/chat/activity breakdowns, page through recent requests, or export the filtered history as CSV. The dashboard uses your selected accent color.

Tracking begins with version 0.12.0. Counts come from provider responses, including direct ChatGPT tool follow-ups, title suggestions, memory summaries, API chat and AI reviews. Cache reads/writes are included in input; reasoning is included in output, so neither is added twice. The selected chat shows its latest reported context snapshot, or its last request's input when only that is available. Context limits appear only when reported. Provider plan quotas remain separate from token totals.

Earlier history, usage in other apps, and Claude Code Terminal sessions cannot be imported as account-wide totals. Missing counts are labeled **Not reported**, including canceled requests whose counters never arrived; a reported zero remains distinct. Model labels identify the model selected for the request. The local ledger stores counts and request metadata, never prompts or credentials, and remains after chats are deleted. Library backups include the ledger; restoring a backup restores usage to that snapshot.

## CLI and model update checks

**Settings → Updates → CLI & model updates** checks at every app launch and at **:00 and :30 of each hour** in your Mac's local time. The setting is on by default and can be disabled. **Check now** runs the same checks immediately without shifting the schedule. While the Mac is asleep or the app is closed, checks do not run; waking an open app performs one catch-up check and resumes the next clock boundary. Clock and time-zone changes recalculate the schedule.

Claude Code and Grok Build checks read known installation metadata first, falling back to a bounded version-only command with automatic updater behavior disabled. The checker compares that version with the provider's public release feed and shows installed/latest versions, errors, last-check time and update-guide links. It never launches Codex or installs software. Use the provider's own updater or package manager, then reconnect. Managed or stable-channel installations may intentionally differ from the newest release.

The same check refreshes the model catalog of an active direct ChatGPT connection. Refreshes wait for active work to finish, preserve model preferences and keep the previous catalog on failure. CLI upgrades do not grant model access: Claude selects account models in its Terminal session, Grok publishes models when a workspace session starts, and custom API model IDs remain in API connections.

## Files and MCP plugins

- The Files toolbar offers syntax highlighting, 9–28 pt text, line wrapping, and **Go to line** (⌘L). Open files have individual tabs that keep their scroll position and selection while switching. **Quick Open** (⌘P) searches filenames and paths.
- **Chat + code** keeps the conversation beside a resizable file view. **Open in separate window** provides another native window with the same file tabs and navigator, and its own scroll position.
- Select code and use its actions menu to explain, review, refactor, or propose tests/documentation with configured AI connections. Review the exact excerpt and recipients before sending; suggested code is not automatically saved.

- **Files → Open in tab** opens a wide, resizable code view with the file navigator on the right. Switch between **Chat** and **Files** without closing either tab. Search matches names and paths inside collapsed folders; the file-type menu filters code, documents, or images. **Find** (or `⌘F` while the code view is focused) searches within the open file. File search skips hidden/generated folders and symbolic links, with an explicit partial-results notice for large or unreadable projects.
- **Attach** in the composer, or drop local files onto it. Up to 24 context items: UTF-8 text/code (1 MiB total) plus PNG/JPEG/WebP/non-animated GIF and unlocked PDFs (8 MiB each, 12 MiB media total; PDFs 1–50 pages, images up to 40 megapixels). Media has native previews and is sent as inline binary input through direct ChatGPT, subject to the selected model's support. Other connections reject media explicitly. No Files upload API is used. Files may be outside the workspace when explicitly selected. Snapshots persist with the conversation and are sent with subsequent messages until removed; changes on disk require a refreshed attachment.
- Click an attachment to preview or edit it. **Edit…** in the workspace file browser also opens the complete file (never a truncated preview). **Save file** writes explicitly, checks the original bytes, rejects symlink swaps/concurrent changes, and preserves file mode. Unsaved changes prevent an updater restart and prompt on quit.
- To let ChatGPT edit an attached file, enable **Allow AI edits** in that attachment's menu and choose **Configuration → Workspace edits**. Every exact text replacement still requires **Allow once** after reviewing the original/replacement. No permission to other paths, arbitrary shell commands, creation or deletion is granted. Other provider integrations do not receive these NativeAgent tools.
- **Settings → Plugins**, or **Plugins** beside the composer, manages installed local MCP stdio servers. Supply an absolute executable and a JSON array of arguments. Configurations persist, connections do not; explicitly trust/start each server after launch. This is not a sandbox: the program has your Mac user rights and may act on startup. NativeAgent passes a minimal environment, not inherited provider/API tokens. Do not put secrets in the plain-text configuration. Remote HTTP/OAuth, resource browsing and prompts are not implemented in this release.
- Connected MCP tools are supplied to direct ChatGPT requests in the documented SIWC function-tool namespace. Every tool invocation shows the server, tool and exact arguments for approval. Read-only workspace mode does **not** restrict third-party server code. Calls are bounded, never automatically retried, and interrupted/failed calls can have side effects already; review before retrying. Actual results and referenced tool output appear in conversation details.
- The bottom of the Settings sidebar always shows the installed app version and build number, **Check for Updates…**, and a **Download on GitHub Pages** link. The chat header’s three-dot menu also includes update and download actions. Automatic checks/downloads remain user-controlled in the app menu. Signed updates are checked on launch when the last check is at least 15 minutes old, then by Sparkle's hourly schedule while running. The in-app updater replaces the existing app bundle; users should not download every ZIP manually, which can make Archive Utility create `NativeAgent 2.app`. Installation waits for active tasks, file saves and unsaved editor changes. Offline/closed apps cannot be guaranteed the latest version. New releases still require local signing; a source push alone cannot sign an update with a key that remains on your Mac.

Protocol references: [SIWC limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations), [Responses function namespaces](https://developers.openai.com/api/docs/guides/function-calling), [MCP stdio lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle). The client negotiates MCP 2025-06-18, 2025-03-26 or 2024-11-05. Tests use offline HTTP and stdio fixtures; they do not establish live account/model compatibility.

The first turn in each project requires an explicit trust confirmation because repositories may contain agent instructions, hooks, and executable configuration.

## GitHub workspace

Open the GitHub button in the workspace toolbar, **Agent → GitHub workspace**, or **Settings → GitHub**. Install the [official GitHub CLI](https://cli.github.com/) if needed; NativeAgent finds Homebrew's usual locations or lets you choose the **gh** executable. **Sign in with GitHub** opens GitHub's device authorization page and displays the one-time code. This uses GitHub CLI's account and credential storage, shared with other clients of that CLI. NativeAgent does not ask for or expose a GitHub token; the connection screen reports whether CLI credentials are in Keychain.

- Browse repositories with paging, clone into a new local folder, create a new project, or publish an existing folder. New repositories default to private. Creating/publishing links the local folder and remote; it does not automatically stage, commit or upload files.
- **Changes** shows working/staged files, diffs, individual stage/unstage controls, and a commit-message editor. Review and commit locally, then explicitly **Push**. **Fetch** updates remote references; **Pull** permits only fast-forward updates from the tracking branch.
- **History** shows recent commits and their diffs. **Branches** creates/switches branches, compares local or fetched remote references, and merges into the current branch. A local merge requires a clean working tree; conflicts stay visible until resolved and committed or explicitly aborted.
- **Pull requests** lists open requests, shows their diffs, creates draft or ready requests from pushed branches, and merges after confirmation. GitHub branch rules apply; merging is bound to the reviewed head commit. No force push, automatic reset, or administrator override is provided.
- **Ask AI** reviews the displayed diff, explains merge risks, or drafts a commit message/pull-request description. Choose connected ChatGPT/Grok accounts or configured Claude, OpenAI-compatible, and custom APIs. AI receives the displayed source after you choose Send; GitHub credentials are never included. Suggestions do not execute repository operations. Claude account-only sessions remain in official Terminal; add a Claude API connection for these integrated reviews.

Repository commands use bounded, cancellable processes. A canceled network operation may already have completed remotely; refresh before retrying. GitHub authentication failure does not hide local status/history. Only github.com account operations are supported in this version.

## Bookmarks, answer comparison and storage

- Use the bookmark icon on a completed message to save a label. **Agent → Message bookmarks** searches labels/excerpts, edits labels, and jumps to the original message. An archived chat must be restored to open it; permanently deleting a chat also deletes its bookmarks.
- **Agent → Compare AI answers** or a reply's context menu opens saved answers side by side. Choose two to six and optionally ask selected AIs to combine them or identify disagreements. The comparison lists the latest 200 messages plus answers in the currently loaded history; full selected text is loaded on request. Oversized inputs are rejected rather than silently shortened.
- **Settings → Storage** or **Agent → Storage manager** shows chat payloads, attachment payloads, database size, backups and caches. Sort/filter chats, archive selected active chats, or permanently delete selected archived chats after confirmation. The open chat and running chats are protected. The upcoming-deletions list shows conditional archive eligibility dates.
- Backup/cache cleanup selects individual files in the app's own storage. Changed files and symbolic links are rejected. Attachment payload size is already included in chat size; SQLite free pages may be reused without immediately reducing the database file.

## Memory, retries, backups and updates (0.7)

- **Chat menu → Chat memory and pinned instructions** lets you inspect/reset the rolling summary and save up to 8,000 characters of exact instructions sent on every request. Summarization uses the connected model and its allowance. It covers saved user/assistant text, not unseen terminal sessions or tool output.
- **Project profile → Project memory** stores frameworks, conventions, goals, decisions and things to avoid. Each field allows 4,000 characters. Save memory separately from profile defaults; it takes effect on the next request in existing and new chats using that project. Empty fields forget those preferences. Memory never grants tool permissions.
- User messages have **Edit & resend**; assistant replies have **Regenerate in new branch**; errors have **Retry in new branch**. These prepare a new chat with full earlier user/assistant text and the selected prompt as a draft. Review its current attachments and press Send. Originals are unchanged, file-edit permission is reset, and previous external actions are not undone or automatically repeated.
- **Settings → Configuration → Library backups** enables daily local snapshots (on by default), manual backups, Finder access and restore. Seven daily copies are retained; manual/pre-restore copies stay until removed. A verified restore is staged for next launch and creates a safety backup first. Restored remote sessions are cleared and reconnect is disabled. Backups include conversation/project data but not Keychain credentials; they are not encrypted. Chat actions offer complete user/assistant-message **Markdown** and **PDF** exports (not embedded attachments or tool activity).
- Chat actions include **Pin chat**; pinned chats appear in their own section. Unread replies survive relaunch and clear when the latest chat history is opened. The active chat shows a working indicator even while another chat is selected.
- **Settings → Updates** shows version/build, last check, truthful status, actual download progress when Sparkle supplies byte counts, retryable errors and **What’s New**. Release highlights appear once per installed build and can always be reopened. Signed updates replace the existing app in place.

## Groups and folders

Create a group from the sidebar and optionally associate it with a local parent folder. Select the group to add chats and nested folders. Nested folders inherit the parent's working folder; use **Edit group** or the folder picker when creating a child to select a different subdirectory. The system folder picker also supports creating a new directory.

Use **New chat** in the main sidebar for standalone chats, or **New chat** in a group's overview for chats inside that group. Right-click a chat to rename it or move it to any group or back to **Standalone chats**. You can also drag a chat onto a group. Groups can be renamed, moved, and removed when empty. Moving an existing chat preserves its working directory and history.

Groups, nesting, chat locations, and drafts persist across restarts. Migration 2 preserves existing project chats and creates a consistent SQLite backup named `NativeAgent.before-library-v2.sqlite3` before migrating the library. Sidebar search queries chat titles throughout the database, including unloaded chats, and filters group names. The right-hand files/changes inspector is optional; at narrow widths it temporarily replaces the sidebar to keep the conversation usable. Files and Git status are loaded only when the inspector is opened.

Hover over a chat's three dots to open its actions. The popup closes when the pointer leaves that row and its popup; moving over a title alone does not open it. Long titles truncate with an ellipsis and a soft fade, then scroll continuously while hovered (unless Reduce Motion is enabled). Choose **Rename…** to edit the name inline, with the current title as the placeholder. **Suggest name with AI** requires at least **five saved user messages in that chat**; assistant replies and tool output do not count. The inline editor shows the current count when below the minimum; manual renaming has no message minimum. AI naming uses the connected ChatGPT model and saved user/assistant messages across the conversation, summarizing long histories in chunks. The suggestion remains editable until **Save**; Cancel/Escape discards it. Naming requests do not add chat messages or run tools. Messages in separate provider terminals that were never captured locally are unavailable to the title generator.

## Switch models in the same chat

The composer’s model menu includes enabled models from native providers, with favorites marked by stars, plus an entry for the official Claude Code terminal. Switch between turns; stop an active turn first. Same-provider model changes reuse that provider’s remote session. Changing native providers starts a new provider session while preserving the local chat, title, folder, draft, and full local history. No foreign provider’s session ID is reused. Claude terminal sessions manage their own model and history in the official program.

On the next send after changing to a legacy provider, a bounded excerpt of up to 24 recent visible user/assistant messages (up to 2,000 characters each) accompanies your new message; older context and long-message tails can be omitted. Direct ChatGPT uses the rolling summary plus recent-message window described above. Chat pins and current project memory accompany every request. Command output, hidden reasoning, and runtime credentials are not included automatically. Switching back starts a fresh provider session with local context. Account/model access remains subject to each provider’s entitlement rules.

## Conversation details and prompt navigation

The clipboard-list button at the top right opens **Conversation details**. Progress shows the current task state, provider-reported plans and tool lifecycles, and pending approvals for this conversation. Results contains recorded file changes and responses; click an entry to read the stored output/diff, preview a file inside the working folder, or jump to its timeline entry. Sources contains only explicit provider references (read actions, image views, opened web pages) and recent-chat context actually sent by NativeAgent. A search query or a link mentioned in prose is not proof that a source was used. Older conversations may have no source records. Historical status is labeled “Last reported,” not presented as a live task.

The right-edge **prompt minimap** shows the latest 200 user prompts plus prompts in the currently loaded history window. Hover to magnify a bar and its neighbors and read a short preview; click to jump to the original message. The accent marker tracks the visible conversation position. Older prompts become available as you scroll up through history. Focus the rail and use Up/Down to choose a prompt, Return to jump, and Escape to dismiss its preview. Individual prompt buttons also have accessible labels. Motion respects macOS Reduce Motion, and no animation timer or polling runs while idle.

Prompt navigation loads only short excerpts plus stable database IDs. Jumping outside loaded history fetches a bounded message window. The details popover initially shows up to 200 recent saved records plus the current history window; older records remain available by navigating earlier history. It does not scan repository files to invent results or capture separate Claude terminal sessions.

Provider event mapping follows the [official App Server event documentation](https://learn.chatgpt.com/docs/app-server); missing fields or unsupported events remain unavailable rather than being estimated.

## Archive and recovery

Right-click a chat and choose **Archive chat**. Open **Archive** at the bottom of the sidebar to restore it, including its group, messages, and unsent draft. Stop any active turn in that chat before archiving. The archive follows your selected appearance/accent, searches titles across all archived chats, and filters by the date they were archived (including an inclusive custom date range). The trash button permanently deletes one chosen archived chat after confirmation, without waiting for its recovery period to end.

Recovery normally expires exactly 30 × 24 hours after archiving. If more than 30 unexpired chats are archived, the oldest chats containing at least 10 MiB (10,485,760 bytes) of stored content expire after 20 × 24 hours, only until 30 archived chats remain. Smaller and newer chats keep their normal recovery period. Stored size counts saved text, metadata, drafts, and conversation feature payloads (including attachment snapshots); it excludes SQLite page/index overhead and original files referenced on disk. Expired chats are hidden and cannot be restored. Cleanup permanently removes local conversation records on launch, when opening Archive, after archiving, and hourly while the app remains open, in small transactions. If the app is closed or the Mac is asleep, cleanup resumes when it next runs. Original workspace files, provider-managed sessions, and backups are kept separately. Freed database pages are reused; cleanup does not guarantee immediate shrinkage of the database file or forensic erasure.

## Large libraries and long chats

The sidebar loads 50 chats per page, with each group loaded on demand. Use **Load older chats** for another page or search for an unloaded chat directly. Opening or restoring a conversation loads its latest 40 entries with skeleton placeholders while waiting. Scrolling near the top loads 40 older entries; scrolling down reloads newer entries evicted from the bounded 200-entry window. Layout changes do not trigger eager page loading. Accessible load buttons and **Latest messages** remain available. Long message bodies initially use 8,000-character previews; full text loads only when requested. Stored history is not discarded by these display limits.

The selected account connects automatically once per launch when saved authorization exists. Disable this in **Settings → Configuration** if desired. An explicit Disconnect keeps the current session offline; invalid or expired authorization may still need manual sign-in. Startup never opens a login browser, sends a prompt, or resumes interrupted tasks. The first launch after restoring a database backup stays offline for review.

Large messages initially show an 8,000-character preview. **Show full message** loads that message into a bounded native scrolling text view; collapsing it releases the expanded text. Streaming is batched, database writes are serialized and throttled, and UI refreshes slow down under Low Power Mode or serious thermal pressure. These measures reduce app work; they cannot guarantee laptop temperature or control a provider’s own workload.

## Local data and safety

- App metadata and display history: `~/Library/Application Support/NativeAgent/NativeAgent.sqlite3`
- NativeAgent's ChatGPT access, refresh and ID tokens are stored in a separate device-only Keychain entry, never in UserDefaults, SQLite, logs or process arguments. No Codex/Claude credential files are read. API keys use a different Keychain service; legacy runtimes may also retain explicitly supplied API credentials.
- Account labels in Settings are last-known status until the provider confirms the current connection. Sign-out is confirmed because it affects other clients sharing the official runtime's account. Removing a Keychain key does not revoke it at the provider or delete a copy already managed by a runtime.
- Account and API-key modes are distinct: an existing Codex API-key login is not silently accepted as a ChatGPT account subscription.
- Files are previewed only inside the chosen project. Escaping symbolic links are rejected.
- Git integration is read-only in P0. NativeAgent never resets, stashes, stages, commits, or pushes user work.
- Timeline, transport frames, file previews, Git output, and command output have explicit size limits.

## Verification

The offline test suite covers framing, UTF-8 boundaries, oversized input, SQLite migrations and provider namespaces, preference persistence, model selection, credential isolation, provider request payloads, process-output draining, path safety, staged/unstaged Git state, cross-provider conversation handoffs, rapid chat creation, streaming write ordering, archive expiry and recovery, and 10,000-chat/10,000-message fixtures. Set `NATIVEAGENT_SNAPSHOT_DIR` to an output directory when running `swift test --disable-sandbox` to render the actual SwiftUI workspace, archive, welcome screen, and settings panels with mock data and credentials. See [ProviderCompatibility.md](Docs/ProviderCompatibility.md) for the deliberately separate authenticated provider acceptance status.

Architecture details are in [Architecture.md](Docs/Architecture.md), and measurements are recorded in [Performance.md](Docs/Performance.md).

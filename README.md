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

1. In welcome setup, choose **ChatGPT → Account sign-in**. No executable is required.
2. Choose **Continue with ChatGPT**, authorize NativeAgent in the browser, and return to the app. Saved registrations appear in the account picker; select **Add another account or workspace** for a new registration. **Reconnect saved account** uses only NativeAgent's saved session. Provider eligibility applies; sign-in is not proof of commercial distribution approval. API billing is never selected automatically.
3. Under **Models**, enable/disable models, star favorites, choose the default, and select supported thinking levels for native providers. Codex discovers its catalog; Grok publishes its session catalog after a workspace session is created. Claude models are chosen using **/model** in the official terminal. A listed model does not prove entitlement.
4. Set workspace access and custom instructions in **Configuration**, then choose a theme, accent color, message size, and timestamps in **Appearance**. You can skip setup and return through **Settings** (`⌘,`); **Configuration → Run welcome setup again** reopens it.
5. Create a standalone chat with **New chat** (`⌘N`), or a group with **+** next to **Groups**. Choose a working folder (`⌘O`). Connect the selected provider explicitly after relaunching.
6. For native providers, choose a model in the composer, enter a task, and send it with `⌘Return`. Favorites sort first; disabled models cannot be used. New chats use the saved default. `⌘.` requests interruption. You can create multiple independent chats; only one native provider turn runs at a time. For Claude, open its official terminal as described below.

Claude Code uses a clearly identified **official Terminal session** until native interactive controls are verified against a working installed version. Choose a folder and press **Open Claude Code**; use its own model selection, permissions, /resume and Ctrl-C. Terminal conversations are separate from NativeAgent's local timeline, and existing drafts/history are preserved. Codex uses sandboxing and native approval requests. Grok uses ACP permission requests; **Read only** requires an advertised plan mode. Switching providers never sends an existing provider's thread ID to a different runtime.

Direct ChatGPT supports text chat, explicit attachments and a bounded recent-history excerpt (24 messages, up to 2,000 characters each). It has no local execution/editing tools and does not claim native remote thread resume. Models come from the account-specific catalog. Cancel closes the local listener; sign-in expires after five minutes. Disconnect preserves NativeAgent's authorization; sign-out attempts session revocation and clears its tokens without touching Codex. Usage settings link to ChatGPT; percentages are never invented. The runtime-specific controls described above apply only to the explicit legacy API-key connections.

The first turn in each project requires an explicit trust confirmation because repositories may contain agent instructions, hooks, and executable configuration.

## Groups and folders

Create a group from the sidebar and optionally associate it with a local parent folder. Select the group to add chats and nested folders. Nested folders inherit the parent's working folder; use **Edit group** or the folder picker when creating a child to select a different subdirectory. The system folder picker also supports creating a new directory.

Use **New chat** in the main sidebar for standalone chats, or **New chat** in a group's overview for chats inside that group. Right-click a chat to rename it or move it to any group or back to **Standalone chats**. You can also drag a chat onto a group. Groups can be renamed, moved, and removed when empty. Moving an existing chat preserves its working directory and history.

Groups, nesting, chat locations, and drafts persist across restarts. Migration 2 preserves existing project chats and creates a consistent SQLite backup named `NativeAgent.before-library-v2.sqlite3` before migrating the library. Sidebar search queries chat titles throughout the database, including unloaded chats, and filters group names. The right-hand files/changes inspector is optional; at narrow widths it temporarily replaces the sidebar to keep the conversation usable. Files and Git status are loaded only when the inspector is opened.

## Switch models in the same chat

The composer’s model menu includes enabled models from native providers, with favorites marked by stars, plus an entry for the official Claude Code terminal. Switch between turns; stop an active turn first. Same-provider model changes reuse that provider’s remote session. Changing native providers starts a new provider session while preserving the local chat, title, folder, draft, and full local history. No foreign provider’s session ID is reused. Claude terminal sessions manage their own model and history in the official program.

On the next send after a provider change, a bounded excerpt of up to 24 recent visible user/assistant messages (up to 2,000 characters each) accompanies your new message. Command output, hidden reasoning, and runtime credentials are not included automatically. The composer discloses this sharing before send. Older context and long-message tails are omitted; mention or paste important older details again. Switching back also starts a fresh provider session with recent context. Account/model access remains subject to each provider’s entitlement rules.

## Conversation details and prompt navigation

The clipboard-list button at the top right opens **Conversation details**. Progress shows the current task state, provider-reported plans and tool lifecycles, and pending approvals for this conversation. Results contains recorded file changes and responses; click an entry to read the stored output/diff, preview a file inside the working folder, or jump to its timeline entry. Sources contains only explicit provider references (read actions, image views, opened web pages) and recent-chat context actually sent by NativeAgent. A search query or a link mentioned in prose is not proof that a source was used. Older conversations may have no source records. Historical status is labeled “Last reported,” not presented as a live task.

The right-edge **prompt minimap** has one bar per user prompt. Hover to magnify a bar and its neighbors and read a short preview; click to jump to the original message. The accent marker tracks the visible conversation position. Long prompt indexes scroll within the rail. Focus the rail and use Up/Down to choose a prompt, Return to jump, and Escape to dismiss its preview. Individual prompt buttons also have accessible labels. Motion respects macOS Reduce Motion, and no animation timer or polling runs while idle.

Prompt navigation loads only short excerpts plus stable database IDs. Jumping outside loaded history fetches a bounded message window. The details popover initially shows up to 200 recent saved records plus the current history window; older records remain available by navigating earlier history. It does not scan repository files to invent results or capture separate Claude terminal sessions.

Provider event mapping follows the [official App Server event documentation](https://learn.chatgpt.com/docs/app-server); missing fields or unsupported events remain unavailable rather than being estimated.

## Archive and recovery

Right-click a chat and choose **Archive chat**. Open **Archive** at the bottom of the sidebar to restore it, including its group, messages, and unsent draft. Stop any active turn in that chat before archiving.

Recovery expires exactly 30 × 24 hours after archiving. Expired chats are hidden and cannot be restored. Cleanup permanently removes them from the live local library on launch, when opening Archive, and hourly while the app remains open, in small transactions. If the app is closed or the Mac is asleep, cleanup resumes when it next runs. This is local deletion, not a remote-provider history deletion or a guarantee of forensic erasure: provider-managed sessions, migration backups, and Time Machine or other external backups are separate.

## Large libraries and long chats

The sidebar loads 50 chats per page, with each group loaded on demand. Use **Load older chats** for another page or search for an unloaded chat directly. Opening a conversation loads its latest 40 entries; **Load earlier messages** loads another 40. The visible history window is capped at 200 entries, with **Return to latest messages** when browsing older history. Stored history is not discarded by these display limits.

Large messages initially show an 8,000-character preview. **Show full message** loads that message into a bounded native scrolling text view; collapsing it releases the expanded text. Streaming is batched, database writes are serialized and throttled, and UI refreshes slow down under Low Power Mode or serious thermal pressure. These measures reduce app work; they cannot guarantee laptop temperature or control a provider’s own workload.

## Local data and safety

- App metadata and display history: `~/Library/Application Support/NativeAgent/NativeAgent.sqlite3`
- NativeAgent's ChatGPT access, refresh and ID tokens are stored in a separate device-only Keychain entry, never in UserDefaults, SQLite, logs or process arguments. No Codex/Claude credential files are read. API keys use a different Keychain service; legacy runtimes may also retain explicitly supplied API credentials.
- Account labels in Settings are last-known status until explicitly reconnected. Sign-out is confirmed because it affects other clients sharing the official runtime's account. Removing a Keychain key does not revoke it at the provider or delete a copy already managed by a runtime.
- Account and API-key modes are distinct: an existing Codex API-key login is not silently accepted as a ChatGPT account subscription.
- Files are previewed only inside the chosen project. Escaping symbolic links are rejected.
- Git integration is read-only in P0. NativeAgent never resets, stashes, stages, commits, or pushes user work.
- Timeline, transport frames, file previews, Git output, and command output have explicit size limits.

## Verification

The offline test suite covers framing, UTF-8 boundaries, oversized input, SQLite migrations and provider namespaces, preference persistence, model selection, credential isolation, provider request payloads, process-output draining, path safety, staged/unstaged Git state, cross-provider conversation handoffs, rapid chat creation, streaming write ordering, archive expiry and recovery, and 10,000-chat/10,000-message fixtures. Set `NATIVEAGENT_SNAPSHOT_DIR` to an output directory when running `swift test --disable-sandbox` to render the actual SwiftUI workspace, archive, welcome screen, and settings panels with mock data and credentials. See [ProviderCompatibility.md](Docs/ProviderCompatibility.md) for the deliberately separate authenticated provider acceptance status.

Architecture details are in [Architecture.md](Docs/Architecture.md), and measurements are recorded in [Performance.md](Docs/Performance.md).

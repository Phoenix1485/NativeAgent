# Provider compatibility

## Current implementation

NativeAgent now uses direct, application-owned ChatGPT browser authorization. No API key or Codex installation is required for this connection. Failures and limits never switch billing modes. Independent Claude/Grok subscription authorization is not configured; account connections fail closed without launching their runtimes.

| Provider | Authentication | Conversation controls |
| --- | --- | --- |
| ChatGPT account | Direct browser OAuth + PKCE, application-owned Keychain credentials | Native Responses streaming and cancellation; explicit context and bounded local history; no local tools or remote thread resume |
| Codex API key (legacy, explicit) | Runtime login RPC with user-supplied API key | JSON-RPC streaming/approvals, gated by installed runtime validation |
| Claude/Grok account | Independent authorization not configured; no CLI launch | Unavailable in account mode |
| Claude/Grok API key (legacy, explicit) | User-supplied API key, separate billing | Existing Terminal/ACP adapters; require installed runtimes |

## Legacy Codex runtime contract (not used by ChatGPT account sign-in)

On an explicit connection, NativeAgent runs the selected executable's `--version` and `app-server generate-json-schema --out <temporary-directory>`. It checks representative login, account, cancellation, thread, resume, turn and interruption requests against that executable's generated v2 schemas. Missing or incompatible schemas produce an unsupported-version state; an executable which cannot run produces a connection failure. Temporary schema files are deleted after inspection.

The app starts one owned `codex app-server --listen stdio://` process and explicitly selects the built-in OpenAI model provider. It sends `initialize`, waits for its response, sends `initialized`, then reads `account/read` with refresh enabled. An account's exact type must match the explicitly selected subscription or API-key mode. Unknown account types are not subscription proof.

The browser flow uses `account/login/start {type:"chatgpt"}`, the returned `loginId` and `authUrl`, and matching `account/login/completed` notifications. Only HTTPS URLs on the supported OpenAI authentication hosts are opened. Account state is re-read and models are loaded before the provider announces a ready connection. Unmatched/late completion notifications are ignored. Cancel sends `account/login/cancel`; browser closure is indistinguishable from waiting, so the app offers Cancel and a five-minute timeout. Failed browser launch, unsuccessful authentication and expired/changed accounts remain recoverable.

The schema pinned to the installed package metadata (0.111.0) uses **`on-request`** for approval policy and **`read-only` / `workspace-write`** for thread sandbox modes. Turn sandbox policy objects instead use **`readOnly` / `workspaceWrite`**. This fixes the old tests and adapter, which incorrectly asserted camelCase for all of these fields.

Only command-execution and file-change approval request types receive native permission cards. Responses retain the actual request ID, restrict decisions to supported advertised choices, and cannot replay resolved requests. Unknown approval variants are rejected. NativeAgent does not advertise experimental interactive controls it cannot answer. Thread/turn IDs, errors and terminal statuses are provider-owned; commands and file changes are rendered from completed items.

Usage percentages and reset times come only from `account/rateLimits/read` or its update notification. The app shows unavailable information as unavailable. A provider-reported usage-limit error disables sending without switching billing or automatically replaying the task. The shared account is checked again before new turns.

References: [App Server](https://learn.chatgpt.com/docs/app-server), [authentication](https://learn.chatgpt.com/docs/auth). The installed executable's generated schema is the compatibility authority; documentation examples can differ across versions.

## Credentials and process ownership

Direct ChatGPT credentials belong to NativeAgent and stay in its isolated Keychain entry. No CLI token files are opened or copied. For the explicit legacy API-key adapters only, `CODEX_HOME` and `CLAUDE_CONFIG_DIR` identify shared runtime profiles. Disconnect preserves credentials. Legacy runtime sign-out warns that other clients of the shared profile may also be signed out; direct ChatGPT sign-out does not affect Codex.

User-supplied API keys are stored in device-only macOS Keychain entries. Codex receives an explicitly chosen key through its supported login RPC; it can also persist that key in its own credential store. Claude receives the selected key through its child environment only. Removing NativeAgent's Keychain entry does not revoke a key or erase the provider's copy.

Provider child environments remove inherited API keys, OAuth token overrides, alternate-provider selectors and workload-identity overrides before adding any explicitly selected API key. This does not change the user's global environment. Provider-managed configuration and organization policies still apply; a mismatched auth method is rejected, not silently accepted. Another independent client changing a shared login after a status check remains an external race; NativeAgent performs fresh checks but cannot lock other clients' provider profiles.

Pipe readers run off the main actor, drain stdout/stderr, and preserve partial JSON frames. Pipe and RPC queues are bounded; protocol overflow/EOF fails the connection rather than claiming success. Commands have deadlines and cancellation; owned processes receive termination with a bounded kill fallback. No provider starts at application launch, and app termination disconnects owned runtimes. Explicitly opened Claude terminal conversations belong to the Terminal window and can continue after the GUI closes.

## Claude Code terminal fallback

NativeAgent probes `--version` and `auth --help`, then parses the documented JSON from `auth status`. It requires successful exit, a boolean `loggedIn`, and an exact matching `authMethod`: `claude.ai` for subscription mode or `api_key` for the chosen API-key mode. Malformed/unknown output is not accepted as a successful connection. Account email, subscription type and configuration directory are displayed only when supplied by the program.

If subscription authentication is absent, **Connect Claude Code** opens the official `claude auth login` in Terminal. NativeAgent waits for exit and runs `auth status` again. The user never needs to type the login command. Cancellation or timeout cancels the pending operation; a completed provider login may remain available for a subsequent reconnect.

A small terminal-launch mode in the **same Swift executable** hands the terminal's standard input/output to the unmodified Claude program. It has no Node/Python bridge, embedded browser, private OAuth implementation or subscription token storage. A temporary owner-only launch directory contains paths and options, never a key or token. An optional API key is fetched from Keychain by the native launcher and passed only in the child's environment. This short-lived launcher is not an idle daemon.

**Open official Claude Code terminal** opens the chosen workspace after trust confirmation. The helper rechecks the selected authentication method in that workspace before launching. Claude owns the model picker (`/model`), conversation continuation (`/resume`), permission prompts and Ctrl-C. These terminal conversations are not ingested into NativeAgent's local timeline. Existing native drafts and history remain intact. Read only starts Claude's plan mode; it is not an enforced NativeAgent sandbox and can be changed in Terminal. No `--bare`, permission bypass, simulated native permissions or undocumented control protocol is used.

Anthropic's current conditions permit end users to authenticate into an unmodified official Claude Code binary in a product subject to the applicable agreements. Preserve all of its built-in authentication methods, bill usage to each end user's own credentials, and do not imply Anthropic endorsement. NativeAgent neither implements independent Claude.ai login nor collects/proxies its tokens. Review the applicable agreements before distributing the product; this implementation does not grant a distribution license.

References: [CLI reference](https://code.claude.com/docs/en/cli-reference), [authentication](https://code.claude.com/docs/en/authentication), [legal and compliance](https://code.claude.com/docs/en/legal-and-compliance).

## Direct ChatGPT browser authorization

Implemented from official [registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [accounts and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions), and [native HTTP inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference). The account route does not construct a CodexProvider, probe an executable or read its profile. The user's macOS malware warning must not be bypassed.

First sign-in uses the documented dynamic-registration entry point with NativeAgent's name and a persisted host ID; returning accounts use their issued client ID. Fresh state, nonce and PKCE protect each five-minute loopback attempt. Only 127.0.0.1 is bound. Callbacks reject state/client mismatches, duplicates, wrong paths and expired attempts. Apple Security/CryptoKit verify RS256/ES256 signatures with the published JWKS and enforce issuer/audience/expiry/nonce. Missing direct-plan scopes fail closed. HTTP redirects/cookies/disk caches are disabled. Credentials are isolated in NativeAgent's Keychain service. Renewals are serialized within the provider actor; sign-out attempts discovered-endpoint revocation before clearing tokens and reports unconfirmed revocation.

Native URLSession requests use the public `/v1/models` and `/v1/responses` endpoints, `store:false` and `stream:true`. Only a terminal `response.completed` is success; failed/incomplete/disconnected streams are not retried automatically. The direct adapter has **no local shell/file-edit tools** and advertises no native approvals/file-change events. A bounded visible-history excerpt is explicitly resent, recorded as context, and may omit older messages. Account-specific models replace the old runtime catalog; unsupported thinking levels are not invented. Eligibility and commercial partner access remain provider requirements, not claims established by this build.

Browser/authentication tests use generated cryptographic fixtures, fake credentials and local loopback HTTP only. Real provider consent, eligibility and authenticated inference still require an owner-operated live check. No real login credentials were copied or modified during development.

### Direct-browser validation — build 0.4.1

- Final suite: **95 tests passed**, including 27 native UI renders. The unsigned local release app rebuilt successfully (9.9 MB). Older verification records below describe earlier builds.
- Verified the actual view-model login route produces the OpenAI authorization URL even with a nonexistent Codex executable configured; opening the URL does not mark the account connected. Cancellation clears pending state.
- Exercised a real localhost callback plus simulated token exchange/JWKS verification through to application-owned credential persistence. Tested fresh/returning registration, PKCE, state, callback URI, denied consent, duplicate parameters, token scopes, rotation and signed RSA/EC identity fixtures.
- Exercised native HTTP streaming with success, explicit failure and missing terminal completion. An event framer preserves blank SSE boundaries rather than using macOS AsyncBytes.lines, which drops them.
- Tests do not launch Codex, bypass macOS security, open real authorization pages, use real account tokens, or charge any provider account. The real browser consent and authenticated response remain an owner-operated acceptance check.

## Verification record — 2026-10-12

- Swift sources compile on the development Mac.
- The offline suite covers account/billing isolation, stale callbacks, cancellation, timeout, provider errors, actual RPC decisions, schema enum validation, process draining, stream EOF and existing library/conversation behavior. Conversation navigation adds stable-ID seeking, live-fact updates, provenance checks, fisheye falloff and scoped approvals. Opt-in SwiftUI renders cover account onboarding, Claude terminal fallback, the prompt minimap at two window sizes and all three details tabs.
- The installed npm package reports metadata version **0.111.0**. Both the launcher and bundled native Codex executable were probed; even `--version` exits with **signal 9 / shell status 137**, including outside the execution sandbox. This is not a verified runnable runtime version.
- Claude Code is absent from the standard installation locations and command search path.
- Therefore live browser callbacks, real account/model entitlement, authenticated streaming, permission execution, interruption, resumed turns and Claude Terminal operation with the real executable are **not yet accepted**. No login credentials were read, copied or modified during development.

Once working official runtimes are installed, use the GUI buttons to verify: signed-out login; existing login reuse; cancel/browser-close recovery; mismatched API/subscription credentials; a model response; permission accept/deny; stop; disconnect/reconnect/resume; and usage-limit behavior when the provider supplies a real limit. For Claude, perform model selection, continuation, permissions and interruption in its official terminal. These checks require the owner's accounts and must not be reported as passed based on synthetic tests.

## Workspace feature boundaries

Validation on 2026-10-12: **83 tests passed, zero failures**, including the opt-in actual SwiftUI/AppKit renders. New coverage includes serial queue decisions/failure/uncertainty/cancellation, independent branches, profile application before implicit chat creation, context staleness/path boundaries, report evidence, paged/canceled search, restored unknown tasks and rollback conflict preservation. `NSFileCoordinator` tests require the ordinary macOS execution environment; the tool sandbox denies its coordination service. Native views were rendered at both workspace sizes and all new panels/palette were rendered offline. These are not authenticated provider or system-notification delivery tests.

- The dashboard shows selected-provider live state and explicitly labels other providers' saved identities as unverified. Model catalogs are not entitlement guarantees. Missing usage/reset/remaining data and management URLs remain unavailable; there is no inferred allowance or API-key fallback.
- Native queues/reports require structured streaming. Claude terminal conversations are not ingested; their execution, history, questions and approvals remain in Terminal.
- Branching currently uses the labeled selected-context fallback. Native fork-at-message semantics have not been verified against the installed executable.
- Code selections and file attachments are UTF-8 text only. Paths/line ranges/source hashes accompany copied content. The context inspector does not expose hidden/internal provider context.
- Codex questions are accepted only if its generated `ToolRequestUserInputResponse` schema validates the response shape. Missing/incompatible schemas fail closed. Actual question IDs, required answers and advertised choices are checked, and resolved requests cannot be replayed. No answer is preselected or auto-submitted, including requests that advertise an automatic timeout.
- Proposed Codex file changes are labeled separately from completed events and observed disk changes. Decisions use real pending approval requests, not synthetic apply buttons. Rollback excludes new/deleted/binary/uncheckpointed files and detects subsequent byte changes.
- Native notification permission/delivery, actual question availability and authenticated serial execution still require GUI/live-provider acceptance testing. Offline wire fixtures do not establish those capabilities on the installed runtime.

The optional question handling and proposal lifecycle follow the [official App Server documentation](https://learn.chatgpt.com/docs/app-server); runtime schema validation gates response payloads. Notifications use Apple's [normal authorization flow](https://developer.apple.com/documentation/UserNotifications/asking-permission-to-use-notifications). Targeted replacements use [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(writingitemat:options:error:byaccessor:)).

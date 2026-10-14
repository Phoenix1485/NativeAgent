import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case accounts = "Accounts", models = "Models", configuration = "Configuration", appearance = "Appearance"
    var id: String { rawValue }
    var icon: String { switch self { case .accounts: "person.crop.circle"; case .models: "sparkles"; case .configuration: "slider.horizontal.3"; case .appearance: "paintpalette" } }
    var subtitle: String { switch self {
    case .accounts: "Your accounts. Your choice of intelligence."
    case .models: "Keep the models you love. Hide the rest."
    case .configuration: "Decide how your agent works."
    case .appearance: "A workspace that feels like you."
    } }
}

struct ProviderSettingsView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    var body: some View { SettingsHub(model: model, settings: model.settings) }
}

struct SettingsHub: View {
    @ObservedObject var model: WorkspaceViewModel
    @ObservedObject var settings: AppPreferences
    var onboarding = false
    @State var page: SettingsPage = .accounts
    @State private var key = ""
    @State private var modelSearch = ""
    @State private var customModel = ""
    @State private var confirmSignOut = false
    @State private var confirmRemoveKey = false
    private var kind: ProviderKind { settings.provider }
    private var profile: ProviderPreference { settings.profile(kind) }
    private var busy: Bool { model.isWorking || model.accountActionInProgress || model.connectionStatus == .connecting }
    private var ready: Bool { if case .ready = model.connectionStatus { true } else { false } }
    private var direct: Bool { kind == .codex && profile.method == .account }
    private var unsupportedBrowser: Bool { kind != .codex && profile.method == .account }
    private var runtimePath: String? { ProviderExecutable.resolve(kind, configured: profile.binaryPath) }
    private var runtimeAvailable: Bool { runtimePath.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false }

    var body: some View {
        HStack(spacing: 0) {
            navigation
            Rectangle().fill(Studio.line).frame(width: 1)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(onboarding ? "MAKE IT YOURS" : "YOUR WORKSPACE").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(Studio.accent)
                        Text(page.rawValue).font(.system(size: 29, weight: .semibold)).tracking(-0.8)
                        Text(page.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if onboarding { Text("\((SettingsPage.allCases.firstIndex(of: page) ?? 0) + 1) / 4").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).padding(.top, 4) }
                }.padding(28)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch page { case .accounts: accounts; case .models: models; case .configuration: configuration; case .appearance: appearance }
                    }.padding(.horizontal, 28).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .leading)
                }
                if onboarding { onboardingFooter }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(Studio.canvas).accentColor(settings.accent.color).tint(settings.accent.color)
            .preferredColorScheme(settings.theme.scheme)
            .task { model.refreshSavedKeys(); model.refreshChatGPTAccounts() }
            .onChange(of: kind) { key = ""; customModel = "" }
            .onChange(of: profile.binaryPath) { model.providerInspection = nil }
            .onDisappear { key = "" }
            .alert("Sign out of \(kind.title)?", isPresented: $confirmSignOut) {
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) { Task { await model.signOut() } }
            } message: { Text(direct ? "This revokes NativeAgent’s selected ChatGPT session and clears its tokens from Keychain. Codex and other apps are unchanged. Your chat history stays here." : "This signs out the official provider runtime on this Mac, including other clients that share its account. Your chat history stays here.") }
            .alert("Remove saved API key?", isPresented: $confirmRemoveKey) {
                Button("Cancel", role: .cancel) {}
                Button("Remove key", role: .destructive) { Task { await model.removeAPIKey(kind) } }
            } message: { Text("Removes this provider’s key from NativeAgent’s Keychain entry. It does not revoke the key with the provider.") }
            .alert("Something needs attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .alert("You’re using your ChatGPT plan", isPresented: $model.showChatGPTPlanWelcome) {
                Button("Got it", role: .cancel) {}
            } message: { Text("Eligible requests in NativeAgent use your ChatGPT plan. Manage app access and usage limits in ChatGPT Settings → Usage.") }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 21)).foregroundStyle(Studio.accent)
                Text("NativeAgent").font(.system(size: 16, weight: .semibold))
            }.padding(.top, 10)
            VStack(alignment: .leading, spacing: 5) {
                Text(onboarding ? "Welcome home." : "Settings").font(.system(size: 14, weight: .medium))
                Text(onboarding ? "A few choices. All yours." : "Everything, in one place.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(spacing: 5) {
                ForEach(SettingsPage.allCases) { item in
                    Button { page = item } label: { SidebarRow(title: item.rawValue, icon: item.icon, selected: page == item) }.buttonStyle(.plain)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(.secondary)
                Text("Private by design").font(.system(size: 11, weight: .medium))
                Text("Keys and ChatGPT authorization tokens stay in Keychain. Passwords stay with your provider.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }
        }.padding(22).frame(width: 215).frame(maxHeight: .infinity).background(Studio.sidebar)
    }

    private var providerSelector: some View {
        HStack(spacing: 8) {
            ForEach(ProviderKind.allCases) { provider in
                Button { Task { await model.useProvider(provider) } } label: {
                    HStack(spacing: 7) { Image(systemName: provider.symbol); Text(provider == .codex ? "ChatGPT" : provider == .claude ? "Claude" : "Grok") }
                        .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(kind == provider ? Studio.accent.opacity(0.12) : Studio.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(kind == provider ? Studio.accent.opacity(0.5) : Studio.line))
                }.buttonStyle(.plain).disabled(busy)
            }
        }
    }

    private var accounts: some View {
        Group {
            providerSelector
            card {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: kind.symbol).font(.system(size: 22)).foregroundStyle(Studio.accent).frame(width: 42, height: 42).background(Studio.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(direct ? "ChatGPT" : kind.title).font(.system(size: 16, weight: .semibold))
                        Text(ready ? (profile.accountLabel ?? "Connected") : profile.accountLabel.map { "Last connected: " + $0 } ?? "Connect your account to get started.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(direct ? model.connectionStatus.label : unsupportedBrowser ? "Not available" : runtimeAvailable ? model.connectionStatus.label : "Installation missing").font(.system(size: 10, weight: .medium)).foregroundStyle(ready ? Color.green : Color.secondary)
                }
                Divider().padding(.vertical, 6)
                HStack(spacing: 10) {
                    authChoice(.account, title: "Account sign-in", subtitle: "Recommended", icon: "person.crop.circle")
                    authChoice(.apiKey, title: "Use API key", subtitle: "Separate API billing", icon: "key")
                }
                if profile.method == .account {
                    Text(direct ? "Authorize NativeAgent in your default browser. Eligible requests use your ChatGPT plan. No Codex app or command-line installation is needed." : "Independent browser subscription authorization is not configured for this provider. NativeAgent will not launch its CLI or claim that visiting its website connects your account.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                    if direct, !model.chatGPTAccounts.isEmpty {
                        Picker("ChatGPT account", selection: Binding(get: { model.selectedChatGPTAccount }, set: { id in Task { await model.selectChatGPTAccount(id) } })) {
                            Text("Add another account or workspace").tag("")
                            ForEach(model.chatGPTAccounts) { Text($0.label).tag($0.id) }
                        }.disabled(busy)
                    }
                    if direct { HStack {
                        Button { Task { await model.login() } } label: { Label("Continue with ChatGPT", systemImage: "arrow.up.right") }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)
                        if !model.selectedChatGPTAccount.isEmpty { Button("Reconnect saved account") { Task { await model.connect() } }.buttonStyle(.bordered).disabled(busy) }
                        Spacer()
                        if profile.accountLabel != nil { Button("Sign out…") { confirmSignOut = true }.buttonStyle(.borderless).foregroundStyle(.secondary).disabled(busy) }
                    } }
                } else {
                    Text("API keys are separate from subscription billing. Use a provider-issued API key—not a browser cookie or account password.").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        SecureField(model.savedKeyProviders.contains(kind) ? "A key is saved · enter a replacement" : "Paste your API key", text: $key).textFieldStyle(.roundedBorder)
                        Button("Save key") {
                            let value = key, provider = kind
                            Task { if await model.saveAPIKey(value, kind: provider) { key = "" } }
                        }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    }
                    HStack {
                        Button("Connect with saved key") { Task { await model.connect() } }.buttonStyle(.borderedProminent).disabled(!model.savedKeyProviders.contains(kind) || busy || !runtimeAvailable)
                        Link("Get an API key ↗", destination: kind.keyURL).font(.caption)
                        Spacer()
                        if model.savedKeyProviders.contains(kind) { Button("Remove…") { confirmRemoveKey = true }.buttonStyle(.borderless).disabled(busy) }
                    }
                }
            }
            card {
                Text("PROVIDER CONNECTION").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                if direct {
                    Text("Browser OAuth → NativeAgent → OpenAI Responses API").font(.system(size: 11)).textSelection(.enabled)
                    Text("App-owned authorization in Keychain. Chat and attached context are supported. Local commands and automatic file edits are not enabled in this direct connection.").font(.caption).foregroundStyle(.secondary)
                    Link("Manage ChatGPT plan usage and app access ↗", destination: URL(string: "https://chatgpt.com/settings/usage")!).font(.caption)
                } else if unsupportedBrowser {
                    Text("A documented, provider-approved direct authorization flow is required before this app can connect independently.").font(.caption).foregroundStyle(.secondary)
                } else {
                Text(model.providerInspection?.binaryPath ?? runtimePath ?? "Executable not found").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text("Version: \(model.providerInspection?.version ?? "checked when you connect")").font(.caption).foregroundStyle(.secondary)
                Text("Profile: \(model.providerAccount?.configuration ?? ProviderExecutable.profileDescription(kind))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let account = model.providerAccount {
                    if let email = account.email { Text(email).font(.caption).textSelection(.enabled) }
                    if let plan = account.plan { Text("Provider plan: \(plan)").font(.caption) }
                    Text(account.method == .account ? "Subscription connection" : "Separate API billing · model access checked on use").font(.caption).foregroundStyle(.secondary)
                }
                if let inspection = model.providerInspection { Text(inspection.message).font(.caption).foregroundStyle(.secondary) }
                if ready { Button("Disconnect") { Task { await model.disconnect() } }.disabled(busy) }
                if model.usageWindows.isEmpty {
                    Text("Usage information unavailable.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.usageWindows) { window in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(window.id): \(window.usedPercent)% used").font(.caption)
                            if let reset = window.resetsAt { Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if kind == .claude && !unsupportedBrowser {
                    Text("Conversations run in the official Claude Code terminal. Select models with /model, continue with /resume, and answer permissions there. NativeAgent’s native chat controls are disabled until verified.").font(.caption).foregroundStyle(.secondary)
                    Button("Open official Claude Code terminal") { Task { await model.openClaudeTerminal() } }.disabled(!ready || busy)
                }
            }
            if let notice = model.accountNotice {
                HStack(alignment: .top, spacing: 9) {
                    if model.accountActionInProgress { ProgressView().controlSize(.small) } else { Image(systemName: "info.circle").foregroundStyle(Studio.accent) }
                    Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if model.accountActionInProgress || model.connectionStatus == .notAuthenticated { Button("Cancel") { Task { await model.cancelLogin() } }.buttonStyle(.borderless) }
                }
            }
            if !direct && !unsupportedBrowser && !runtimeAvailable {
                card {
                    Label("Install the runtime once", systemImage: "arrow.down.circle").font(.system(size: 13, weight: .medium))
                    Text("Your custom app uses the provider’s command-line runtime—not its desktop app. It is not bundled or installed automatically.").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack { Link("Official setup guide ↗", destination: kind.setupURL); Spacer(); Button("Choose executable…") { chooseBinary() } }.font(.system(size: 12))
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("ALL CONNECTIONS")
                ForEach(ProviderKind.allCases) { provider in
                    let saved = settings.profile(provider)
                    HStack(spacing: 10) {
                        Image(systemName: provider.symbol).frame(width: 20).foregroundStyle(.secondary)
                        Text(provider.title).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(saved.accountLabel ?? (model.savedKeyProviders.contains(provider) ? "API key saved" : "Not set up")).font(.system(size: 11)).foregroundStyle(.secondary)
                        if saved.verifiedAt != nil { Image(systemName: "checkmark.circle").foregroundStyle(.secondary).help("Previously connected; not an active connection unless selected and connected now") }
                    }
                }
            }
        }
    }

    private func authChoice(_ method: AuthenticationMethod, title: String, subtitle: String, icon: String) -> some View {
        Button { Task { await model.disconnect(); settings.update(kind) { $0.method = method } } } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).foregroundStyle(profile.method == method ? Studio.accent : .secondary)
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 12, weight: .medium)); Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                Image(systemName: profile.method == method ? "checkmark.circle.fill" : "circle").foregroundStyle(profile.method == method ? Studio.accent : .secondary)
            }.padding(12).background(profile.method == method ? Studio.accent.opacity(0.07) : Studio.canvas, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(busy)
    }

    private var models: some View {
        Group {
            providerSelector
            HStack {
                TextField("Search models", text: $modelSearch).textFieldStyle(.roundedBorder)
                Button { Task { await model.refreshModels() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!ready || busy)
            }
            if kind == .claude {
                card {
                    Label("Choose models in Claude Code", systemImage: "terminal").font(.headline)
                    Text("Use /model in the official terminal to see choices for your account. NativeAgent does not claim a live Claude model catalog or native thinking controls.").font(.caption).foregroundStyle(.secondary)
                }
            } else if profile.catalog.isEmpty {
                card {
                    Label("Your model library starts here", systemImage: "sparkles").font(.headline)
                    Text("Connect this provider to load its model catalog. You can also add a specific model ID below. A listed model is not a guarantee of account access.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Set up account") { page = .accounts }.buttonStyle(.bordered)
                }
            } else {
                card {
                    HStack { Text("Default model").font(.system(size: 12, weight: .medium)); Spacer()
                        Picker("Default model", selection: Binding(get: { settings.resolvedDefault(kind) ?? "" }, set: { settings.setDefault($0, provider: kind); model.selectedModelID = $0 })) {
                            if settings.enabledModels(kind).isEmpty { Text("No enabled models").tag("") }
                            ForEach(settings.enabledModels(kind)) { Text($0.displayName).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: 250).disabled(busy)
                    }
                    Text("Used when connecting or starting a new chat. Stars move your favorites to the top of the composer’s model picker.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(spacing: 1) {
                    ForEach(profile.catalog.filter { modelSearch.isEmpty || $0.displayName.localizedCaseInsensitiveContains(modelSearch) || $0.id.localizedCaseInsensitiveContains(modelSearch) }) { item in modelRow(item) }
                }.background(Studio.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.line))
            }
            if kind != .claude { HStack {
                TextField("Add a specific model ID or CLI alias", text: $customModel).textFieldStyle(.roundedBorder)
                Button("Add model") { addCustomModel() }.disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            } }
            Text("Thinking controls appear only for levels advertised by the runtime or documented for its aliases. ‘Provider default’ uses the advertised default when available; otherwise it leaves the runtime’s setting unchanged. Custom IDs must be supported by your provider.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
        }
    }

    private func modelRow(_ item: ProviderModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { settings.update(kind) { value in if value.starredModels.contains(item.id) { value.starredModels.remove(item.id) } else { value.starredModels.insert(item.id) } } } label: {
                    Image(systemName: profile.starredModels.contains(item.id) ? "star.fill" : "star").foregroundStyle(profile.starredModels.contains(item.id) ? Color.yellow : Color.secondary)
                }.buttonStyle(.plain).accessibilityLabel("Favorite \(item.displayName)")
                VStack(alignment: .leading, spacing: 3) { Text(item.displayName).font(.system(size: 13, weight: .medium)); Text(item.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
                Spacer()
                if settings.resolvedDefault(kind) == item.id { Text("DEFAULT").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(Studio.accent) }
                Toggle("Enable \(item.displayName)", isOn: Binding(get: { !profile.disabledModels.contains(item.id) }, set: { settings.setEnabled(item.id, enabled: $0, provider: kind) })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(busy)
            }
            if !item.reasoningEfforts.isEmpty {
                HStack {
                    Label("Thinking", systemImage: "brain").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Thinking for \(item.displayName)", selection: Binding(get: { settings.reasoning(for: item, provider: kind) ?? "" }, set: { value in settings.update(kind) { $0.reasoning[item.id] = value.isEmpty ? nil : value } })) {
                        Text("Provider default").tag("")
                        ForEach(item.reasoningEfforts, id: \.self) { Text($0.capitalized).tag($0) }
                    }.labelsHidden().frame(width: 180).controlSize(.small).disabled(busy)
                }
            }
        }.padding(15)
    }

    private var configuration: some View {
        Group {
            providerSelector
            if direct {
                card {
                    sectionLabel("DIRECT CHATGPT CONNECTION")
                    Text("Browser sign-in and native HTTPS requests. The saved Codex executable path is not used for account sign-in or chat. Attach files explicitly; this connection cannot execute commands or edit the workspace.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
            card {
                sectionLabel("PROVIDER RUNTIME")
                TextField("Automatic detection", text: Binding(get: { profile.binaryPath }, set: { value in settings.update(kind) { $0.binaryPath = value } })).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).disabled(busy)
                HStack { Text(runtimePath ?? "No executable found").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled); Spacer(); Button("Choose…") { chooseBinary() }.disabled(busy) }
                Text("Changes apply on the next connection. No provider starts at app launch. Signing in or connecting starts only the chosen command-line runtime.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            }
            card {
                HStack { sectionLabel("WORKSPACE ACCESS"); Spacer(); Picker("Workspace access", selection: $settings.access) { ForEach(WorkspaceAccess.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 190).disabled(busy) }
                Text(direct ? "This direct ChatGPT connection has no local execution or editing tools, regardless of this setting. Only explicitly attached context and a bounded recent conversation excerpt are sent." : "Codex uses sandboxing and native approvals. Claude Code manages permissions in its official terminal; Read only starts its plan mode, which the user can change there. Grok uses native permission prompts and requires plan mode for Read only.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            }
            card {
                sectionLabel("CUSTOM INSTRUCTIONS")
                Text("How should your agent work? Language, coding style, testing expectations…").font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text: $settings.instructions).font(.system(size: 12)).scrollContentBackground(.hidden).frame(height: 100).padding(8).background(Studio.canvas, in: RoundedRectangle(cornerRadius: 8)).disabled(busy)
                Text("Applied to new Codex threads and Grok turns. Configure Claude instructions in its official terminal. Never put passwords or API keys here.").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if !onboarding { Button("Run welcome setup again") { settings.onboardingComplete = false } }
        }
    }

    private var appearance: some View {
        Group {
            sectionLabel("COLOR THEME")
            HStack(spacing: 12) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Button { settings.theme = theme } label: {
                        VStack(spacing: 10) {
                            HStack(spacing: 0) {
                                Rectangle().fill(theme == .light ? Color(white: 0.9) : Color(white: 0.12)).frame(width: 22)
                                VStack(alignment: .leading, spacing: 6) { Capsule().fill(settings.accent.color).frame(width: 30, height: 5); Capsule().fill(Color.gray.opacity(0.25)).frame(height: 4); Capsule().fill(Color.gray.opacity(0.25)).frame(width: 46, height: 4) }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity).background(theme == .light ? Color.white : theme == .dark ? Color(white: 0.18) : Color(white: 0.45))
                            }.frame(height: 76).clipShape(RoundedRectangle(cornerRadius: 7))
                            HStack { Text(theme.rawValue.capitalized); Spacer(); if settings.theme == theme { Image(systemName: "checkmark.circle.fill").foregroundStyle(settings.accent.color) } }.font(.system(size: 12, weight: .medium))
                        }.padding(12).background(Studio.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.theme == theme ? settings.accent.color : Studio.line, lineWidth: settings.theme == theme ? 2 : 1))
                    }.buttonStyle(.plain)
                }
            }
            card {
                sectionLabel("ACCENT COLOR")
                HStack(spacing: 17) {
                    ForEach(AccentChoice.allCases) { accent in
                        Button { settings.accent = accent } label: {
                            ZStack { Circle().fill(accent.color).frame(width: 30, height: 30); if settings.accent == accent { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) } }
                        }.buttonStyle(.plain).help(accent.rawValue.capitalized).accessibilityLabel(accent.rawValue.capitalized)
                    }
                    Spacer(); Text(settings.accent.rawValue.capitalized).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            card {
                HStack { Text("Message size").font(.system(size: 12)); Spacer(); Text("\(Int(settings.textSize)) pt").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Slider(value: $settings.textSize, in: 12...20, step: 1)
                Text("A little more room for your ideas.").font(.system(size: settings.textSize)).padding(.vertical, 8)
                Divider()
                Toggle("Show message timestamps", isOn: $settings.showTimestamps).font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
            }
            Text("Appearance changes are applied immediately to the workspace and settings.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var onboardingFooter: some View {
        HStack {
            Button("Set up later") { settings.onboardingComplete = true }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.accountActionInProgress)
            Spacer()
            if page != .accounts { Button("Back") { if let index = SettingsPage.allCases.firstIndex(of: page) { page = SettingsPage.allCases[index - 1] } }.buttonStyle(.bordered) }
            Button(page == .appearance ? "Open workspace" : "Continue") {
                if page == .appearance { settings.onboardingComplete = true }
                else if let index = SettingsPage.allCases.firstIndex(of: page) { page = SettingsPage.allCases[index + 1] }
            }.buttonStyle(.borderedProminent).controlSize(.large)
        }.font(.system(size: 12)).padding(20).background(Studio.surface)
    }
    private func sectionLabel(_ title: String) -> some View { Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary) }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Studio.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.line))
    }
    private func chooseBinary() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.prompt = "Choose Executable"
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        guard FileManager.default.isExecutableFile(atPath: path) else { model.errorMessage = "Choose an executable file, not an app bundle or folder."; return }
        settings.update(kind) { $0.binaryPath = path }
    }
    private func addCustomModel() {
        let id = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 200, !id.contains(where: \.isWhitespace) else { model.errorMessage = "Enter a model ID without spaces (up to 200 characters)."; return }
        settings.update(kind) { if !$0.catalog.contains(where: { $0.id == id }) { $0.catalog.append(.init(id: id, displayName: id, description: "Custom model ID · access checked by provider")) } }
        customModel = ""
    }
}

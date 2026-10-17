import AppKit
import SwiftUI

struct FeaturePanel: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @ObservedObject var features: WorkspaceFeaturesController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(features.panel?.title ?? "Workspace").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { features.panel = nil }.keyboardShortcut(.cancelAction)
            }
            if let notice = features.notice {
                HStack { Text(notice).font(.callout).textSelection(.enabled); Spacer(); Button("Dismiss") { features.notice = nil } }
                    .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Group {
                switch features.panel {
                case .dashboard: dashboard
                case .profiles: ProjectProfilePanel(features: features)
                case .templates: PromptLibraryPanel(features: features)
                case .reports: TaskReportsPanel(features: features)
                case .context: ContextInspectorPanel(features: features)
                case .memory:
                    if let chat = model.selectedConversation { ChatMemoryView(chat: chat.id) }
                    else { Text("Select a chat to manage its memory.") }
                case .queue: TaskQueuePanel(features: features)
                case .search: WorkspaceSearchPanel(features: features)
                case .selectedCode: selectedCode
                default: Text("Choose a workspace command.")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(24).frame(width: 760, height: 650).background(Studio.canvas)
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(ProviderKind.allCases) { provider in
                    let preference = model.settings.profile(provider)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Label(provider.title, systemImage: provider.symbol).font(.headline)
                                Spacer()
                                Text(preference.method == .apiKey ? "API key · separately billed" : "Provider account · subscription access").font(.caption)
                            }
                            if provider == model.settings.provider {
                                Text(model.connectionStatus.label)
                                if model.turnStatus == .stateUnknown { Button("Review uncertain execution…") { Task { await model.detachUnknownExecution() } } }
                                Text(model.providerAccount?.email ?? "No verified account identity available").foregroundStyle(.secondary)
                                if let plan = model.providerAccount?.plan { Text("Provider plan: \(plan)") }
                                if model.usageWindows.isEmpty { Text("Usage information unavailable.").foregroundStyle(.secondary) }
                                ForEach(model.usageWindows) { usage in
                                    VStack(alignment: .leading) {
                                        Text("\(usage.id): \(usage.usedPercent)% used (provider reported)")
                                        if let reset = usage.resetsAt { Text("Resets \(reset.formatted())").font(.caption) }
                                    }
                                }
                                DisclosureGroup("Available models (\(model.availableModels.count))") {
                                    ForEach(model.availableModels) { Text($0.displayName + " · " + $0.id).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                                }
                            } else {
                                Text(preference.accountLabel.map { "Last saved identity: \($0) (not currently verified)" } ?? "Not connected in this workspace").foregroundStyle(.secondary)
                                Text("Usage information unavailable.").font(.caption)
                            }
                            HStack {
                                Button("Connection settings…") { openSettings() }
                                Button(provider == model.settings.provider ? "Reconnect" : "Select and connect") { Task { await model.useProvider(provider); await model.connect() } }
                                    .disabled(model.isWorking || model.accountActionInProgress)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                Text("Billing modes never switch automatically. Remaining allowance and management links are unavailable unless supplied by a verified integration. Claude terminal activity is not captured by native task reports or queues.").font(.caption).foregroundStyle(.secondary)
                GroupBox("Notifications and restoration") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Task notifications (opt in)", isOn: Binding(get: { features.notificationsEnabled }, set: { enabled in
                            if enabled { Task { await features.enableNotifications() } } else { features.notificationsEnabled = false }
                        }))
                        ForEach(["finished", "failed", "approval", "question"], id: \.self) { event in
                            Toggle(event.capitalized, isOn: Binding(get: { features.notificationEnabled(event) }, set: { features.setNotification(event, enabled: $0) })).disabled(!features.notificationsEnabled)
                        }
                        Text("Question alerts require an explicit provider question event; ordinary reply text is never treated as a question.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Connect automatically when the app opens", isOn: Binding(get: { model.settings.automaticallyConnect }, set: { model.settings.automaticallyConnect = $0 }))
                        Text("Interrupted tasks require review. Restoring never resends a request.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var selectedCode: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select text in the Files preview. These actions prepare a draft with the exact selection and line range; they do not send or edit files.").foregroundStyle(.secondary)
            ForEach(["Explain this code", "Review for bugs", "Suggest improvements", "Refactor", "Generate tests", "Generate documentation"], id: \.self) { action in
                Button(action) { Task { await features.prepareCodeAction(action) } }.disabled(features.selectedCode.isEmpty || !model.providerCapabilities.structuredStreaming)
            }
        }
    }
}

private struct ProjectProfilePanel: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @ObservedObject var features: WorkspaceFeaturesController
    @State private var value: ProjectProfile?
    var body: some View {
        Group {
            if let profile = value {
                Form {
                    TextField("Profile name", text: binding(\.name))
                    Picker("Provider", selection: binding(\.provider)) { ForEach(ProviderKind.allCases) { Text($0.title).tag($0) } }
                    Picker("Model", selection: binding(\.modelID)) {
                        Text("Provider default").tag(String?.none)
                        ForEach(model.settings.enabledModels(profile.provider)) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    let efforts = model.settings.enabledModels(profile.provider).first { $0.id == profile.modelID }?.reasoningEfforts ?? []
                    Picker("Supported reasoning", selection: binding(\.reasoning)) {
                        Text("Model default").tag(String?.none)
                        ForEach(efforts, id: \.self) { Text($0).tag(Optional($0)) }
                    }.disabled(efforts.isEmpty)
                    LabeledContent("Working directory", value: profile.workingDirectory)
                    if profile.provider == .codex {
                        Picker("Native sandbox permission", selection: binding(\.access)) { ForEach(WorkspaceAccess.allCases, id: \.self) { Text($0.title).tag($0) } }
                    } else { Text("This integration does not expose a configurable native workspace sandbox. Permission preferences cannot grant additional capabilities.").font(.caption).foregroundStyle(.secondary) }
                    TextField("Coding instructions", text: binding(\.instructions), axis: .vertical).lineLimit(3...7)
                    TextField("Build command (stored only)", text: binding(\.buildCommand))
                    TextField("Test command (stored only)", text: binding(\.testCommand))
                    TextField("Format command (stored only)", text: binding(\.formatCommand))
                    TextField("Context preferences", text: binding(\.contextNotes), axis: .vertical).lineLimit(2...5)
                    Text("Saving never runs commands. Defaults apply to new conversations; current overrides remain visible in the context inspector.").font(.caption).foregroundStyle(.secondary)
                    Button("Save project profile") { Task { if let value { await features.saveProfile(value) } } }.buttonStyle(.borderedProminent)
                    ProjectMemoryEditor(projectID: profile.id).id(profile.id)
                }.formStyle(.grouped)
            } else { Text("Select a project first.") }
        }.onAppear { value = features.profile ?? features.defaultProfile() }
            .onChange(of: value?.provider) { value?.modelID = nil; value?.reasoning = nil }
            .onChange(of: value?.modelID) { value?.reasoning = nil }
    }
    private func binding<T>(_ key: WritableKeyPath<ProjectProfile, T>) -> Binding<T> {
        Binding(get: { value![keyPath: key] }, set: { value?[keyPath: key] = $0 })
    }
}

private struct PromptLibraryPanel: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @ObservedObject var features: WorkspaceFeaturesController
    @State private var query = ""
    @State private var editing: PromptTemplate?
    @State private var outcome = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search title, folder or text", text: $query).textFieldStyle(.roundedBorder)
                Button("New template") { editing = .init(title: "Untitled template", body: "{{outcome}}") }
            }
            if editing != nil {
                TextField("Title", text: edit(\.title))
                TextField("Folder / category", text: edit(\.folder))
                Picker("Scope", selection: edit(\.projectID)) {
                    Text("Global").tag(UUID?.none)
                    if let project = model.selectedProject { Text(project.name).tag(Optional(project.id)) }
                }
                TextEditor(text: edit(\.body)).font(.system(.body, design: .monospaced)).frame(minHeight: 130)
                Text("Placeholders: {{selected_code}}, {{file_path}}, {{language}}, {{outcome}}").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Save") { Task { if let editing { await features.saveTemplate(editing) }; editing = nil } }; Button("Cancel") { editing = nil } }
            } else {
                TextField("Requested outcome (placeholder value)", text: $outcome)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(features.templates) { template in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(template.title).font(.headline)
                                    Text("\(template.folder) · \(template.projectID == nil ? "Global" : "Project")").font(.caption).foregroundStyle(.secondary)
                                    Text(String(template.body.prefix(220))).font(.caption).lineLimit(3)
                                    HStack {
                                        Button("Insert into draft") { features.insertTemplate(template, values: ["selected_code": features.selectedCode, "file_path": model.selectedFile?.relativePath ?? "", "language": model.selectedFile.map { URL(fileURLWithPath: $0.relativePath).pathExtension } ?? "", "outcome": outcome]) }
                                        Button("Edit") { editing = template }
                                        Button("Duplicate") { var copy = template; copy.id = UUID(); copy.title += " copy"; editing = copy }
                                        Button("Delete", role: .destructive) { Task { await features.deleteTemplate(template) } }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                            }
                        }
                        if features.templates.count >= 50 { Button("Load more") { Task { await features.loadTemplates(query: query, more: true) } } }
                    }
                }
            }
        }.task(id: query) { await features.loadTemplates(query: query) }
    }
    private func edit<T>(_ key: WritableKeyPath<PromptTemplate, T>) -> Binding<T> { Binding(get: { editing![keyPath: key] }, set: { editing?[keyPath: key] = $0 }) }
}

private struct ContextInspectorPanel: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @ObservedObject var features: WorkspaceFeaturesController
    @State private var excerpt = ""
    @State private var kind: ContextAttachment.Kind = .excerpt
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Next request · explicit application context").font(.headline)
                Text("\(model.settings.provider.title) · \(model.selectedModelID ?? "No model") · \(model.settings.access.title)")
                if let profile = features.runProfile ?? features.profile {
                    Text("Profile: \(profile.name). \(profile.modelID != model.selectedModelID || profile.access != model.settings.access || profile.instructions != model.settings.instructions ? "Current settings override saved defaults." : "Using saved defaults.")").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Applicable coding instructions") { Text(model.settings.instructions.isEmpty ? "No application instructions attached." : model.settings.instructions).textSelection(.enabled) }
                ForEach(features.context) { item in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item.title).font(.headline); Spacer()
                                Button("Remove") { Task { await features.removeContext(item.id) } }
                            }
                            Text(item.kind == .fileReference ? "Reference only — file contents are not copied" : "Copied content · \(item.text.utf8.count) bytes").font(.caption)
                            if let path = item.path { Text(path).font(.caption).textSelection(.enabled) }
                            if let first = item.startLine { Text("Lines \(first)–\(item.endLine ?? first)").font(.caption) }
                            if item.stale { Label("Source changed or missing. Remove and reattach before sending.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            DisclosureGroup("Inspect contents and metadata") { Text(item.wireText).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack {
                    Button("Copy file contents…") { Task { await features.attachFile(referenceOnly: false) } }
                    Button("Add file reference…") { Task { await features.attachFile(referenceOnly: true) } }
                    Button("Check freshness") { Task { await features.validateContext() } }
                }.disabled(model.selectedProject == nil)
                Picker("Context type", selection: $kind) { Text("Text excerpt").tag(ContextAttachment.Kind.excerpt); Text("Instructions").tag(ContextAttachment.Kind.instructions); Text("Text attachment").tag(ContextAttachment.Kind.attachment) }
                TextEditor(text: $excerpt).frame(height: 90).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                Button("Attach text") { Task { await features.addContext(.init(kind: kind, title: kind.rawValue.capitalized, text: excerpt)); excerpt = "" } }.disabled(excerpt.isEmpty)
                Divider()
                Text("Provider-reported context (partial)").font(.headline)
                Text("Only explicitly reported sources appear here. The provider’s full internal context is unavailable.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.conversationDetails.filter { ConversationFact.decode($0.detail)?.category == .source }) { entry in
                    Button(entry.title) { Task { await model.navigateToMessage(entry.id); features.panel = nil } }.help(entry.text)
                }
            }
        }.task { await features.validateContext(); await model.refreshConversationSummaries() }
    }
}

private struct TaskReportsPanel: View {
    @ObservedObject var features: WorkspaceFeaturesController
    @State private var selectedFile: String?
    @State private var comparison = "Diff"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = features.selectedReport {
                HStack {
                    Button("All reports") { features.selectedReport = nil; selectedFile = nil }
                    Spacer()
                    Button("Copy Markdown") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report.markdown, forType: .string) }
                    Button("Export…") { features.exportReport(report) }
                    Button("Conversation") { Task { await features.openConversation(report.conversationID); features.panel = nil } }
                }
                if let file = features.checkpoints.first(where: { $0.path == selectedFile }) {
                    Text(file.path).font(.headline)
                    Text(file.after == nil ? "Post-task contents unavailable. No rollback offered." : "Observed on disk · already applied (not proof of authorship)").font(.caption).foregroundStyle(.secondary)
                    Picker("Comparison", selection: $comparison) { ForEach(["Diff", "Before", "After"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                    LongMessageView(text: comparison == "Diff" ? file.diff : comparison == "Before" ? String(decoding: file.before, as: UTF8.self) : file.after.map { String(decoding: $0, as: UTF8.self) } ?? "Unavailable", fontSize: 12, monospaced: true)
                    HStack { Button("Back to report") { selectedFile = nil }; Button(file.rolledBack ? "Restored" : "Roll back this file…") { Task { await features.rollback(file) } }.disabled(file.rolledBack || file.after == nil || features.activeTask != nil) }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            LongMessageView(text: report.markdown, fontSize: 12, monospaced: true).frame(height: 280)
                            Divider()
                            Text("Saved task comparisons").font(.headline)
                            ForEach(features.checkpoints) { file in Button(file.path + (file.rolledBack ? " · restored" : " · observed on disk")) { selectedFile = file.path } }
                            ForEach(report.fileChanges.keys.sorted(), id: \.self) { path in
                                DisclosureGroup("Provider-reported: \(path)") { Text(report.fileChanges[path] ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                            }
                            ForEach((report.proposals ?? [:]).keys.sorted(), id: \.self) { key in
                                if let proposal = report.proposals?[key] {
                                    DisclosureGroup("\(proposal.state == "proposed" ? "Proposed (not confirmed applied)" : "Provider status: " + proposal.state) · \(proposal.path)") {
                                        LongMessageView(text: proposal.diff, fontSize: 12, monospaced: true).frame(height: 180)
                                    }
                                }
                            }
                            Text("Provider change events are not treated as unapplied proposals. Approve or decline real pending requests in the conversation. New/deleted files and files outside captured coverage require manual review.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                if features.reports.isEmpty { Text("No recorded native tasks for this project yet.").foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(features.reports) { report in
                            Button { Task { await features.openReport(report.id) } } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(report.prompt).lineLimit(2)
                                    Text("\(report.state.rawValue) · \(report.provider.title) · \(report.startedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                        if features.reports.count >= 30 { Button("Load older reports") { Task { await features.loadReports(more: true) } } }
                    }
                }
            }
        }.task { await features.loadReports() }
    }
}

private struct TaskQueuePanel: View {
    @ObservedObject var features: WorkspaceFeaturesController
    @State private var editing: QueuedWork?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(features.queuePaused ? "Paused · serial execution" : "Started · serial execution").font(.headline)
                Spacer()
                Button("Add composer draft") { Task { await features.enqueueDraft() } }
                Button(features.queuePaused ? "Start queue" : "Pause after current") { if features.queuePaused { Task { await features.startQueue() } } else { features.pauseQueue() } }
            }
            Text("Tasks capture project, provider authentication/profile, model, permissions and explicit context. Approval/input blocks the next task; failure or uncertain state pauses the queue. Commands in profiles are not run automatically.").font(.caption).foregroundStyle(.secondary)
            if editing != nil {
                TextEditor(text: Binding(get: { editing?.prompt ?? "" }, set: { editing?.prompt = $0 })).frame(height: 110)
                HStack { Button("Save edited prompt") { Task { if let editing { await features.editQueue(editing) }; editing = nil } }; Button("Cancel edit") { editing = nil } }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(features.queue.sorted { $0.position < $1.position }) { item in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.prompt).lineLimit(4)
                                Text("\(item.state.rawValue) · \(item.provider.title) · \(item.modelID)").font(.caption.weight(.medium))
                                Text(item.projectPath + " · " + item.profile.name + " · " + item.authentication.rawValue).font(.caption).foregroundStyle(.secondary)
                                if let failure = item.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
                                HStack {
                                    Button("Edit") { editing = item }.disabled(item.state != .queued)
                                    Button("Move up") { Task { await features.moveQueue(item, by: -1) } }.disabled(!features.queuePaused || item.state.isActive)
                                    Button("Move down") { Task { await features.moveQueue(item, by: 1) } }.disabled(!features.queuePaused || item.state.isActive)
                                    Button("Cancel") { Task { await features.cancelQueue(item) } }.disabled(!item.state.isActive && item.state != .queued)
                                    Button("Remove") { Task { await features.removeQueue(item) } }.disabled(item.state.isActive)
                                    if let id = item.conversationID { Button("Conversation") { Task { await features.openConversation(id); features.panel = nil } } }
                                }.controlSize(.small)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                        }
                    }
                }
            }
        }
    }
}

private struct WorkspaceSearchPanel: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @ObservedObject var features: WorkspaceFeaturesController
    @State private var query = ""
    @State private var projectContent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search local content", text: $query).textFieldStyle(.roundedBorder)
            Toggle("Project-file contents (separate, bounded search)", isOn: $projectContent).disabled(model.selectedProject == nil)
            Text(projectContent ? "Up to 2,000 files, 1 MiB per text file; hidden, generated, dependency and symbolic-link paths excluded." : "Local history, projects, reports and templates · 40 results per page").font(.caption).foregroundStyle(.secondary)
            if features.searchLoading { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(features.searchResults) { hit in
                        Button { Task { await features.openSearch(hit) } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(hit.title).font(.headline).lineLimit(1)
                                Text([hit.kind, hit.projectName, hit.conversationTitle].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                Text(hit.excerpt).font(.caption).lineLimit(3)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if features.searchHasMore { Button("Load more results") { features.search(query, projectContent: projectContent, more: true) }.disabled(features.searchLoading) }
                }
            }
        }.onChange(of: query) { features.search(query, projectContent: projectContent) }
            .onChange(of: projectContent) { features.search(query, projectContent: projectContent) }
            .onDisappear { features.cancelSearch() }
    }
}

struct WorkspaceCommandPalette: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var features: WorkspaceFeaturesController
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool
    private struct Entry: Identifiable { var id: String; var title: String; var subtitle: String; var available: Bool; var run: () -> Void }
    private var entries: [Entry] {
        let commands = WorkspaceCommand.allCases.filter { $0.matches(query) }.map { command in
            Entry(id: command.id, title: command.title, subtitle: command.shortcut, available: features.canExecute(command)) {
                if command == .settings { features.paletteVisible = false; openSettings() } else { features.execute(command) }
            }
        }
        let projects = model.projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.prefix(20).map { project in
            Entry(id: "project/" + project.id.uuidString, title: project.name, subtitle: "Switch project", available: !model.isWorking) { features.paletteVisible = false; Task { await model.select(project) } }
        }
        let chats = model.conversations.filter { $0.archivedAt == nil && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }.prefix(30).map { chat in
            Entry(id: "chat/" + chat.id.uuidString, title: chat.title, subtitle: "Switch conversation", available: true) { features.paletteVisible = false; Task { await model.select(chat) } }
        }
        return commands + projects + chats
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Type a command, project or recent conversation", text: $query).textFieldStyle(.plain).font(.title3).focused($focused)
                .onSubmit { invokeSelection() }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            Button { entry.run() } label: {
                                HStack { Text(entry.title).lineLimit(1); Spacer(); Text(entry.subtitle).font(.caption).foregroundStyle(.secondary) }
                                    .padding(10).background(selection == index ? Studio.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!entry.available).id(index)
                        }
                    }
                }.onChange(of: selection) { proxy.scrollTo(selection) }
            }
            Text("↑ ↓ to navigate · Return to open · Escape to close · Search history for older conversations").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 600, height: 440)
            .onAppear { focused = true }
            .onChange(of: query) { selection = 0 }
            .onMoveCommand { direction in
                if direction == .down { selection = min(max(0, entries.count - 1), selection + 1) }
                if direction == .up { selection = max(0, selection - 1) }
            }
            .onExitCommand { features.paletteVisible = false }
    }
    private func invokeSelection() { if entries.indices.contains(selection), entries[selection].available { entries[selection].run() } }
}

struct WindowFrameRestorer: NSViewRepresentable {
    final class Host: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.setFrameAutosaveName("NativeAgentWorkspace") }
    }
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ nsView: Host, context: Context) {}
}

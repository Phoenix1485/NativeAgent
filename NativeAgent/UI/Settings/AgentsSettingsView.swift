import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentsSettingsView: View {
    @ObservedObject var model: WorkspaceViewModel
    @ObservedObject var store: AgentStore
    @State private var search = ""
    @State private var editing: AgentProfile?
    @State private var removing: AgentProfile?
    @State private var error: String?
    @State private var restore = false
    private var filtered: [AgentProfile] {
        store.profiles.filter { search.isEmpty || ($0.name + " " + $0.handle + " " + $0.summary).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("YOUR SPECIALISTS", systemImage: "person.2.badge.gearshape").font(.caption.weight(.semibold)).foregroundStyle(Studio.accent)
                Spacer()
                Menu {
                    Button("Import agents…", action: importAgents)
                    Button("Export agents…", action: exportAgents)
                    Divider()
                    Button("Restore built-in presets…") { restore = true }
                } label: { Image(systemName: "ellipsis.circle") }.help("Import, export and restore agents")
                Button { var value = AgentProfile(); value.handle = uniqueHandle("my-agent"); editing = value } label: { Label("New agent", systemImage: "plus") }.buttonStyle(.borderedProminent)
                    .disabled(store.profiles.count >= 50)
            }
            Text("Choose a preset or build a specialist with its own instructions, reference material and AI connection. Type @name in a prompt or choose @ → Agents; an accepted mention appears as a checked chip.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Let the main ChatGPT assistant delegate to agents", isOn: $store.automaticEnabled)
                Stepper("Up to \(store.callLimit) agent calls per turn", value: $store.callLimit, in: 1...6).disabled(!store.automaticEnabled)
                Text("The main direct ChatGPT connection can choose specialists when useful. Each agent controls whether to ask first or run automatically. Other connections support explicit @mentions. Agents cannot delegate again.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16).background(Studio.surface, in: RoundedRectangle(cornerRadius: 12))
            TextField("Search agents by name, @handle or purpose", text: $search)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Search agents")
            if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            LazyVStack(spacing: 10) {
                ForEach(filtered) { profile in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: profile.isBuiltIn ? "sparkles" : "person.crop.square").font(.title3).foregroundStyle(Studio.accent).frame(width: 28)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(profile.name).font(.headline); Text("@" + profile.handle).font(.caption.monospaced()).foregroundStyle(Studio.accent) }
                            Text(profile.summary.isEmpty ? "Custom instructions and context" : profile.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(status(profile)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Button("Edit") { editing = profile }
                        Menu {
                            Button(profile.enabled ? "Disable" : "Enable") { changeEnabled(profile) }
                            Button("Duplicate") { var copy = profile; copy.id = UUID(); copy.name += " copy"; copy.handle = uniqueHandle(profile.handle); copy.delegation = .manual; editing = copy }
                            Button("Delete…", role: .destructive) { removing = profile }
                        } label: { Image(systemName: "ellipsis") }.help("Agent actions")
                    }.padding(16).background(Studio.surface, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.line))
                }
                if filtered.isEmpty { Text("No matching agents. Create one or restore the built-in presets.").font(.callout).foregroundStyle(.secondary).padding(24) }
            }
            Text("These are NativeAgent presets powered by your configured accounts or APIs, not imported GPTs or Claude projects. Specialists provide text answers; the main assistant retains its tools and edit approvals. Claude subscription Terminal sessions are separate; use a Claude API connection for agents. Agent settings and references are stored on this Mac; export them separately from chat-library backups.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.isWorking || model.accountActionInProgress)
        .task { model.refreshSavedKeys(); model.refreshChatGPTAccounts() }
        .sheet(item: $editing) { profile in AgentEditorView(model: model, store: store, profile: profile) }
        .alert("Delete this agent?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Delete", role: .destructive) { if let removing { perform { try store.remove(removing.id) } }; removing = nil }
        } message: { Text("Its configuration and saved reference text will be removed. Existing chat messages stay in your library. Update drafts that mention this agent.") }
        .alert("Restore built-in agent presets?", isPresented: $restore) {
            Button("Cancel", role: .cancel) { }
            Button("Restore") { perform { try store.restoreBuiltIns() } }
        } message: { Text("Replaces changes to built-in agents with the defaults. Custom agents are kept.") }
    }
    private func status(_ profile: AgentProfile) -> String {
        guard profile.enabled else { return "Disabled" }
        guard let recipient = profile.recipient(from: model.aiRecipients) else { return "Needs connection setup · " + profile.delegation.rawValue }
        return recipient.detail + " · " + recipient.model + " · " + profile.delegation.rawValue
    }
    private func uniqueHandle(_ stem: String) -> String {
        var index = 1, result = String(stem.prefix(34))
        while store.profiles.contains(where: { $0.handle == result }) { index += 1; result = String(stem.prefix(34)) + "-\(index)" }
        return result
    }
    private func changeEnabled(_ profile: AgentProfile) { var value = profile; value.enabled.toggle(); perform { try store.save(value) } }
    private func perform(_ operation: () throws -> Void) { do { try operation(); error = nil } catch { self.error = error.localizedDescription } }
    private func importAgents() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 6_000_000 else { throw NativeAgentError.unsupported("Choose an agent JSON file smaller than 6 MB.") }
            try store.importData(Data(contentsOf: url))
        }
    }
    private func exportAgents() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "NativeAgent-agents.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try store.exportData().write(to: url, options: .atomic) }
    }
}

struct AgentEditorView: View {
    @ObservedObject var model: WorkspaceViewModel
    @ObservedObject var store: AgentStore
    @Environment(\.dismiss) private var dismiss
    @State var profile: AgentProfile
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(profile.isBuiltIn ? "Configure agent" : "Your custom agent").font(.title2.weight(.semibold)); Spacer(); Text("@" + profile.handle).font(.callout.monospaced()).foregroundStyle(Studio.accent) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { TextField("Name", text: $profile.name); TextField("@handle (without @)", text: $profile.handle) }
                    TextField("When should this agent be used?", text: $profile.summary)
                    Toggle("Enabled", isOn: $profile.enabled)
                    Divider()
                    Picker("AI connection", selection: $profile.connectionID) {
                        Text("ChatGPT preset · saved account or OpenAI API").tag("preset-chatgpt")
                        Text("Claude preset · Anthropic API").tag("preset-claude")
                        Text("Grok preset · xAI API or Grok account").tag("preset-grok")
                        ForEach(model.aiRecipients) { recipient in Text(recipient.name + " · " + recipient.detail).tag(recipient.id) }
                        if !profile.connectionID.hasPrefix("preset-"), !model.aiRecipients.contains(where: { $0.id == profile.connectionID }) { Text("Unavailable saved connection").tag(profile.connectionID) }
                    }
                    TextField("Model override · leave blank for the connection's model", text: $profile.model)
                    if let resolved = profile.recipient(from: model.aiRecipients) { Text(resolved.detail + " · " + resolved.model).font(.caption).foregroundStyle(.secondary) }
                    else { Text("This agent needs an enabled connection. Configure account/model access or add a connection in Settings → API connections.").font(.caption).foregroundStyle(.orange) }
                    textSection("Instructions", help: "Define its role, expertise, process and boundaries. Up to 32 KB.", text: $profile.instructions, height: 140)
                    textSection("Response preferences", help: "Optional tone, format, language or output requirements.", text: $profile.outputStyle, height: 65)
                    HStack {
                        Text("Reference material").font(.headline)
                        Spacer()
                        Button("Import text file…", action: importReference)
                    }
                    Text("Saved text is included in every request to this agent. Paste knowledge, conventions or examples. Text only, up to 80 KB; no passwords or API keys.").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $profile.reference).font(.system(size: 12, design: .monospaced)).frame(height: 120).border(Studio.line)
                    Divider()
                    Toggle("Include recent chat messages and chat instructions", isOn: $profile.includeHistory)
                    Toggle("Include attached text", isOn: $profile.includeAttachments)
                    Toggle("Allow Grok account agents to read the selected project", isOn: $profile.allowProjectRead)
                    Text("Other agents receive only the request and the context enabled above. Grok account requests require a trusted folder and can read it; write approvals remain denied. Images/PDFs are not sent to specialist agents.").font(.caption).foregroundStyle(.secondary)
                    Picker("Delegation", selection: $profile.delegation) { ForEach(AgentDelegation.allCases) { Text($0.rawValue).tag($0) } }
                    Text(profile.delegation == .automatic
                         ? "The main assistant may send this agent a task without asking again. That task may itself contain context chosen by the assistant. Requests use this connection's account limits or API billing; the per-turn cap still applies."
                         : profile.delegation == .ask ? "The main assistant may propose this agent and show its task and destination for approval before sending." : "This agent runs only when you explicitly select or mention it.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.trailing, 8)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("Settings apply to future requests.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save agent") { do { try store.save(profile); dismiss() } catch { self.error = error.localizedDescription } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 680, height: 740).background(Studio.canvas)
            .tint(model.settings.accent.color).accentColor(model.settings.accent.color)
            .disabled(model.isWorking)
    }
    private func textSection(_ title: String, help: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(help).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text).font(.system(size: 12)).frame(height: height).border(Studio.line)
        }
    }
    private func importReference() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 80_000 else { throw NativeAgentError.unsupported("Choose a UTF-8 text file of at most 80 KB.") }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0"), profile.reference.utf8.count + data.count + 2 <= 80_000 else { throw NativeAgentError.unsupported("The file must contain UTF-8 text and fit within the 80 KB reference limit.") }
            if !profile.reference.isEmpty { profile.reference += "\n\n" }
            profile.reference += text
        } catch { self.error = error.localizedDescription }
    }
}

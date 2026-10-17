import SwiftUI

struct AIConnectionsView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @State private var editing: AIConnection?
    @State private var removing: AIConnection?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("API connections").font(.title2.weight(.semibold))
                Spacer()
                Text("\(model.aiConnections.connections.count + model.savedKeyProviders.count) / 10 tokens").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("Bring your own API key. Tokens stay in this Mac’s Keychain, separately from account sign-ins. Use these AIs individually or together from @ in any chat. API usage has its own billing.").font(.callout).foregroundStyle(.secondary)
            ForEach(model.aiConnections.connections) { connection in
                HStack(spacing: 12) {
                    Image(systemName: "key.horizontal").foregroundStyle(Studio.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.name).font(.headline)
                        Text(connection.model + " · " + connection.destination).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("Edit") { editing = connection }
                    Button { removing = connection } label: { Image(systemName: "trash") }.accessibilityLabel("Remove \(connection.name)")
                }.padding(14).background(Studio.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            if !model.savedKeyProviders.isEmpty {
                Text("\(model.savedKeyProviders.count) existing provider key(s) also count toward the limit. Manage those in Accounts. They appear in @ after you configure a model in Models.").font(.caption).foregroundStyle(.secondary)
            }
            Menu {
                ForEach(AIConnection.presets, id: \.name) { preset in
                    Button(preset.name) { var connection = preset; connection.id = UUID(); editing = connection }
                }
            } label: { Label("Add API connection", systemImage: "plus") }
                .disabled(model.aiConnections.connections.count + model.savedKeyProviders.count >= AIConnectionStore.maximumTokens)
            Text("Supports OpenAI-compatible Chat Completions and Anthropic Messages APIs. Custom endpoints need a matching format; this does not make every proprietary AI API compatible. Text only, with no tool execution.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.disabled(model.isWorking || model.accountActionInProgress)
            .onAppear { model.refreshSavedKeys() }
            .sheet(item: $editing) { AIConnectionEditor(connection: $0).environmentObject(model) }
            .alert("Remove API connection?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Remove", role: .destructive) {
                    if let removing { do { try model.removeAIConnection(removing.id) } catch { self.error = error.localizedDescription } }
                    removing = nil
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: { Text("The saved Keychain token will be deleted. Existing chat messages are kept.") }
    }
}

private struct AIConnectionEditor: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State var connection: AIConnection
    @State private var token = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("API connection").font(.title2.weight(.semibold))
            TextField("Display name", text: $connection.name)
            Picker("API format", selection: $connection.format) { ForEach(AIWireFormat.allCases) { Text($0.title).tag($0) } }
            TextField("HTTPS API base URL, for example https://api.deepseek.com", text: $connection.baseURL)
            TextField("Model ID from your provider", text: $connection.model)
            SecureField("API token · leave blank to keep the existing token", text: $token)
            Text("Your token and prompts will be sent to \(connection.destination.isEmpty ? "the endpoint you enter" : connection.destination). Use only an endpoint you trust. Changing the URL requires entering its token again. Saving does not send a paid test request.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { token = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save connection") {
                    do { try model.saveAIConnection(connection, token: token); token = ""; dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(26).frame(width: 560).onDisappear { token = "" }
    }
}

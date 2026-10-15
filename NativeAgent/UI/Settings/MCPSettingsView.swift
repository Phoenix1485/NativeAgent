import AppKit
import SwiftUI

struct MCPSettingsView: View {
    @ObservedObject var manager: MCPManager
    @State private var name = ""
    @State private var executable = ""
    @State private var arguments = "[]"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect trusted local MCP servers to give ChatGPT additional tools and data sources. Servers never start automatically; every model tool call needs your approval.").foregroundStyle(.secondary)
            Text("Local stdio tools only. Remote HTTP/OAuth servers, prompts and resource browsing are not supported in this release. Server programs run with your Mac permissions, independently of workspace read-only mode.").font(.caption).foregroundStyle(.secondary)
            if let notice = manager.notice { Text(notice).foregroundStyle(.orange).textSelection(.enabled) }
            ForEach(manager.servers) { server in
                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Label(server.name, systemImage: "puzzlepiece.extension").font(.headline)
                            Spacer()
                            if manager.connecting.contains(server.id) { ProgressView().controlSize(.small) }
                            else if manager.connected[server.id] != nil {
                                Button("Disconnect") { Task { await manager.disconnect(server.id) } }
                            } else { Button("Connect…") { Task { await manager.connect(server) } } }
                            Button("Remove") { Task { await manager.remove(server.id) } }.disabled(manager.connecting.contains(server.id))
                        }
                        Text(server.executable).font(.caption.monospaced()).textSelection(.enabled)
                        if let tools = manager.connected[server.id] {
                            DisclosureGroup("\(tools.count) tools available") {
                                ForEach(tools) { tool in
                                    VStack(alignment: .leading) {
                                        Text(tool.name).font(.headline)
                                        Text(tool.description).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                                }
                            }
                            Text("Disconnect and reconnect to refresh the tool list.").font(.caption).foregroundStyle(.secondary)
                        } else { Text("Disconnected").font(.caption).foregroundStyle(.secondary) }
                    }.padding(8)
                }
            }
            GroupBox("Add a local server") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Server name", text: $name)
                    HStack {
                        TextField("Absolute executable path", text: $executable)
                        Button("Choose…") {
                            let picker = NSOpenPanel(); picker.canChooseDirectories = false
                            if picker.runModal() == .OK { executable = picker.url?.path ?? "" }
                        }
                    }
                    TextField("Arguments as JSON, e.g. [\"/path/to/server.js\"]", text: $arguments)
                        .font(.system(.body, design: .monospaced))
                    Text("For a Node server choose the installed node executable and put the server script path in the arguments array. No shell expansion or installation is performed. Do not put secrets here; configuration is stored locally as plain text.").font(.caption).foregroundStyle(.secondary)
                    Button("Add server") {
                        do { try manager.add(name: name, executable: executable, arguments: arguments); name = ""; executable = ""; arguments = "[]"; manager.notice = nil }
                        catch { manager.notice = error.localizedDescription }
                    }.disabled(name.isEmpty || executable.isEmpty)
                }.textFieldStyle(.roundedBorder).padding(8)
            }
        }
    }
}

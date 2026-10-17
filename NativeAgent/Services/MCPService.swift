import AppKit
import Combine
import Foundation

struct MCPServerConfiguration: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var executable: String
    var arguments: [String]
}

struct MCPTool: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    let schema: JSONValue
}

/// Explicitly started local stdio servers. No shell, installation, credential inheritance or autostart.
actor MCPConnection {
    private let transport = ProcessTransport()
    private var rpc: RPCClient?
    private var tasks: [Task<Void, Never>] = []
    private var generation = UUID()
    private var tools: [MCPTool] = []
    private let onClose: @Sendable () async -> Void
    init(onClose: @escaping @Sendable () async -> Void = {}) { self.onClose = onClose }

    func connect(_ configuration: MCPServerConfiguration) async throws -> [MCPTool] {
        guard rpc == nil else { throw NativeAgentError.alreadyRunning }
        guard configuration.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: configuration.executable) else {
            throw NativeAgentError.unsupported("Choose an installed MCP server executable using its absolute path.")
        }
        let token = generation
        let rpc = RPCClient(transport: transport, jsonRPCVersion: true)
        self.rpc = rpc
        do {
            let parent = ProcessInfo.processInfo.environment
            var environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
            for name in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] { environment[name] = parent[name] }
            let output = try await transport.start(binary: URL(fileURLWithPath: configuration.executable), arguments: configuration.arguments,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser, environment: environment)
            tasks = [
                Task { [weak self] in await rpc.consume(output.stdout); await self?.connectionEnded(token) },
                Task { for await _ in output.stderr { /* Drain without logging possible credentials. */ } },
                Task { for await request in rpc.serverRequests {
                    if request.method == "ping" { try? await rpc.reply(to: request.id, result: .object([:])) }
                    else { try? await rpc.reply(to: request.id, errorCode: -32601, message: "Client capability not enabled") }
                } },
                Task { for await _ in rpc.notifications { /* No polling or unsolicited actions. Refresh is explicit. */ } }
            ]
            let result = try await rpc.request(method: "initialize", params: .object([
                "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("NativeAgent"), "version": .string("0.6.0")])]))
            guard token == generation else { throw CancellationError() }
            guard ["2024-11-05", "2025-03-26", "2025-06-18"].contains(result["protocolVersion"]?.stringValue ?? ""),
                  result["capabilities"]?["tools"]?.objectValue != nil else {
                throw NativeAgentError.unsupported("This server must support MCP stdio tools (2024-11-05 through 2025-06-18).")
            }
            try await rpc.notify(method: "notifications/initialized")
            var cursor: String?, cursors = Set<String>(), found: [MCPTool] = []
            repeat {
                let result = try await rpc.request(method: "tools/list", params: .object(cursor.map { ["cursor": .string($0)] } ?? [:]))
                guard token == generation else { throw CancellationError() }
                found += try Self.parseTools(result)
                guard found.count <= 64, Set(found.map(\.name)).count == found.count else {
                    throw NativeAgentError.unsupported("MCP tools must have unique names; at most 64 tools are supported per server.")
                }
                cursor = result["nextCursor"]?.stringValue
                if let cursor, !cursors.insert(cursor).inserted || cursors.count > 16 { throw NativeAgentError.protocolError("Invalid MCP pagination") }
            } while cursor != nil
            tools = found
            return found
        } catch { await disconnect(); throw error }
    }

    nonisolated static func parseTools(_ result: JSONValue) throws -> [MCPTool] {
        guard let values = result["tools"]?.arrayValue else { throw NativeAgentError.protocolError("Missing MCP tool list") }
        return try values.map { value in
            guard let name = value["name"]?.stringValue, !name.isEmpty, name.utf8.count <= 128,
                  let schema = value["inputSchema"], schema["type"]?.stringValue == "object",
                  try JSONEncoder().encode(schema).count <= 65_536 else { throw NativeAgentError.protocolError("Invalid MCP tool definition") }
            return MCPTool(name: name, description: String((value["description"]?.stringValue ?? name).prefix(4_096)), schema: schema)
        }
    }

    func call(_ tool: MCPTool, arguments: JSONValue) async throws -> String {
        guard let rpc, tools.contains(tool), arguments.objectValue != nil else { throw NativeAgentError.unsupported("MCP tool is no longer connected. Reconnect and send again.") }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            do {
                let result = try await rpc.request(method: "tools/call", params: .object(["name": .string(tool.name), "arguments": arguments]), timeout: .seconds(120))
                try Task.checkCancellation()
                let data = try JSONEncoder().encode(result)
                guard data.count <= 262_144 else { throw NativeAgentError.unsupported("MCP returned more than 256 KiB. Narrow the request. The action may already have completed.") }
                let text = String(decoding: data, as: UTF8.self)
                if result["isError"] == .bool(true) { throw NativeAgentError.protocolError("MCP tool reported an error: " + text) }
                return text
            } catch {
                // Never retry a possibly side-effecting call. Close the process on uncertain execution.
                await disconnect()
                throw error
            }
        } onCancel: { Task { await self.disconnect() } }
    }

    func disconnect() async {
        generation = UUID(); tools = []
        let old = rpc; rpc = nil
        await old?.close(); await transport.closeInput(); await transport.stop()
        tasks.forEach { $0.cancel() }; tasks = []
    }
    private func connectionEnded(_ token: UUID) async {
        guard token == generation else { return }
        await disconnect(); await onClose()
    }
}

@MainActor
final class MCPManager: ObservableObject {
    @Published private(set) var servers: [MCPServerConfiguration]
    @Published private(set) var connected: [UUID: [MCPTool]] = [:]
    @Published private(set) var connecting = Set<UUID>()
    @Published var notice: String?
    private var connections: [UUID: MCPConnection] = [:]
    private var tickets: [UUID: UUID] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        servers = defaults.data(forKey: "mcp.servers.v1").flatMap { try? JSONDecoder().decode([MCPServerConfiguration].self, from: $0) } ?? []
    }
    func add(name: String, executable: String, arguments: String) throws {
        guard servers.count < 8, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, executable.hasPrefix("/") else {
            throw NativeAgentError.unsupported("Enter a name and an absolute executable path. Up to eight servers are supported.")
        }
        let args = try JSONDecoder().decode([String].self, from: Data(arguments.utf8))
        guard args.count <= 64, arguments.utf8.count <= 16_384 else { throw NativeAgentError.unsupported("Too many MCP arguments.") }
        servers.append(.init(name: name, executable: executable, arguments: args)); save()
    }
    private func save() { if let data = try? JSONEncoder().encode(servers) { defaults.set(data, forKey: "mcp.servers.v1") } }
    func connect(_ server: MCPServerConfiguration) async {
        guard !connecting.contains(server.id), connected[server.id] == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Trust and start \(server.name)?"
        alert.informativeText = "This runs a local program with your Mac user permissions, not in a sandbox. It may read or change files or use the network on startup. Only start servers you trust. Its tool descriptions will be shared with ChatGPT on future sends; each tool call requires approval.\n\n\(server.executable)\nArguments: \(server.arguments)\n\nDo not put passwords in arguments. NativeAgent does not inherit provider tokens or shell environment secrets."
        alert.addButton(withTitle: "Start server"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        connecting.insert(server.id)
        defer { connecting.remove(server.id) }
        let ticket = UUID(); tickets[server.id] = ticket
        let connection = MCPConnection { [weak self] in await self?.connectionEnded(server.id, ticket: ticket) }
        connections[server.id] = connection
        do {
            let tools = try await connection.connect(server)
            guard tickets[server.id] == ticket else { await connection.disconnect(); return }
            connected[server.id] = tools
        }
        catch { connections[server.id] = nil; connected[server.id] = nil; notice = error.localizedDescription }
    }
    func disconnect(_ id: UUID) async {
        tickets[id] = nil
        let old = connections.removeValue(forKey: id); connected[id] = nil
        await old?.disconnect()
    }
    func remove(_ id: UUID) async { await disconnect(id); servers.removeAll { $0.id == id }; save() }
    func shutdown() async { for id in Array(connections.keys) { await disconnect(id) } }
    private func connectionEnded(_ id: UUID, ticket: UUID) {
        guard tickets[id] == ticket else { return }
        tickets[id] = nil; connections[id] = nil; connected[id] = nil
        notice = "An MCP server disconnected. Reconnect explicitly before using its tools again. No tool was retried."
    }
    func toolBindings() -> [NativeTool] {
        servers.flatMap { server in
            (connected[server.id] ?? []).enumerated().compactMap { index, tool -> NativeTool? in
                guard let connection = connections[server.id], let ticket = tickets[server.id] else { return nil }
                let name = "mcp_" + server.id.uuidString.replacingOccurrences(of: "-", with: "") + "_\(index)"
                return NativeTool(name: name, description: "\(server.name): \(tool.description)", schema: tool.schema) { arguments in
                    let text = String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
                    return PreparedNativeTool(title: "\(server.name) · \(tool.name)", review: "MCP server: \(server.executable)\nTool: \(tool.name)\nArguments:\n\(text)\n\nThis third-party tool may change files or external data. Its result will be sent to ChatGPT. Workspace read-only mode does not sandbox MCP servers.") {
                        do { return try await connection.call(tool, arguments: arguments) }
                        catch { await self.connectionEnded(server.id, ticket: ticket); throw error }
                    }
                }
            }
        }
    }
}

struct PreparedNativeTool: Sendable {
    let title: String
    let review: String
    var changedPath: String? = nil
    var requiresApproval = true
    let execute: @Sendable () async throws -> String
}

struct NativeTool: Sendable {
    let name: String
    let description: String
    let schema: JSONValue
    let prepare: @Sendable (JSONValue) async throws -> PreparedNativeTool
    var definition: JSONValue { .object(["type": .string("function"), "name": .string(name), "description": .string(description), "parameters": schema, "strict": .bool(false)]) }
}

import Foundation

/// Probes run only after an explicit Connect/Sign in action. No credentials are read here.
enum RuntimeValidation {
    static func version(path: String, kind: ProviderKind, command: ProviderCommand) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw NativeAgentError.missingInstallation("Install \(kind.title), or choose its executable in Configuration.")
        }
        let result = try await command.run(path: path, arguments: ["--version"], environment: ProviderExecutable.environment(kind: kind, key: nil), timeout: .seconds(10))
        guard result.code == 0 else {
            throw NativeAgentError.providerUnavailable("\(kind.title) could not run its version check (exit \(result.code)). Repair its installation or choose another executable.")
        }
        guard let version = parseVersion(String(decoding: result.output, as: UTF8.self)) else {
            throw NativeAgentError.unsupportedVersion("The selected executable did not report a supported version format.")
        }
        return version
    }

    static func parseVersion(_ text: String) -> String? {
        guard text.utf8.count < 4096,
              let range = text.range(of: #"\b[0-9]+\.[0-9]+\.[0-9]+\b"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    static func codexSchema(path: String, command: ProviderCommand) async throws -> JSONValue? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeAgent-schema-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await command.run(path: path, arguments: ["app-server", "generate-json-schema", "--out", directory.path],
                                         environment: ProviderExecutable.environment(kind: .codex, key: nil), timeout: .seconds(30))
        guard result.code == 0 else { throw NativeAgentError.unsupportedVersion("This Codex version cannot generate the required App Server schema. Update Codex and reconnect.") }
        let samples: [(String, JSONValue)] = [
            ("LoginAccountParams", .object(["type": .string("chatgpt")])),
            ("LoginAccountParams", .object(["type": .string("apiKey"), "apiKey": .string("schema-check-placeholder")])),
            ("GetAccountParams", .object(["refreshToken": .bool(true)])),
            ("CancelLoginAccountParams", .object(["loginId": .string("schema-check")])),
            ("ThreadStartParams", .object(["cwd": .string("/tmp"), "modelProvider": .string("openai"), "approvalPolicy": .string("on-request"), "sandbox": .string("read-only")])),
            ("ThreadResumeParams", .object(["threadId": .string("schema-check"), "modelProvider": .string("openai"), "approvalPolicy": .string("on-request"), "sandbox": .string("workspace-write")])),
            ("TurnStartParams", .object(["threadId": .string("schema-check"), "input": .array([.object(["type": .string("text"), "text": .string("check")])]), "approvalPolicy": .string("on-request"), "sandboxPolicy": .object(["type": .string("workspaceWrite"), "networkAccess": .bool(false), "writableRoots": .array([.string("/tmp")])])])),
            ("TurnInterruptParams", .object(["threadId": .string("schema-check"), "turnId": .string("schema-check")]))
        ]
        for (name, sample) in samples {
            let url = directory.appendingPathComponent("v2/" + name + ".json")
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 4_194_304,
                  let data = try? Data(contentsOf: url), let schema = try? JSONDecoder().decode(JSONValue.self, from: data),
                  SchemaSubset.accepts(sample, schema: schema, root: schema) else {
                throw NativeAgentError.unsupportedVersion("Codex’s \(name) schema does not match this app’s supported protocol. Update NativeAgent or choose a compatible Codex version.")
            }
        }
        // Optional capability. Never make base authentication depend on this experimental surface.
        let responseURL = directory.appendingPathComponent("v2/ToolRequestUserInputResponse.json")
        guard let size = try? responseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_048_576,
              let data = try? Data(contentsOf: responseURL), let schema = try? JSONDecoder().decode(JSONValue.self, from: data),
              SchemaSubset.accepts(.object(["answers": .object(["question": .object(["answers": .array([.string("chosen answer")])])])]), schema: schema, root: schema) else { return nil }
        return schema
    }

    static func claudeCommands(path: String, command: ProviderCommand) async throws {
        let environment = ProviderExecutable.environment(kind: .claude, key: nil)
        let result = try await command.run(path: path, arguments: ["auth", "--help"], environment: environment, timeout: .seconds(10))
        let help = String(decoding: result.output, as: UTF8.self)
        guard result.code == 0, ["login", "logout", "status"].allSatisfy(help.contains) else {
            throw NativeAgentError.unsupportedVersion("This Claude Code version does not advertise auth login/status/logout. Update Claude Code and reconnect.")
        }
    }
}

/// The subset needed to check our request examples against the runtime's own schema.
/// Undocumented request fields and unresolved references fail closed. This checks
/// types, required fields and variants, not every JSON Schema constraint.
enum SchemaSubset {
    static func accepts(_ value: JSONValue, schema: JSONValue, root: JSONValue, depth: Int = 0) -> Bool {
        guard depth < 32 else { return false }
        if schema == .bool(true) { return true }
        if schema == .bool(false) { return false }
        guard let object = schema.objectValue else { return false }
        if let ref = object["$ref"]?.stringValue {
            guard ref.hasPrefix("#/definitions/"), let target = root["definitions"]?[String(ref.dropFirst(14))] else { return false }
            return accepts(value, schema: target, root: root, depth: depth + 1)
        }
        for key in ["oneOf", "anyOf", "allOf"] {
            if let variants = object[key]?.arrayValue {
                let count = variants.filter { accepts(value, schema: $0, root: root, depth: depth + 1) }.count
                if key == "allOf" ? count != variants.count : (key == "oneOf" ? count != 1 : count == 0) { return false }
            }
        }
        if let values = object["enum"]?.arrayValue, !values.contains(value) { return false }
        if let types = object["type"].map({ $0.arrayValue ?? [$0] }) {
            let actual: String
            switch value { case .null: actual = "null"; case .bool: actual = "boolean"; case .number: actual = "number"; case .string: actual = "string"; case .array: actual = "array"; case .object: actual = "object" }
            guard types.contains(.string(actual)) || (actual == "number" && types.contains(.string("integer"))) else { return false }
        }
        if let values = value.objectValue, object["properties"] != nil || (object["oneOf"] == nil && object["anyOf"] == nil && object["allOf"] == nil) {
            let properties = object["properties"]?.objectValue ?? [:]
            if let required = object["required"]?.arrayValue, required.contains(where: { values[$0.stringValue ?? ""] == nil }) { return false }
            for (key, child) in values {
                // Even when the server permits extra properties, every field we SEND must be documented.
                guard let property = properties[key] ?? object["additionalProperties"].flatMap({ $0.objectValue == nil ? nil : $0 }), accepts(child, schema: property, root: root, depth: depth + 1) else { return false }
            }
        }
        if let values = value.arrayValue, let item = object["items"] {
            return values.allSatisfy { accepts($0, schema: item, root: root, depth: depth + 1) }
        }
        return true
    }
}

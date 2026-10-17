import SwiftUI

struct ProjectMemoryEditor: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let projectID: UUID
    @State private var memory = ProjectMemory()
    @State private var loaded = false
    @State private var saving = false
    @State private var status: String?
    var body: some View {
        Section("Project memory") {
            Text("Applied on the next request in every chat using this project. This memory is separate from automatic chat summaries; only you edit it. Leave fields blank to forget them. Up to 4,000 characters per field.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Frameworks and stack", text: $memory.frameworks, axis: .vertical).lineLimit(2...5)
            TextField("Coding conventions", text: $memory.conventions, axis: .vertical).lineLimit(2...5)
            TextField("Project goals", text: $memory.goals, axis: .vertical).lineLimit(2...5)
            TextField("Decisions", text: $memory.decisions, axis: .vertical).lineLimit(2...5)
            TextField("Things to avoid", text: $memory.avoidances, axis: .vertical).lineLimit(2...5)
            if !memory.isValid { Text("A field is longer than 4,000 characters.").foregroundStyle(.orange) }
            Button("Save project memory") {
                saving = true
                Task {
                    defer { saving = false }
                    do { try await model.database.saveProjectMemory(memory, projectID: projectID); status = "Saved. Used for the next request in this project." }
                    catch { status = error.localizedDescription }
                }
            }.disabled(!loaded || saving || model.isWorking || !memory.isValid)
            if let status { Text(status).font(.caption).textSelection(.enabled) }
        }.task(id: projectID) {
            loaded = false
            do { memory = try await model.database.projectMemory(projectID); loaded = true }
            catch { status = error.localizedDescription }
        }
    }
}

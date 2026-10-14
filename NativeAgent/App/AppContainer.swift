import Foundation

@MainActor
final class AppContainer: ObservableObject {
    let viewModel: WorkspaceViewModel

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeAgent", isDirectory: true)
        let databaseURL = support.appendingPathComponent("NativeAgent.sqlite3")
        let database: DatabaseActor
        do { database = try DatabaseActor(url: databaseURL) }
        catch { fatalError("Unable to initialize NativeAgent storage: \(error.localizedDescription)") }
        viewModel = WorkspaceViewModel(database: database, files: FileService(), git: GitService())
    }
}

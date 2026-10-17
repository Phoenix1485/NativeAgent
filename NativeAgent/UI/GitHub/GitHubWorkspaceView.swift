import AppKit
import SwiftUI

struct GitHubWorkspaceView: View {
    enum Page: String, CaseIterable { case changes = "Changes", history = "History", branches = "Branches", pulls = "Pull requests", repositories = "Repositories" }
    @ObservedObject var model: WorkspaceViewModel
    @ObservedObject var controller: GitHubController
    @State private var page: Page = .changes
    @State private var commitMessage = ""
    @State private var newBranch = ""
    @State private var base = "main"
    @State private var head = "HEAD"
    @State private var diffTitle = "Select a file or comparison"
    @State private var repositoryQuery = ""
    @State private var cloneSource = ""
    @State private var repositoryName = ""
    @State private var privateRepository = true
    @State private var createMode = false
    @State private var showRepositoryForm = false
    @State private var parentFolder: URL?
    @State private var showPRForm = false
    @State private var prTitle = ""
    @State private var prBody = ""
    @State private var prDraft = true
    @State private var aiRequest: AIAssistanceRequest?

    private var root: String? { model.selectedProject?.canonicalPath }
    private var localReady: Bool { !controller.busy && !model.isWorking && controller.snapshot?.root == root && controller.snapshot?.isRepository == true }
    private var remoteReady: Bool { localReady && controller.auth.isAuthenticated && controller.snapshot?.repository != nil }
    private var stagedCount: Int { controller.snapshot?.changes.filter(\.staged).count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GitHubAccountView(controller: controller)
            Divider()
            toolbar
            if let error = controller.error { HStack { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled); Spacer(); Button("Dismiss") { controller.error = nil } } }
            if let error = controller.githubError { Text("GitHub: " + error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Picker("Repository section", selection: $page) { ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if page == .repositories { repositories }
            else if controller.snapshot?.isRepository != true {
                ContentUnavailableView {
                    Label("Choose a Git repository", systemImage: "folder.badge.gearshape")
                } description: { Text("Open a local project, clone one from GitHub, or create a repository for your current folder.") }
                actions: { Button("Open local folder…") { openLocal() }; Button("Browse GitHub repositories") { page = .repositories } }
            } else {
                HSplitView {
                    VStack(alignment: .leading, spacing: 10) {
                        switch page {
                        case .changes: changes
                        case .history: history
                        case .branches: branches
                        case .pulls: pullRequests
                        case .repositories: EmptyView()
                        }
                    }.frame(minWidth: 290, idealWidth: 340, maxWidth: 470)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(controller.diff.isEmpty ? "Select a file or comparison" : controller.compareSelection).font(.caption.weight(.medium)).lineLimit(2)
                            Spacer()
                            Menu("Ask AI") {
                                Button("Review these changes") { prepareAI(.review) }
                                Button("Explain merge risks") { prepareAI(.merge) }
                                Button("Draft pull request description") { prepareAI(.pullRequest) }
                            }.disabled(controller.diff.isEmpty || controller.busy || model.isWorking)
                        }.padding(.horizontal, 8)
                        if controller.diff.isEmpty { ContentUnavailableView("No diff selected", systemImage: "arrow.left.arrow.right", description: Text("Select a change, commit, branch comparison or pull request.")) }
                        else { CodeTextView(text: controller.diff).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }.frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxHeight: .infinity)
            }
            if controller.busy { HStack { ProgressView().controlSize(.small); Text("Working…").font(.caption); Spacer(); Button("Cancel") { controller.cancel() } } }
            if controller.snapshot?.mergeInProgress == true {
                HStack {
                    Text("Merge in progress. Resolve the conflicted files, stage them, and commit to finish.").font(.caption)
                    Spacer()
                    Button("Abort merge…") {
                        guard confirm("Abort this merge?", "Discard conflict-resolution edits from this merge and return to the pre-merge state.", action: "Abort merge") else { return }
                        Task { await controller.abortMerge() }
                    }.disabled(!localReady)
                }
            }
        }
        .task(id: root) { await controller.refreshAuth(); await controller.setProject(root: root) }
        .onChange(of: page) { if page == .repositories { Task { await controller.loadRepositories() } } }
        .sheet(isPresented: $showRepositoryForm) { repositoryForm }
        .sheet(isPresented: $showPRForm) { pullRequestForm }
        .sheet(item: $aiRequest) { request in
            AIAssistanceView(assistant: model.assistant, request: request, onUse: request.purpose == .commit || request.purpose == .pullRequest ? { text in
                if request.purpose == .commit { commitMessage = text }
                else { prBody = text }
            } : nil).environmentObject(model)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.snapshot?.repository ?? model.selectedProject?.name ?? "No project selected").font(.headline).lineLimit(1)
                Text("\(controller.snapshot?.branch ?? "") · ↑\(controller.snapshot?.ahead ?? 0) ↓\(controller.snapshot?.behind ?? 0)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { Task { await controller.refresh() } }.disabled(controller.busy || root == nil)
            Button("Fetch") { Task { await controller.fetch() } }.disabled(!remoteReady)
            Button("Pull") { Task { await controller.pull() } }.help("Fast-forward only; local changes must be committed first").disabled(!remoteReady)
            Button("Push…") {
                guard confirm("Push to GitHub?", "Push branch \(controller.snapshot?.branch ?? "") to \(controller.snapshot?.repository ?? ""). Local commits will be uploaded.", action: "Push") else { return }
                Task { await controller.push() }
            }.buttonStyle(.borderedProminent).disabled(!remoteReady)
            Menu {
                Button("Open local folder…") { openLocal() }
                Button("Clone from GitHub…") { page = .repositories }
                Button("Create new project on GitHub…") { createMode = true; repositoryName = ""; parentFolder = nil; showRepositoryForm = true }
                Button("Publish this folder on GitHub…") { createMode = false; repositoryName = model.selectedProject?.name ?? ""; showRepositoryForm = true }.disabled(root == nil || controller.snapshot?.remoteURL != nil)
            } label: { Image(systemName: "plus") }.disabled(controller.busy || model.isWorking)
        }
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(controller.snapshot?.changes.count ?? 0) changes").font(.headline)
                Spacer()
                Button("Stage all") {
                    let paths = Array(Set(controller.snapshot?.changes.filter { !$0.staged }.map(\.path) ?? []))
                    Task { await controller.stage(paths: paths) }
                }.disabled(!localReady)
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(controller.snapshot?.changes ?? []) { file in
                        HStack {
                            Button { Task { await compare(file.staged ? .staged(path: file.path) : .working(path: file.path), title: file.path) } } label: {
                                HStack { Text(file.kind.rawValue.prefix(1).uppercased()).font(.caption.monospaced()).foregroundStyle(file.staged ? .green : .orange); Text(file.path).lineLimit(1).truncationMode(.middle); Spacer() }
                            }.buttonStyle(.plain).disabled(controller.busy)
                            Button(file.staged ? "Unstage" : "Stage") {
                                Task { if file.staged { await controller.unstage(paths: [file.path]) } else { await controller.stage(paths: [file.path]) } }
                            }.controlSize(.small).disabled(!localReady)
                        }.padding(8).background(Studio.surface, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            Text("Commit staged changes · \(stagedCount) files").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $commitMessage).font(.system(size: 12)).frame(height: 85).border(Studio.line)
            HStack {
                Button("Suggest with AI") { Task { await compare(.staged(), title: "Staged changes"); prepareAI(.commit) } }.disabled(!localReady || stagedCount == 0)
                Spacer()
                Button("Commit") { Task { await controller.commit(message: commitMessage); if controller.error == nil { commitMessage = "" } } }
                    .disabled(!localReady || stagedCount == 0 || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var history: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(controller.commits) { commit in
                    Button { Task { await compare(.commit(commit.sha), title: commit.shortSHA + " · " + commit.subject) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(commit.subject).font(.callout.weight(.medium)).lineLimit(2)
                            Text(commit.shortSHA + " · " + commit.author + " · " + commit.date).font(.caption).foregroundStyle(.secondary)
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).disabled(controller.busy)
                }
            }
        }
    }

    private var branches: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { TextField("New branch name", text: $newBranch); Button("Create") { Task { await controller.createBranch(name: newBranch); if controller.error == nil { newBranch = "" } } }.disabled(!localReady || newBranch.isEmpty) }
            HStack { TextField("Base ref", text: $base); Text("→"); TextField("Head ref", text: $head) }
            HStack {
                Button("Compare branches") { Task { await compare(.branches(base: base, head: head), title: base + " → " + head) } }.disabled(!localReady)
                Button("Compare with pushed") { Task { await compare(.upstream, title: "Local changes against last fetched upstream") } }.disabled(!localReady || controller.snapshot?.upstream == nil)
            }
                Text(controller.lastFetchedAt.map { "Last fetched " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Fetch first to include the latest pushed commits. Comparisons use local Git references.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.branches) { branch in
                        HStack {
                            Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch").foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
                            Text(branch.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if !branch.isCurrent {
                                Menu {
                                    Button("Switch to branch") { Task { await controller.switchBranch(name: branch.name) } }
                                    Button("Merge into current branch…") {
                                        guard confirm("Merge \(branch.name)?", "Merge this branch into \(controller.snapshot?.branch ?? "") in the local repository. Push afterward to update GitHub. Any conflicts will remain visible for resolution.", action: "Merge") else { return }
                                        Task { await controller.mergeBranch(name: branch.name) }
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }.disabled(!localReady)
                            }
                        }.padding(6)
                    }
                }
            }
        }
    }

    private var pullRequests: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Open pull requests").font(.headline); Spacer(); Button("New pull request…") { showPRForm = true }.disabled(!remoteReady) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.pullRequests) { pr in
                        VStack(alignment: .leading, spacing: 7) {
                            Text("#\(pr.number) · \(pr.title)").font(.callout.weight(.medium))
                            Text(pr.headRefName + " → " + pr.baseRefName + " · " + pr.mergeStateStatus).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Review") { Task { await controller.loadPullRequestDiff(pr); diffTitle = "#\(pr.number) · \(pr.title)" } }.disabled(controller.busy)
                                if let url = URL(string: pr.url), url.host == "github.com" { Link("GitHub ↗", destination: url) }
                                Spacer()
                                Button("Merge…") {
                                    guard confirm("Merge pull request #\(pr.number)?", "Merge \(pr.headRefName) into \(pr.baseRefName) on GitHub. The reviewed head must still match \(pr.headRefOid.prefix(8)). GitHub branch rules remain in effect.", action: "Merge") else { return }
                                    Task { await controller.mergePullRequest(pr) }
                                }.disabled(!remoteReady || pr.isDraft || pr.state != "OPEN")
                            }
                        }.padding(12).background(Studio.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if controller.pullRequests.isEmpty { Text("No open pull requests. Refresh to check GitHub.").foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("GitHub URL or owner/repository", text: $cloneSource).textFieldStyle(.roundedBorder)
                Button("Clone repository…") { cloneFromSource() }
                    .disabled(controller.busy || model.isWorking || !controller.auth.isAuthenticated || cloneSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                TextField("Filter loaded repositories", text: $repositoryQuery).textFieldStyle(.roundedBorder)
                Button("Refresh") { Task { await controller.loadRepositories() } }.disabled(controller.busy || !controller.auth.isAuthenticated)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.repositories.filter { repositoryQuery.isEmpty || $0.fullName.localizedCaseInsensitiveContains(repositoryQuery) }) { repository in
                        HStack {
                            Image(systemName: repository.isPrivate ? "lock" : "globe")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(repository.fullName).font(.headline)
                                if let description = repository.description { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            Spacer()
                            Button("Clone…") { clone(repository) }.disabled(controller.busy || model.isWorking || !controller.auth.isAuthenticated)
                        }.padding(12).background(Studio.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if controller.hasMoreRepositories {
                        Button("Load more repositories") { Task { await controller.loadRepositories(reset: false) } }.disabled(controller.busy || !controller.auth.isAuthenticated)
                    }
                }
            }
        }.frame(maxHeight: .infinity)
    }

    private var repositoryForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(createMode ? "New GitHub project" : "Publish local folder").font(.title2)
            TextField("Repository name", text: $repositoryName).textFieldStyle(.roundedBorder)
            Toggle("Private repository", isOn: $privateRepository)
            Text("Owner: \(controller.auth.login ?? "Sign in first")").font(.callout)
            if createMode {
                HStack { Text(parentFolder?.path ?? "Choose a parent folder").lineLimit(2).textSelection(.enabled); Spacer(); Button("Choose…") { parentFolder = chooseFolder(prompt: "Create Project Here") } }
            } else { Text(root ?? "No folder selected").font(.callout).textSelection(.enabled) }
            Text("Create the GitHub repository and connect the local folder. Review and stage files in Changes, commit them, then push when ready.").font(.callout).foregroundStyle(.secondary)
            if let error = controller.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { showRepositoryForm = false }.disabled(controller.busy)
                Spacer()
                Button("Create repository") {
                    Task {
                        if createMode, let parentFolder {
                            if let url = await controller.createRepository(name: repositoryName, at: parentFolder.appendingPathComponent(repositoryName), privateRepository: privateRepository) {
                                showRepositoryForm = false; await model.openGitHubProject(url); page = .changes
                            }
                        } else if await controller.publish(name: repositoryName, privateRepository: privateRepository) { showRepositoryForm = false; page = .changes }
                    }
                }.buttonStyle(.borderedProminent).disabled(controller.busy || model.isWorking || !controller.auth.isAuthenticated || repositoryName.isEmpty || (createMode && parentFolder == nil))
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(controller.busy)
    }

    private var pullRequestForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create pull request").font(.title2)
            Text("\(controller.snapshot?.repository ?? "") · \(controller.snapshot?.branch ?? "") → \(base)").font(.caption)
            TextField("Title", text: $prTitle).textFieldStyle(.roundedBorder)
            TextField("Base branch", text: $base).textFieldStyle(.roundedBorder)
            TextEditor(text: $prBody).frame(height: 220).border(Studio.line)
            Toggle("Create as draft", isOn: $prDraft)
            Text("Push your branch before creating the pull request. Use Ask AI on a branch diff to draft this description.").font(.caption).foregroundStyle(.secondary)
            if let error = controller.error { Text(error).foregroundStyle(.red) }
            HStack { Button("Cancel") { showPRForm = false }.disabled(controller.busy); Spacer(); Button("Create pull request") { Task { await controller.createPullRequest(title: prTitle, body: prBody, base: base, draft: prDraft); if controller.error == nil { showPRForm = false } } }.buttonStyle(.borderedProminent).disabled(!remoteReady || prTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 640).interactiveDismissDisabled(controller.busy)
    }

    private func compare(_ value: GitComparison, title: String) async { await controller.compare(value); if controller.error == nil { diffTitle = title } }
    private func prepareAI(_ purpose: AIAssistanceRequest.Purpose) {
        guard !controller.diff.isEmpty, controller.error == nil else { return }
        aiRequest = .init(purpose: purpose, source: (controller.snapshot?.repository ?? model.selectedProject?.name ?? "Project") + " · " + controller.compareSelection, content: controller.diff, projectPath: root)
    }
    private func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true; panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func clone(_ repository: GitHubRepository) {
        guard let parent = chooseFolder(prompt: "Clone Here") else { return }
        Task { if let url = await controller.clone(repo: repository, to: parent.appendingPathComponent(repository.name)) { await model.openGitHubProject(url); page = .changes } }
    }
    private func cloneFromSource() {
        let source = cloneSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = GitHubService.githubRepository(source) ?? source
        do {
            try GitHubService.validateRepository(name)
            let shortName = String(name.split(separator: "/").last!)
            clone(.init(id: 0, name: shortName, fullName: name, isPrivate: false, url: "https://github.com/" + name, cloneURL: "https://github.com/" + name + ".git", defaultBranch: nil, description: nil))
        } catch { controller.error = error.localizedDescription }
    }
    private func openLocal() { guard let url = chooseFolder(prompt: "Open Project") else { return }; Task { await model.openGitHubProject(url) } }
    private func confirm(_ title: String, _ message: String, action: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

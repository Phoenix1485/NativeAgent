import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @EnvironmentObject private var updater: AppUpdater
    @AppStorage("showWorkspaceInspector") private var showInspector = false
    @State private var inspectorTab = "Files"
    @State private var showDiagnostics = false
    @State private var showConversationDetails = false
    @State private var showSidebar = true
    @StateObject private var fileBrowser: FileBrowserState
    @StateObject private var detachedFiles = DetachedFilesWindow()
    @State private var availableWidth: CGFloat = 1280
    @Environment(\.openSettings) private var openSettings

    init(fileBrowser: FileBrowserState? = nil) {
        _fileBrowser = StateObject(wrappedValue: fileBrowser ?? FileBrowserState())
    }

    var body: some View {
        workspaceLayout
            .sheet(isPresented: $updater.showWhatsNew, onDismiss: { updater.acknowledgeWhatsNew() }) { WhatsNewView().environmentObject(updater) }
            .sheet(item: Binding(get: { model.features.editingFile }, set: { model.features.editingFile = $0 })) { file in
                AttachedFileEditor(file: file, features: model.features).environmentObject(model)
            }
            .background(sessionObservers)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.markSelectedChatRead() } }
            .background(WindowFrameRestorer().frame(width: 0, height: 0))
            .sheet(isPresented: Binding(get: { model.features.paletteVisible || model.features.panel != nil }, set: { if !$0 { model.features.paletteVisible = false; model.features.panel = nil } })) {
                if model.features.paletteVisible { WorkspaceCommandPalette(features: model.features).environmentObject(model) }
                else { FeaturePanel(features: model.features).environmentObject(model) }
            }
            .task(id: showInspector || fileBrowser.showingTab || detachedFiles.isVisible) {
                await model.setInspectorVisible(showInspector || fileBrowser.showingTab || detachedFiles.isVisible)
            }
            .sheet(isPresented: $fileBrowser.quickOpenVisible) { QuickOpenFilesView(browser: fileBrowser).environmentObject(model) }
            .onChange(of: model.selectedProject?.id) { fileBrowser.reset() }
            .onChange(of: fileBrowser.showingTab) { NSApp.keyWindow?.makeFirstResponder(nil) }
            .background(GeometryReader { proxy in
                Color.clear.onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { availableWidth = proxy.size.width }
            })
            .alert("Something needs attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }

    private var workspaceLayout: some View {
        HStack(spacing: 0) {
            if showSidebar && (!(showInspector || fileBrowser.showingTab) || availableWidth >= 1100) {
                ProjectSidebarView().frame(width: 254).frame(maxHeight: .infinity)
                Rectangle().fill(Studio.line).frame(width: 1)
            }
            VStack(spacing: 0) {
                header
                Rectangle().fill(Studio.line).frame(height: 1)
                if fileBrowser.tabOpen {
                    workspaceTabs
                    Divider()
                }
                HSplitView {
                    ConversationView()
                        .frame(minWidth: conversationVisible ? 320 : 0, idealWidth: conversationVisible ? 450 : 0,
                               maxWidth: conversationVisible ? .infinity : 0, maxHeight: .infinity)
                        .frame(width: conversationVisible ? nil : 0)
                        .clipped().opacity(conversationVisible ? 1 : 0)
                        .allowsHitTesting(conversationVisible)
                        .accessibilityHidden(!conversationVisible)
                    if fileBrowser.tabOpen {
                        Group {
                            if model.selectedProject != nil {
                                FileBrowserView(browser: fileBrowser, expanded: true, active: fileBrowser.showingTab, onDetach: openDetachedFiles)
                            } else {
                                ContentUnavailableView {
                                    Label("Choose a working folder", systemImage: "folder")
                                } description: {
                                    Text("Open a folder to browse and search its files.")
                                } actions: {
                                    Button("Choose folder…") { model.openProject() }
                                }
                            }
                        }
                        .frame(minWidth: fileBrowser.showingTab ? 500 : 0, maxWidth: fileBrowser.showingTab ? .infinity : 0, maxHeight: .infinity)
                        .frame(width: fileBrowser.showingTab ? nil : 0, height: fileBrowser.showingTab ? nil : 0)
                        .clipped().opacity(fileBrowser.showingTab ? 1 : 0)
                        .allowsHitTesting(fileBrowser.showingTab)
                        .accessibilityHidden(!fileBrowser.showingTab)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showDiagnostics && conversationVisible {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Activity log", systemImage: "terminal").font(.caption.weight(.medium))
                            Spacer()
                            Button { showDiagnostics = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }
                        CommandOutputView(text: model.diagnosticMessages.isEmpty ? "No provider activity yet." : model.diagnosticMessages.suffix(20).joined(separator: "\n"))
                    }.padding(16).frame(height: 175).background(Studio.surface)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if showInspector && !fileBrowser.showingTab {
                Rectangle().fill(Studio.line).frame(width: 1)
                VStack(spacing: 0) {
                    HStack {
                        Picker("Inspector", selection: $inspectorTab) { Text("Files").tag("Files"); Text("Changes").tag("Changes") }.pickerStyle(.segmented)
                        Button { showInspector = false } label: { Image(systemName: "xmark") }.buttonStyle(QuietButtonStyle())
                    }.padding(12).frame(height: 64)
                    Divider()
                    if model.selectedProject == nil {
                        VStack(spacing: 12) {
                            Image(systemName: "folder").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                            Text("Your working files").font(.headline)
                            Text("Choose a folder to browse files\nand review changes.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Choose folder…") { model.openProject() }.buttonStyle(.bordered)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if inspectorTab == "Files" {
                        FileBrowserView(browser: fileBrowser, onExpand: {
                            fileBrowser.openTab()
                        }, onDetach: openDetachedFiles).frame(maxHeight: .infinity)
                    }
                    else { ChangesView().frame(maxHeight: .infinity) }
                }.frame(width: 300).frame(maxHeight: .infinity).background(Studio.sidebar)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Studio.canvas).tint(Studio.accent)
    }

    private var workspaceTabs: some View {
        HStack(spacing: 6) {
            Button { fileBrowser.showingTab = false } label: {
                Label("Chat", systemImage: "bubble.left")
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(!fileBrowser.showingTab ? Studio.hover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }.accessibilityLabel("Chat tab").accessibilityAddTraits(!fileBrowser.showingTab ? .isSelected : [])
            HStack(spacing: 8) {
                Button { fileBrowser.showingTab = true } label: {
                    Label("Files", systemImage: "doc.text")
                        .padding(.leading, 12).padding(.vertical, 8)
                }.accessibilityLabel("Files tab").accessibilityAddTraits(fileBrowser.showingTab ? .isSelected : [])
                Button {
                    fileBrowser.closeTab()
                } label: { Image(systemName: "xmark").font(.caption2).padding(6) }
                    .help("Close Files tab").accessibilityLabel("Close Files tab")
            }.padding(.trailing, 4)
                .background(fileBrowser.showingTab ? Studio.hover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            Spacer()
            Button {
                fileBrowser.showingTab = true
                fileBrowser.splitWithChat.toggle()
            } label: {
                Label(fileBrowser.splitWithChat ? "Code only" : "Chat + code", systemImage: "rectangle.split.2x1")
            }.help("Show the conversation beside code with resizable panels")
            Button(action: openDetachedFiles) { Image(systemName: "macwindow.on.rectangle") }
                .padding(.horizontal, 8).help("Open files in a separate window").accessibilityLabel("Open files in a separate window")
        }.font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6).background(Studio.sidebar)
    }

    private var sessionObservers: some View {
        Color.clear
            .onChange(of: model.features.session) {
                let session = model.features.session
                showInspector = session.inspector; showSidebar = session.sidebar; inspectorTab = session.inspectorTab; showDiagnostics = session.terminal
                model.features.scheduleSessionSave()
            }
            .onChange(of: showInspector) { model.features.session.inspector = showInspector }
            .onChange(of: showSidebar) { model.features.session.sidebar = showSidebar }
            .onChange(of: inspectorTab) { model.features.session.inspectorTab = inspectorTab }
            .onChange(of: showDiagnostics) { model.features.session.terminal = showDiagnostics }
            .background(selectionObservers)
    }

    private var selectionObservers: some View {
        Color.clear
            .onChange(of: model.selectedConversation?.id) { model.features.scheduleSessionSave() }
            .onChange(of: model.selectedProject?.id) { model.features.scheduleSessionSave() }
            .onChange(of: model.selectedFile?.relativePath) { model.features.scheduleSessionSave() }
            .onChange(of: model.features.panel) { model.features.scheduleSessionSave() }
            .onChange(of: model.features.selectedReport?.id) { model.features.scheduleSessionSave() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }.buttonStyle(QuietButtonStyle()).help("Toggle sidebar")
            HStack(spacing: 8) {
                if let group = model.selectedGroup {
                    Text(group.name).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text(model.selectedConversation?.title ?? (model.selectedGroup == nil ? "New chat" : "Overview")).fontWeight(.medium).lineLimit(1)
            }.font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 12)
            if let version = updater.availableVersion {
                Button { updater.checkForUpdates() } label: {
                    Label("Update \(version) available", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Studio.accent)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Studio.accent.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(Studio.accent.opacity(0.3)))
                .help("Download and install the NativeAgent update")
                .accessibilityHint("Opens the update installer")
            }
            HStack(spacing: 6) {
                Circle().fill(isReady ? Color.green.opacity(0.85) : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
                Text(model.github.busy ? "GitHub operation" : model.assistant.isRunning ? "AI review" : model.isWorking ? model.turnStatus.label : model.selectedAIRecipients.isEmpty ? model.connectionStatus.label : "\(model.selectedAIRecipients.count) AIs selected").font(.system(size: 11))
            }.foregroundStyle(.secondary)
            Button(!model.selectedAIRecipients.isEmpty ? "AI connections" : isReady ? "Disconnect" : "Connect") {
                if !model.selectedAIRecipients.isEmpty { model.showAIConnections = true }
                else { Task { if isReady { await model.disconnect() } else { await model.connect() } } }
            }
                .font(.system(size: 12, weight: .medium)).buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 7)
                .background(Studio.surface, in: Capsule()).overlay(Capsule().stroke(Studio.line))
                .disabled(model.connectionStatus == .connecting || model.accountActionInProgress || model.isWorking)
            Rectangle().fill(Studio.line).frame(width: 1, height: 18)
            Button { model.features.paletteVisible = true } label: { Image(systemName: "command") }.buttonStyle(QuietButtonStyle()).help("Command palette (⌘K)").accessibilityLabel("Command palette")
            Button { model.features.execute(.github) } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                .buttonStyle(QuietButtonStyle()).help("GitHub workspace").accessibilityLabel("GitHub workspace")
            Button { fileBrowser.quickOpenVisible = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                .buttonStyle(QuietButtonStyle()).keyboardShortcut("p", modifiers: .command)
                .disabled(model.selectedProject == nil).help("Quick Open file (⌘P)").accessibilityLabel("Quick Open file")
            Menu {
                Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                Link("Download NativeAgent…", destination: AppUpdater.downloadPageURL)
                Divider()
                ForEach(WorkspaceCommand.allCases) { command in
                    Button(command.title) { if command == .settings { openSettings() } else { model.features.execute(command) } }.disabled(!model.features.canExecute(command))
                }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("Workspace tools")
            Button { model.features.execute(.terminal) } label: { Image(systemName: "terminal") }.buttonStyle(QuietButtonStyle()).help("Activity log")
            Button { showConversationDetails.toggle() } label: { Image(systemName: "list.bullet.clipboard") }
                .buttonStyle(QuietButtonStyle()).help("Conversation details").accessibilityLabel("Conversation details")
                .popover(isPresented: $showConversationDetails, arrowEdge: .bottom) { ConversationDetailsView().environmentObject(model) }
            Button {
                if fileBrowser.showingTab { fileBrowser.showingTab = false; showInspector = true }
                else { showInspector.toggle() }
            } label: { Image(systemName: "sidebar.right") }.buttonStyle(QuietButtonStyle()).help("Files and changes").accessibilityLabel("Files and changes")
        }.padding(.horizontal, 18).frame(height: 64)
    }

    private var isReady: Bool { if case .ready = model.connectionStatus { true } else { false } }
    private var conversationVisible: Bool { !fileBrowser.showingTab || fileBrowser.splitWithChat }

    private func openDetachedFiles() { detachedFiles.open(model: model, browser: fileBrowser) }
}

import SwiftUI

private struct MessageFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

private struct TimelineBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ConversationView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @State private var editor: GroupEditorRequest?
    @State private var atBottom = true
    @FocusState private var composerFocused: Bool
    @State private var availableHeight: CGFloat = 820
    @State private var visiblePromptID: UUID?
    @State private var timelineHeight: CGFloat = 0
    @State private var showPlugins = false
    @State private var messageFrames: [UUID: CGRect] = [:]
    @State private var pagingIntent = HistoryPagingIntent()
    @State private var paging = false
    @State private var pagingRequest = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if !model.features.branches.isEmpty {
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                    ForEach(model.features.branches.prefix(3)) { link in
                        let isChild = link.id == model.selectedConversation?.id
                        Button(isChild ? "From: \(link.parentTitle)" : "Branch: \(link.branchTitle)") { Task { await model.features.openConversation(isChild ? link.parentID : link.id) } }.lineLimit(1).help(link.mode)
                    }
                    Spacer()
                    Text("Selected-context branches").foregroundStyle(.secondary)
                }.font(.caption).padding(.horizontal, 24).padding(.vertical, 8)
            }
            if model.timeline.isEmpty && (model.historyLoading || model.historyLoadError != nil) {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = model.historyLoadError {
                        Text("Couldn’t load this chat").font(.headline)
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry loading messages") { if let chat = model.selectedConversation { Task { await model.select(chat) } } }
                    } else { ConversationSkeleton() }
                    Spacer()
                }.frame(maxWidth: 680).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                composer.frame(maxWidth: 780).padding(.horizontal, 28).padding(.bottom, 22)
            } else if model.timeline.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        Spacer(minLength: 32)
                        intro
                        if model.selectedGroup != nil && model.selectedConversation == nil { groupContents }
                        else { starters }
                        composer
                        Text("Your workspace. Your conversations.").font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                    }.frame(maxWidth: 680).padding(.horizontal, 36).padding(.top, availableHeight < 700 ? 10 : 65).padding(.bottom, 40).frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                timeline.id(model.selectedConversation?.id)
                composer.frame(maxWidth: 780).padding(.horizontal, 28).padding(.bottom, 22).padding(.top, 12)
            }
        }.background(GeometryReader { proxy in
            Color.clear.onAppear { availableHeight = proxy.size.height }.onChange(of: proxy.size.height) { availableHeight = proxy.size.height }
        }).sheet(item: $editor) { GroupEditorView(request: $0) }
            .sheet(isPresented: $showPlugins) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("MCP plugins").font(.title2); Spacer(); Button("Done") { showPlugins = false }.keyboardShortcut(.cancelAction) }
                    ScrollView { MCPSettingsView(manager: model.features.mcp) }
                }.padding(24).frame(width: 680, height: 600)
            }
            .task(id: model.selectedConversation?.id) { await model.refreshConversationSummaries() }
            .onChange(of: model.selectedConversation?.id) { pagingIntent.reset(); messageFrames = [:]; paging = false; pagingRequest = UUID(); atBottom = true; visiblePromptID = nil }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: model.selectedGroup == nil ? "sparkle" : "folder.fill").foregroundStyle(Studio.accent)
                Text(model.selectedGroup == nil ? "LET’S MAKE SOMETHING" : "WORKSPACE GROUP")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary)
            }
            Text(model.selectedGroup?.name ?? "What are we building?").font(.system(size: 34, weight: .semibold)).tracking(-1)
            Text(model.selectedGroup == nil ? "A fresh idea, a tricky bug, or the next big thing.\nPick a folder and start a conversation." : "Keep the work in one place. Start a chat or add a folder.")
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
            if let group = model.selectedGroup {
                HStack(spacing: 12) {
                    Button { Task { await model.newConversation(in: group.id) } } label: { Label("New chat", systemImage: "plus") }.buttonStyle(.borderedProminent)
                    Button { editor = GroupEditorRequest(parentID: group.id) } label: { Label("New folder", systemImage: "folder.badge.plus") }.buttonStyle(.bordered)
                    Button { editor = GroupEditorRequest(parentID: group.parentID, editing: group) } label: { Image(systemName: "ellipsis") }.buttonStyle(QuietButtonStyle()).help("Edit group")
                }.controlSize(.large).padding(.top, 5)
            }
        }
    }

    private var starters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { starter("Build a feature", icon: "square.stack.3d.up", prompt: "Help me build a new feature in this project: "); starter("Find a bug", icon: "ant", prompt: "Help me investigate and fix this bug: "); starter("Explore the code", icon: "curlybraces", prompt: "Explore this codebase and explain its architecture.") }
            VStack(alignment: .leading, spacing: 8) { starter("Build a feature", icon: "square.stack.3d.up", prompt: "Help me build a new feature: "); starter("Explore the code", icon: "curlybraces", prompt: "Explore this codebase and explain its architecture.") }
        }
    }

    private func starter(_ title: String, icon: String, prompt: String) -> some View {
        Button { model.draft = prompt; composerFocused = true } label: {
            HStack(spacing: 8) { Image(systemName: icon).foregroundStyle(.secondary); Text(title) }
                .font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 11)
                .background(Studio.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Studio.line))
        }.buttonStyle(.plain)
    }

    private var groupContents: some View {
        VStack(spacing: 4) {
            ForEach(model.groups.filter { $0.parentID == model.selectedGroupID }) { group in
                Button { Task { await model.selectGroup(group.id) } } label: {
                    HStack { Label(group.name, systemImage: "folder"); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }.padding(12).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            ForEach(model.chats(in: model.selectedGroupID)) { chat in
                Button { Task { await model.select(chat) } } label: {
                    HStack { Label(chat.title, systemImage: "bubble.left"); Spacer(); Text(chat.updatedAt, style: .date).font(.caption).foregroundStyle(.tertiary) }.padding(12).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            ChatPageButton(groupID: model.selectedGroupID)
        }.font(.system(size: 13)).background(Studio.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if model.hasOlderMessages {
                        if model.historyLoadDirection == .older {
                            ConversationSkeleton(rows: 1, label: "Loading earlier messages…")
                        } else {
                            Button("Load earlier messages") { loadPage(.older, proxy: proxy) }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                                .disabled(model.historyLoading || paging).frame(maxWidth: .infinity)
                        }
                    }
                    if let error = model.historyLoadError { Text(error).font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.timeline) { item in
                        TimelineItemView(item: item).id(item.id)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: MessageFramesKey.self, value: [item.id: geometry.frame(in: .named("conversationTimeline"))])
                            })
                    }
                    ForEach(model.conversationApprovals) { approval in ApprovalView(approval: approval) }
                    if !model.conversationApprovals.isEmpty {
                        ForEach(model.conversationDetails.filter { ConversationFact.decode($0.detail)?.key.hasPrefix("change/") == true && ConversationFact.decode($0.detail)?.state == "proposed" }) { item in
                            DisclosureGroup("Proposed change · \(item.title)") {
                                Text(item.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Button("Full proposal") { Task { await model.navigateToMessage(item.id) } }
                            }
                        }
                    }
                    ForEach(model.conversationQuestions) { question in ProviderQuestionView(request: question) }
                    if model.hasNewerMessages {
                        if model.historyLoadDirection == .newer { ConversationSkeleton(rows: 1, label: "Loading newer messages…") }
                        else {
                            Button("Load newer messages") { loadPage(.newer, proxy: proxy) }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                                .disabled(model.historyLoading || paging).frame(maxWidth: .infinity)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom").background(GeometryReader { geometry in
                        Color.clear.preference(key: TimelineBottomKey.self, value: geometry.frame(in: .named("conversationTimeline")).maxY)
                    })
                }.frame(maxWidth: 780).padding(28).padding(.trailing, model.conversationPrompts.isEmpty ? 0 : 48).frame(maxWidth: .infinity)
                    .background(TimelineScrollActivity { direction in
                        pagingIntent.scroll(direction)
                        tryPaging(proxy: proxy)
                    })
            }
            .coordinateSpace(name: "conversationTimeline")
            .background(GeometryReader { geometry in
                Color.clear.onAppear { timelineHeight = geometry.size.height }.onChange(of: geometry.size.height) { timelineHeight = geometry.size.height }
            })
            .onPreferenceChange(TimelineBottomKey.self) { bottom in
                guard !paging, !model.historyLoading else { return }
                atBottom = !model.hasNewerMessages && bottom > 0 && bottom <= timelineHeight + 32
            }
            .onPreferenceChange(MessageFramesKey.self) { frames in
                messageFrames = frames
                tryPaging(proxy: proxy)
                guard let top = frames.filter({ $0.value.maxY > 8 }).min(by: { $0.value.minY < $1.value.minY }),
                      let index = model.timeline.firstIndex(where: { $0.id == top.key }) else { return }
                let id = PromptFisheye.currentPrompt(entryIndex: index, timeline: model.timeline, prompts: model.conversationPrompts)
                if visiblePromptID != id { visiblePromptID = id; if let id { model.features.session.readingPosition = id } }
            }
            .onKeyPress(.pageUp) { pagingIntent.scroll(.older); tryPaging(proxy: proxy); return .ignored }
            .onKeyPress(.pageDown) { pagingIntent.scroll(.newer); tryPaging(proxy: proxy); return .ignored }
            .onChange(of: model.navigationTarget) {
                guard let id = model.navigationTarget else { return }
                atBottom = false
                Task { @MainActor in
                    await Task.yield()
                    guard model.navigationTarget == id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .top) }
                    model.navigationTarget = nil
                }
            }
            .onAppear {
                if let target = model.navigationTarget { atBottom = false; proxy.scrollTo(target, anchor: .top); model.navigationTarget = nil }
                else { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.timeline.last?.text) { if atBottom && !model.hasNewerMessages { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.timeline.count) { if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
            .overlay(alignment: .bottom) {
                if !atBottom { Button { Task { if model.hasNewerMessages { await model.loadLatestMessages() }; proxy.scrollTo("bottom", anchor: .bottom) } } label: { Label("Latest messages", systemImage: "arrow.down") }.buttonStyle(.bordered).padding(8) }
            }
            .overlay(alignment: .trailing) {
                if !model.conversationPrompts.isEmpty {
                    ConversationMinimap(prompts: model.conversationPrompts, currentID: visiblePromptID, maximumHeight: min(356, timelineHeight - 28)) { id in
                        atBottom = false
                        Task { await model.navigateToMessage(id) }
                    }.id(model.selectedConversation?.id).padding(.trailing, 10)
                }
            }
        }
    }

    private func tryPaging(proxy: ScrollViewProxy) {
        guard model.historyLoadError == nil else { return }
        let first = model.timeline.first.flatMap { messageFrames[$0.id] }
        let last = model.timeline.last.flatMap { messageFrames[$0.id] }
        let direction = pagingIntent.take(nearTop: first.map { $0.minY >= -120 && $0.minY < timelineHeight } ?? false,
                                          nearBottom: last.map { $0.maxY <= timelineHeight + 120 && $0.maxY > 0 } ?? false,
                                          hasOlder: model.hasOlderMessages, hasNewer: model.hasNewerMessages,
                                          busy: paging || model.historyLoading)
        if let direction { loadPage(direction, proxy: proxy) }
    }

    private func loadPage(_ direction: HistoryPageDirection, proxy: ScrollViewProxy) {
        guard !paging, !model.historyLoading else { return }
        let chatID = model.selectedConversation?.id
        let visible = messageFrames.filter { $0.value.maxY > 0 && $0.value.minY < timelineHeight }.min { $0.value.minY < $1.value.minY }
        let anchor = visible?.key ?? (direction == .older ? model.timeline.first?.id : model.timeline.last?.id)
        let request = UUID(); pagingRequest = request
        paging = true; atBottom = false; pagingIntent.reset()
        Task { @MainActor in
            if direction == .older { await model.loadOlderMessages() } else { await model.loadNewerMessages() }
            guard model.selectedConversation?.id == chatID, pagingRequest == request else { return }
            await Task.yield()
            guard model.selectedConversation?.id == chatID, pagingRequest == request else { return }
            if let anchor, model.timeline.contains(where: { $0.id == anchor }) {
                var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(anchor, anchor: .top) }
            }
            paging = false
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { Task { await model.features.chooseAttachments() } } label: { Label("Attach", systemImage: "paperclip") }
                    .disabled(model.features.importingFiles || model.isWorking || model.settings.provider == .claude)
                    .help("Attach UTF-8 text and code files, or drop them here")
                Button("Plugins") { showPlugins = true }
                Button("Templates") { model.features.execute(.templates) }
                Button("Context (\(model.features.context.count))") { model.features.execute(.context) }
                Button("Queue draft") { Task { await model.features.enqueueDraft() } }.disabled(model.draft.isEmpty || !model.providerCapabilities.structuredStreaming)
                Spacer()
                if model.features.profile != nil { Button("Profile / overrides") { model.features.execute(.context) } }
            }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 12)
            AttachmentStrip(features: model.features)
            if model.features.importingFiles { ProgressView("Reading files…").controlSize(.small).padding(12) }
            if let notice = model.features.notice {
                HStack {
                    Text(notice).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button { model.features.notice = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss attachment notice")
                }.padding(12)
            }
            if model.settings.provider == .claude {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Official Claude Code terminal", systemImage: "terminal").font(.headline)
                    Text("Claude Code handles its models, conversation history, permissions and interruption in Terminal. This native chat’s draft and history stay here.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Open Claude Code") { Task { await model.openClaudeTerminal() } }.disabled(!claudeConnected || model.accountActionInProgress)
                        SettingsLink { Text("Connection settings…") }
                    }
                }.padding(16)
            }
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty { Text("Ask anything, or describe what you want to build…").font(.system(size: 14)).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.top, 8).allowsHitTesting(false) }
                TextEditor(text: $model.draft).font(.system(size: 14)).scrollContentBackground(.hidden).focused($composerFocused).frame(height: model.timeline.isEmpty ? 96 : 76)
                    .disabled(model.historyLoading || model.settings.provider == .claude)
                    .onChange(of: model.draft) { model.scheduleDraftSave() }
            }.padding(.horizontal, 15).padding(.top, 12)
            HStack(spacing: 10) {
                Button { model.openProject() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(model.selectedProject?.name ?? "Choose folder").lineLimit(1)
                        if model.selectedProject == nil { Image(systemName: "plus").font(.system(size: 9)) }
                    }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Studio.hover.opacity(0.65), in: Capsule())
                }.buttonStyle(.plain).disabled(model.selectedConversation?.remoteThreadID != nil).help(model.selectedProject?.canonicalPath ?? "Choose the working folder for this chat")
                Spacer(minLength: 0)
                ChatModelPicker()
                if model.isWorking {
                    Button { Task { await model.stop() } } label: { Image(systemName: "stop.fill").frame(width: 31, height: 31) }.buttonStyle(.plain).foregroundStyle(Studio.accent).help("Stop turn")
                } else {
                    Text("⌘ ↵").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Button { Task { await model.send() } } label: {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).foregroundStyle(model.canSend ? Color.white : Color.secondary).frame(width: 32, height: 32)
                            .background(model.canSend ? Studio.accent : Studio.hover, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).disabled(!model.canSend).help("Send message · ⌘Return").accessibilityLabel("Send message")
                }
            }.padding(13)
            if model.settings.provider != .claude, let chat = model.selectedConversation, chat.remoteThreadID != nil, chat.providerID != model.settings.provider {
                Text("Next message goes to \(model.settings.provider.title), with a bounded excerpt of this chat’s recent messages. Your chat stays here.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 15).padding(.bottom, 12)
            }
        }.background(Studio.surface, in: RoundedRectangle(cornerRadius: 16))
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.isWorking, !model.features.importingFiles, model.settings.provider != .claude, !urls.isEmpty else { return false }
                Task { await model.features.attachURLs(urls) }
                return true
            }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(composerFocused ? Studio.accent.opacity(0.5) : Studio.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 12, y: 4)
    }

    private var claudeConnected: Bool { if case .ready = model.connectionStatus { true } else { false } }
}

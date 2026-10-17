import SwiftUI

struct GroupEditorRequest: Identifiable {
    let id = UUID()
    var parentID: UUID?
    var editing: ChatGroup?
}

struct ProjectSidebarView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @State private var search = ""
    @State private var editor: GroupEditorRequest?
    @State private var showingArchive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 18)).foregroundStyle(Studio.accent)
                Text("NativeAgent").font(.system(size: 15, weight: .semibold))
                Spacer()
                Menu {
                    Button("New chat", systemImage: "square.and.pencil") { Task { await model.newConversation() } }
                    Button("New group", systemImage: "folder.badge.plus") { editor = GroupEditorRequest() }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Create chat or group")
            }.padding(.horizontal, 20).frame(height: 64)
            VStack(spacing: 8) {
                Button { Task { await model.newConversation() } } label: {
                    HStack {
                        Image(systemName: "square.and.pencil")
                        Text("New chat").fontWeight(.medium)
                        Spacer()
                        Text("⌘N").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.font(.system(size: 13)).padding(11).background(Studio.surface, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Studio.line))
                }.buttonStyle(.plain)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Search chats and groups", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }.padding(10)
            }.padding(.horizontal, 14).padding(.bottom, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if search.isEmpty && !model.pinnedChats.isEmpty {
                        sectionTitle("PINNED")
                        ForEach(model.pinnedChats) { chat in ChatSidebarRow(chat: chat) }
                    }
                    sectionTitle("GROUPS")
                    ForEach(model.groups.filter { search.isEmpty ? $0.parentID == nil : $0.name.localizedCaseInsensitiveContains(search) }) { group in
                        GroupTreeRow(group: group, editor: $editor, searching: !search.isEmpty)
                    }
                    if model.groups.isEmpty && search.isEmpty {
                        Button { editor = GroupEditorRequest() } label: { SidebarRow(title: "Create a group", icon: "folder.badge.plus") }.buttonStyle(.plain)
                        Text("Keep related chats together.\nAdd a folder when you need one.").font(.system(size: 11)).foregroundStyle(.tertiary).lineSpacing(3).padding(.horizontal, 10).padding(.bottom, 12)
                    }
                    sectionTitle(search.isEmpty ? "CHATS" : "MATCHING CHATS").padding(.top, 22)
                    ForEach(search.isEmpty ? model.chats(in: nil).filter { model.chatAttention[$0.id]?.pinned != true } : model.searchResults) { chat in ChatSidebarRow(chat: chat) }
                    if search.isEmpty { ChatPageButton(groupID: nil) }
                    else if model.searchLoading { ProgressView().controlSize(.small).padding(10) }
                    else if model.searchHasMore {
                        Button("Load more matches") { Task { await model.searchChats(search, more: true) } }.buttonStyle(.plain).font(.caption).padding(10)
                    }
                    if model.conversations.isEmpty && search.isEmpty {
                        Text("Your conversations will appear here.").font(.system(size: 11)).foregroundStyle(.tertiary).padding(10)
                    }
                    if !search.isEmpty && !model.searchLoading && model.searchResults.isEmpty && !model.groups.contains(where: { $0.name.localizedCaseInsensitiveContains(search) }) {
                        Text("No results for “\(search)”").font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                }.padding(.horizontal, 12).padding(.bottom, 20)
            }.frame(maxHeight: .infinity)
            Rectangle().fill(Studio.line).frame(height: 1).padding(.horizontal, 16)
            Button { showingArchive = true } label: {
                HStack { Label("Archive", systemImage: "archivebox"); Spacer(); Text("30 days").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 16)
            }.buttonStyle(.plain)
            HStack {
                SettingsLink { Label("Settings", systemImage: "gearshape") }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("LOCAL WORKSPACE").font(.system(size: 8, weight: .medium)).tracking(1).foregroundStyle(.tertiary)
            }.padding(20)
        }.frame(maxHeight: .infinity, alignment: .top).background(Studio.sidebar)
            .sheet(item: $editor) { GroupEditorView(request: $0) }
            .sheet(isPresented: $showingArchive) { ArchiveView() }
            .task(id: search) { await model.searchChats(search) }
    }

    private func sectionTitle(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(.tertiary)
            Spacer()
            if text == "GROUPS" {
                Button { editor = GroupEditorRequest() } label: { Image(systemName: "plus").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.secondary).help("New group")
            }
        }.padding(.horizontal, 10).padding(.bottom, 8)
    }
}

private struct GroupTreeRow: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let group: ChatGroup
    @Binding var editor: GroupEditorRequest?
    var searching = false
    @State private var targeted = false
    private var expanded: Bool { model.expandedGroupIDs.contains(group.id) || searching }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button { model.expand(group.id, expanded: !expanded) } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 34).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel(expanded ? "Collapse \(group.name)" : "Expand \(group.name)")
                Button { Task { await model.selectGroup(group.id) } } label: {
                    SidebarRow(title: group.name, icon: group.parentID == nil ? "folder.fill" : "folder", selected: model.selectedGroupID == group.id && model.selectedConversation == nil, tint: Studio.accent.opacity(0.8))
                }.buttonStyle(.plain)
            }.background(targeted ? Studio.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contextMenu {
                Button("New chat", systemImage: "square.and.pencil") { Task { await model.newConversation(in: group.id) } }
                Button("New folder", systemImage: "folder.badge.plus") { editor = GroupEditorRequest(parentID: group.id) }
                Divider()
                Button("Edit group…", systemImage: "pencil") { editor = GroupEditorRequest(parentID: group.parentID, editing: group) }
                Menu("Move to") {
                    Button("Top level") { Task { await model.moveGroup(group, to: nil) } }
                    ForEach(model.groups.filter { $0.id != group.id && !model.groupPath($0.id).hasPrefix(model.groupPath(group.id) + " / ") }) { target in
                        Button(model.groupPath(target.id)) { Task { await model.moveGroup(group, to: target.id) } }
                    }
                }
                if !model.groups.contains(where: { $0.parentID == group.id }) && !model.conversations.contains(where: { $0.groupID == group.id }) {
                    Button("Remove empty group", role: .destructive) { Task { await model.removeGroup(group) } }
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let value = items.first, let id = UUID(uuidString: value), let chat = model.conversations.first(where: { $0.id == id }) else { return false }
                Task { await model.moveConversation(chat, to: group.id) }
                return true
            } isTargeted: { targeted = $0 }
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.groups.filter { $0.parentID == group.id }) { child in AnyView(GroupTreeRow(group: child, editor: $editor)) }
                    ForEach(model.chats(in: group.id)) { chat in ChatSidebarRow(chat: chat) }
                    ChatPageButton(groupID: group.id)
                    if !model.groups.contains(where: { $0.parentID == group.id }) && !model.conversations.contains(where: { $0.groupID == group.id }) {
                        Button("Add a chat") { Task { await model.newConversation(in: group.id) } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 7)
                    }
                }.padding(.leading, 18)
            }
        }.task(id: expanded) { if expanded { await model.loadChats(in: group.id) } }
    }
}

struct ChatSidebarRow: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let chat: Conversation
    @State private var hovering = false
    @State private var menuRequest = UUID()
    @StateObject private var hoverRegion = SidebarHoverRegion()

    private var actions: [SidebarChatMenu.Item] { SidebarChatMenu.items(chat: chat, model: model) }
    var body: some View {
        if model.renamingConversationID == chat.id {
            ChatRenameEditor(chat: chat).environmentObject(model)
        } else {
            HStack(spacing: 0) {
                Button {
                    if NSEvent.modifierFlags.contains(.option) { menuRequest = UUID() }
                    else { Task { await model.select(chat) } }
                } label: {
                    HStack(spacing: 9) {
                        if model.chatIsWorking(chat.id) {
                            ProgressView().controlSize(.mini).frame(width: 18).help("This chat is working").accessibilityLabel("Chat working")
                        } else if model.chatAttention[chat.id]?.unread == true {
                            Circle().fill(Studio.accent).frame(width: 7, height: 7).frame(width: 18).help("Unread reply").accessibilityLabel("Unread reply")
                        } else { Image(systemName: model.chatAttention[chat.id]?.pinned == true ? "pin" : "bubble.left").frame(width: 18) }
                        ScrollingChatTitle(title: chat.title)
                    }.font(.system(size: 13)).foregroundStyle(model.selectedConversation?.id == chat.id ? Studio.accent : .secondary)
                        .padding(.leading, 10).padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain).draggable(chat.id.uuidString)
                SidebarChatMenu(items: actions, label: "Actions for \(chat.title)", rowHovered: hovering, request: menuRequest, hoverRegion: hoverRegion)
                    .frame(width: 28, height: 30).padding(.trailing, 4)
            }
            .background(model.selectedConversation?.id == chat.id ? Studio.accent.opacity(0.12) : hovering ? Studio.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
            .background(SidebarHoverRegionView(region: hoverRegion))
            .onHover { hovering = $0 }
            .contextMenu { SidebarChatMenuContent(items: actions) }
        }
    }
}

struct ChatPageButton: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let groupID: UUID?
    @State private var loading = false
    var body: some View {
        if model.libraryHasMore.contains(groupID?.uuidString ?? "root") {
            Button(loading ? "Loading…" : "Load older chats") {
                loading = true
                Task { await model.loadChats(in: groupID, more: true); loading = false }
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).padding(10).disabled(loading)
        }
    }
}

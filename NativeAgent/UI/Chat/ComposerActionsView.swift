import SwiftUI

struct ComposerActionsView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    var dismiss: () -> Void
    var query: String
    var highlightedID: String? = nil
    private var matches: [AIRecipient] {
        model.aiRecipients.filter { query.isEmpty || ($0.name + " " + $0.model).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
        ScrollViewReader { proxy in
        ScrollView {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ADD TO THIS REQUEST").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close actions")
            }.padding(8)
            if query.isEmpty || "attach files".localizedCaseInsensitiveContains(query) {
                action("Attach files", detail: "Add text or code context", icon: "paperclip") { dismiss(); Task { await model.features.chooseAttachments() } }
            }
            if query.isEmpty || "plan mode".localizedCaseInsensitiveContains(query) {
                action("Plan mode", detail: "Read-only work; no approved edits", icon: "list.bullet.clipboard") { model.settings.access = .readOnly; dismiss() }
            }
            if query.isEmpty || "prompt templates".localizedCaseInsensitiveContains(query) {
                action("Prompt templates", detail: "Start with a saved instruction", icon: "text.badge.plus") { dismiss(); model.features.execute(.templates) }
            }
            Divider().padding(.vertical, 5)
            HStack {
                Text("ASK YOUR AIs").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                if !model.selectedAIRecipients.isEmpty { Button("Clear") { model.selectedAIRecipients = [] }.font(.caption) }
            }.padding(8)
                VStack(spacing: 4) {
                    ForEach(matches) { recipient in
                        Button {
                            if model.selectedAIRecipients.contains(recipient.id) { model.selectedAIRecipients.remove(recipient.id) }
                            else { model.selectedAIRecipients.insert(recipient.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: model.selectedAIRecipients.contains(recipient.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Studio.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(recipient.name + " · " + recipient.model).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(recipient.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }.padding(10).contentShape(Rectangle())
                                .background(model.selectedAIRecipients.contains(recipient.id) ? Studio.accent.opacity(0.12) : Studio.hover.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(highlightedID == recipient.id ? Studio.accent.opacity(0.5) : .clear))
                        }.buttonStyle(.plain).id(recipient.id).accessibilityAddTraits(model.selectedAIRecipients.contains(recipient.id) ? .isSelected : [])
                    }
                    if matches.isEmpty { Text("No matching AI. Add an API connection or connect a supported account.").font(.caption).foregroundStyle(.secondary).padding(10) }
                }
            Text("Select one for a reply, or several for independent reviews. Separate usage charges may apply.").font(.caption).foregroundStyle(.secondary).padding(8)
        }.padding(10).frame(maxWidth: .infinity)
        }.onChange(of: highlightedID) { if let highlightedID { proxy.scrollTo(highlightedID) } }
        }
        Divider()
        HStack {
            Button("Manage connections…") { dismiss(); model.showAIConnections = true }
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }.padding(14)
        }.background(Studio.sidebar, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Studio.line))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            .buttonStyle(.plain)
    }

    private func action(_ title: String, detail: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 20).foregroundStyle(Studio.accent)
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }.padding(10).contentShape(Rectangle()).background(Studio.hover.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

import SwiftUI

struct ChatModelPicker: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @State private var presented = false
    @State private var showingEffort = false

    private var unavailable: Bool {
        model.isWorking || model.accountActionInProgress || model.modelSwitching || model.connectionStatus == .connecting
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                showingEffort = false; presented = true
            } label: {
                HStack(spacing: 7) {
                    Text(model.settings.provider == .claude ? "Claude Code terminal" : model.selectedProviderModel?.displayName ?? "Choose model")
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }.padding(.leading, 12).padding(.trailing, 9).frame(height: 32).contentShape(Rectangle())
            }.accessibilityLabel("Select model")
            if model.settings.provider != .claude, model.selectedProviderModel != nil {
                Rectangle().fill(Studio.line).frame(width: 1, height: 14)
                Button {
                    showingEffort = true; presented = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt").font(.system(size: 10))
                        Text(ModelEffort.title(model.selectedReasoning)).lineLimit(1)
                    }.foregroundStyle(Studio.accent).padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
                }.accessibilityLabel("Speed and thinking effort: \(ModelEffort.title(model.selectedReasoning))")
                    .help("Balance reply speed and thinking effort")
            }
        }.font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
            .background(Studio.hover.opacity(0.75), in: Capsule())
            .overlay(Capsule().strokeBorder(Studio.line))
            .frame(maxWidth: 290, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
            .disabled(unavailable)
            .popover(isPresented: $presented, arrowEdge: .top) {
                ChatModelPickerPanel(showingEffort: $showingEffort) { presented = false }
                    .environmentObject(model)
                    .accentColor(model.settings.accent.color).tint(model.settings.accent.color)
            }
            .onChange(of: unavailable) { if unavailable { presented = false } }
    }
}

struct ChatModelPickerPanel: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    @Binding var showingEffort: Bool
    var dismiss: () -> Void
    @State private var browsingProvider: ProviderKind?

    private var provider: ProviderKind { browsingProvider ?? model.settings.provider }

    var body: some View {
        VStack(spacing: 0) {
            if showingEffort {
                HStack {
                    Button { showingEffort = false } label: { Label("Models", systemImage: "chevron.left") }
                    Spacer()
                    Text("SPEED & THINKING").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                }.font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 18).padding(.top, 16)
                if let selected = model.selectedProviderModel, model.settings.provider != .claude {
                    ModelEffortControl(model: selected, selection: Binding(get: { model.selectedReasoning }, set: { model.selectedReasoning = $0 }))
                } else {
                    Text("Choose a native chat model to adjust thinking effort.").font(.caption).foregroundStyle(.secondary).padding(20)
                }
            } else {
                modelList
            }
        }.frame(width: 340).background(Studio.surface)
            .onExitCommand(perform: dismiss)
            .disabled(model.isWorking || model.accountActionInProgress || model.modelSwitching || model.connectionStatus == .connecting)
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Select model").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    ForEach(ProviderKind.allCases) { kind in
                        Button(kind.title) { browsingProvider = kind }
                    }
                } label: { Text(provider.title).font(.system(size: 10)) }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                    .accessibilityLabel("Browse provider models")
            }.padding(.horizontal, 8).padding(.top, 6)

            if provider == .claude {
                ModelChoiceRow(title: "Claude Code terminal", subtitle: "Models are managed in the official terminal", selected: model.settings.provider == .claude) {
                    dismiss()
                    Task { await model.useProvider(.claude); await model.connect() }
                }
            } else {
                let items = model.settings.enabledModels(provider)
                if let defaultID = model.settings.resolvedDefault(provider) {
                    ModelChoiceRow(title: "Default", subtitle: "Use your default from Settings", selected: false, symbol: "sparkles") {
                        choose(defaultID, provider: provider)
                    }
                    Divider().padding(.horizontal, 8)
                }
                if items.isEmpty {
                    Text("No enabled models. Connect this provider or manage models in Settings.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                } else {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(items) { item in
                                ModelChoiceRow(title: item.displayName, selected: model.settings.provider == provider && model.selectedModelID == item.id,
                                               symbol: model.settings.profile(provider).starredModels.contains(item.id) ? "star.fill" : nil) {
                                    choose(item.id, provider: provider)
                                }
                            }
                        }
                    }.scrollIndicators(.visible).frame(height: min(260, CGFloat(items.count) * 39))
                }
            }

            Divider().padding(.horizontal, 8)
            if model.settings.provider != .claude, model.selectedProviderModel != nil {
                Button { showingEffort = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt").foregroundStyle(Studio.accent)
                        Text("Speed & thinking")
                        Spacer()
                        Text(ModelEffort.title(model.selectedReasoning)).foregroundStyle(Studio.accent)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.font(.system(size: 12)).padding(10).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            SettingsLink { Label("Manage accounts & models…", systemImage: "slider.horizontal.3").font(.system(size: 11)).foregroundStyle(.secondary) }
                .buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 6)
        }.padding(10)
    }

    private func choose(_ id: String, provider: ProviderKind) {
        dismiss()
        Task { await model.chooseModel(id, provider: provider) }
    }
}

private struct ModelChoiceRow: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool
    var symbol: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Studio.accent) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Studio.accent) }
            }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Studio.accent.opacity(0.12) : hovering ? Studio.hover : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityValue(selected ? "Selected" : "")
    }
}

struct ModelEffortControl: View {
    let model: ProviderModel
    @Binding var selection: String
    private var levels: [String] { ModelEffort.levels(model.reasoningEfforts) }
    private var effective: String? {
        if levels.contains(selection) { return selection }
        return model.defaultReasoningEffort.flatMap { levels.contains($0) ? $0 : nil }
    }
    private var title: String {
        if selection.isEmpty, let effective { return "Auto · " + ModelEffort.title(effective) }
        return ModelEffort.title(levels.contains(selection) ? selection : "")
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "bolt").font(.system(size: 19)).foregroundStyle(Studio.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 21, weight: .medium)).foregroundStyle(Studio.accent)
                    Text(model.displayName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { selection = "" } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 15)).frame(width: 30, height: 30)
                }.buttonStyle(.plain).disabled(selection.isEmpty)
                    .help("Reset to the model’s automatic thinking effort").accessibilityLabel("Reset thinking effort to Auto")
            }
            if !levels.isEmpty {
                EffortSlider(levels: levels, effective: effective, selection: $selection)
                HStack {
                    Label("Faster", systemImage: "bolt.fill")
                    Spacer()
                    Label("More thinking", systemImage: "sparkles")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Text("More thinking may take longer. Saved for this model; Auto uses its default.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This model does not advertise adjustable thinking effort. It will use its automatic settings.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18)
    }
}

private struct EffortSlider: View {
    let levels: [String]
    let effective: String?
    @Binding var selection: String
    @FocusState private var focused: Bool
    private var index: Int? { effective.flatMap { levels.firstIndex(of: $0) } }

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 34)
            let fraction = index.map { Double($0) / Double(max(1, levels.count - 1)) }
            ZStack(alignment: .leading) {
                Capsule().fill(Studio.hover)
                if let fraction {
                    Capsule().fill(Studio.accent.opacity(selection.isEmpty ? 0.35 : 0.8)).frame(width: 34 + travel * fraction)
                }
                ForEach(Array(levels.enumerated()), id: \.element) { offset, _ in
                    Circle().fill(Color.primary.opacity(0.24)).frame(width: 4, height: 4)
                        .offset(x: 15 + travel * Double(offset) / Double(max(1, levels.count - 1)))
                }
                if let fraction {
                    Circle().fill(.white).frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1).offset(x: 3 + travel * fraction)
                }
            }.frame(height: 34).contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    focused = true
                    if let index = ModelEffort.index(at: (value.location.x - 17) / travel, count: levels.count) { selection = levels[index] }
                })
        }.frame(height: 34)
            .overlay(Capsule().strokeBorder(focused ? Studio.accent : Studio.line, lineWidth: 1))
            .focusable().focused($focused).focusEffectDisabled()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Thinking effort")
            .accessibilityValue(selection.isEmpty ? "Auto" : ModelEffort.title(selection))
            .accessibilityHint("Lower effort favors speed; higher effort allows more thinking")
            .accessibilityAdjustableAction { direction in
                switch direction { case .increment: move(1); case .decrement: move(-1); @unknown default: break }
            }
            .onKeyPress(.rightArrow) { move(1); return .handled }
            .onKeyPress(.leftArrow) { move(-1); return .handled }
    }

    private func move(_ delta: Int) {
        guard !levels.isEmpty else { return }
        let next = index.map { min(levels.count - 1, max(0, $0 + delta)) } ?? (delta > 0 ? 0 : levels.count - 1)
        selection = levels[next]
    }
}

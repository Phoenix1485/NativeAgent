import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct UsageSettingsView: View {
    @ObservedObject var controller: UsageController
    var selectedConversation: Conversation?
    var quotaWindows: [ProviderUsageWindow] = []
    @State private var breakdown: BreakdownKind = .providers
    @State private var showAllBreakdowns = false
    @State private var exportTask: Task<Void, Never>?

    private enum BreakdownKind: String, CaseIterable, Identifiable {
        case providers = "Provider", models = "Model", conversations = "Chat", activities = "Activity"
        var id: String { rawValue }
    }
    private struct LoadIdentity: Equatable {
        var selection: UsageSelection
        var conversationID: UUID?
    }
    private var identity: LoadIdentity { LoadIdentity(selection: controller.selection, conversationID: selectedConversation?.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            filters
            if let notice = controller.notice {
                Label(notice, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = controller.captureError {
                Label("Some usage could not be saved: " + error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let summary = controller.summary {
                totals(summary)
                dailyChart(summary)
                breakdowns(summary)
                currentChat
                if !quotaWindows.isEmpty { planLimits }
                recentRequests
                trackingNote(summary)
            } else if controller.loading {
                HStack { ProgressView().controlSize(.small); Text("Loading local usage…").foregroundStyle(.secondary) }.padding(.vertical, 32)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: identity) { await controller.load(conversationID: selectedConversation?.id) }
        .onDisappear { exportTask?.cancel(); controller.deactivate() }
        .accessibilityIdentifier("usage-settings-dashboard")
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("LOCAL TOKEN USAGE", systemImage: "chart.bar.xaxis").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Studio.accent)
                Spacer()
                if controller.loading { ProgressView().controlSize(.mini) }
                Button { Task { await controller.load(conversationID: selectedConversation?.id) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh usage").disabled(controller.loading)
                if controller.exporting {
                    Button("Cancel export") { exportTask?.cancel() }
                } else {
                    Button { chooseExport() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                        .disabled(controller.summary == nil || controller.loading)
                }
            }
            Picker("Date range", selection: $controller.selection.range) {
                ForEach(UsageDateRange.allCases) { range in Text(range.rawValue).tag(range) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Usage date range")
            if controller.selection.range == .custom {
                HStack(spacing: 18) {
                    DatePicker("From", selection: $controller.selection.customStart, displayedComponents: .date)
                    DatePicker("Through", selection: $controller.selection.customEnd, displayedComponents: .date)
                }
            }
            HStack(spacing: 16) {
                Picker("Provider", selection: Binding(get: { controller.selection.provider }, set: controller.selectProvider)) {
                    Text("All providers").tag("")
                    ForEach(controller.catalog?.providers ?? []) { item in Text(item.label).tag(item.id) }
                }.frame(maxWidth: .infinity)
                Picker("Model", selection: $controller.selection.model) {
                    Text("All models").tag(Optional<String>.none)
                    ForEach(modelNames, id: \.self) { name in Text(name.isEmpty ? "Unspecified model" : name).tag(Optional(name)) }
                }.frame(maxWidth: .infinity)
            }.font(.system(size: 12))
            if let started = controller.summary?.trackingStartedAt {
                Text("Local tracking since \(started.formatted(date: .abbreviated, time: .omitted)). Earlier provider history is unavailable; unreported usage is not zero.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let note = controller.exportNotice { Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    private var modelNames: [String] { Array(Set(controller.modelOptions.map(\.label))).sorted() }

    private func totals(_ summary: UsageSummary) -> some View {
        let totals = summary.totals
        return card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reported tokens").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(tokenText(totals.reportedCount == 0 ? nil : totals.tokens.totalTokens)).font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit().tracking(-1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("\(totals.recordCount.formatted()) requests").font(.system(size: 14, weight: .medium)).monospacedDigit()
                    Text("\(totals.reportedCount.formatted()) reported · \(totals.missingCount.formatted()) unreported")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if totals.recordCount > 0 {
                ProgressView(value: Double(totals.reportedCount), total: Double(totals.recordCount)).tint(Studio.accent)
                    .accessibilityLabel("Usage reporting coverage").accessibilityValue("\(totals.reportedCount) of \(totals.recordCount) requests")
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 18) {
                metric("Input", value: totals.reportedCount == 0 ? nil : totals.tokens.inputTokens, icon: "arrow.down.left")
                metric("Output", value: totals.reportedCount == 0 ? nil : totals.tokens.outputTokens, icon: "arrow.up.right")
                metric("Cache read", value: totals.tokens.cachedInputTokens, icon: "tray.and.arrow.down")
                metric("Cache write", value: totals.tokens.cacheWriteInputTokens, icon: "tray.and.arrow.up")
                metric("Reasoning", value: totals.tokens.reasoningOutputTokens, icon: "sparkle")
            }
            Text("Total = input + output. Cache counts are part of input; reasoning is part of output. These details are only shown when reported.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metric(_ title: String, value: Int64?, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(tokenText(value)).font(.system(size: 19, weight: .medium, design: .rounded)).monospacedDigit()
                .accessibilityLabel(title + ": " + (value.map { $0.formatted() } ?? "Not reported"))
        }
    }

    private func dailyChart(_ summary: UsageSummary) -> some View {
        let days = chartDays(summary)
        return card {
            HStack {
                Text("Daily activity").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Local calendar days").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if days.isEmpty {
                emptyState("No reported usage in this range", detail: "Requests without token counts stay in the activity list.", icon: "chart.bar")
            } else {
                Chart(days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.input))
                        .foregroundStyle(by: .value("Direction", "Input"))
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.output))
                        .foregroundStyle(by: .value("Direction", "Output"))
                }
                .chartForegroundStyleScale(["Input": Studio.accent, "Output": Studio.accent.opacity(0.42)])
                .chartYAxis { AxisMarks(position: .leading) }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 14)
                .frame(height: 190)
                .accessibilityLabel("Daily reported input and output tokens")
            }
            if summary.dailyIsTruncated { Text("Chart shows up to 3,660 days. Totals and CSV include the full selected range.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private struct ChartDay: Identifiable {
        var date: Date
        var input: Int64
        var output: Int64
        var id: Date { date }
    }
    private func chartDays(_ summary: UsageSummary) -> [ChartDay] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        return summary.daily.compactMap { item in
            guard item.aggregate.reportedCount > 0, let date = formatter.date(from: item.day) else { return nil }
            return ChartDay(date: date, input: item.aggregate.tokens.inputTokens, output: item.aggregate.tokens.outputTokens)
        }
    }

    private func breakdowns(_ summary: UsageSummary) -> some View {
        let items: [UsageBreakdown] = switch breakdown {
        case .providers: summary.providers
        case .models: summary.models
        case .conversations: summary.conversations
        case .activities: summary.activities
        }
        return card {
            HStack {
                Text("Breakdown").font(.system(size: 14, weight: .semibold))
                Spacer()
                Picker("Group usage by", selection: $breakdown) {
                    ForEach(BreakdownKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 310)
            }
            if items.isEmpty {
                emptyState("No matching requests", detail: "Try another date range or clear the provider and model filters.", icon: "line.3.horizontal.decrease.circle")
            } else {
                HStack { Text(breakdown.rawValue); Spacer(); Text("Requests").frame(width: 72, alignment: .trailing); Text("Tokens").frame(width: 100, alignment: .trailing) }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                ForEach(Array(items.prefix(showAllBreakdowns ? 100 : 8))) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(breakdown == .activities ? displayLabel(item.label) : item.label).font(.system(size: 12, weight: .medium)).lineLimit(1).help(item.label)
                            if let provider = item.provider, breakdown == .models { Text(provider).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                            GeometryReader { geometry in
                                Capsule().fill(Studio.accent.opacity(0.65))
                                    .frame(width: max(2, geometry.size.width * fraction(item.aggregate.tokens.totalTokens, of: summary.totals.tokens.totalTokens)))
                            }.frame(height: 3).accessibilityHidden(true)
                        }
                        Spacer(minLength: 0)
                        Text(item.aggregate.recordCount.formatted()).frame(width: 72, alignment: .trailing)
                        Text(tokenText(item.aggregate.reportedCount == 0 ? nil : item.aggregate.tokens.totalTokens)).frame(width: 100, alignment: .trailing)
                    }.font(.system(size: 12)).monospacedDigit().padding(.vertical, 5)
                }
                if items.count > 8 { Button(showAllBreakdowns ? "Show fewer" : "Show all \(items.count)") { showAllBreakdowns.toggle() }.font(.caption) }
            }
            if summary.breakdownsAreTruncated { Text("Breakdowns show the leading 100 entries per category. Export CSV for every request.").font(.caption).foregroundStyle(.secondary) }
        }.onChange(of: breakdown) { showAllBreakdowns = false }
    }

    private var currentChat: some View {
        card {
            HStack {
                Label("Current chat", systemImage: "bubble.left").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("All time · all providers").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let conversation = selectedConversation {
                Text(conversation.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                if let totals = controller.currentChat?.totals {
                    HStack {
                        Text(tokenText(totals.reportedCount == 0 ? nil : totals.tokens.totalTokens) + " reported tokens").font(.system(size: 15, weight: .medium)).monospacedDigit()
                        Spacer()
                        Text("\(totals.reportedCount) / \(totals.recordCount) requests reported").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                if let context = controller.context {
                    Text(context.contextTokens == nil ? "Latest request input" : "Latest provider-reported context").font(.system(size: 12, weight: .medium))
                    HStack(alignment: .firstTextBaseline) {
                        Text(tokenText(context.contextTokens ?? context.tokens?.inputTokens) + " tokens").font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                        if context.contextTokens != nil, let limit = context.contextLimit {
                            Text("of \(limit.formatted()) limit").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if context.contextTokens == nil, let limit = context.contextLimit {
                        Text("Reported context limit: \(limit.formatted()) tokens").font(.caption).foregroundStyle(.secondary)
                    }
                    if let count = context.contextTokens, let limit = context.contextLimit, limit > 0 {
                        ProgressView(value: min(Double(count), Double(limit)), total: Double(limit)).tint(Studio.accent)
                    }
                    Text("\(context.provider) · \(context.model) · \(context.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    Text(context.contextTokens == nil
                         ? "The most recent request’s input count is not a context capacity measurement or cumulative chat total. The provider has not reported current context occupancy."
                         : "This is the last reported context snapshot, not cumulative chat usage. Compaction and provider behavior can change it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("This provider has not reported context usage for this chat. No token estimate or context limit is assumed.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else { Text("Select a chat to see its recorded usage and any provider-reported context.").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var planLimits: some View {
        card {
            Label("Provider plan limits", systemImage: "gauge.with.dots.needle.50percent").font(.system(size: 14, weight: .semibold))
            Text("These live quota windows are separate from NativeAgent’s token totals.").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(quotaWindows) { window in
                HStack {
                    Text(window.durationMinutes.map { "\($0.formatted()) minute window" } ?? window.id).font(.system(size: 12))
                    Spacer()
                    Text("\(window.usedPercent)% used").font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                ProgressView(value: Double(min(100, max(0, window.usedPercent))), total: 100).tint(Studio.accent)
                if let reset = window.resetsAt { Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var recentRequests: some View {
        card {
            HStack {
                Text("Recent requests").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Newest first").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if controller.recent.isEmpty {
                Text("New requests will appear here after they finish.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(controller.recent) { record in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: record.tokens == nil ? "questionmark.circle" : "checkmark.circle")
                        .foregroundStyle(record.tokens == nil ? Color.secondary : Studio.accent).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.model.isEmpty ? "Unspecified model" : record.model).font(.system(size: 12, weight: .medium)).lineLimit(1).help(record.model)
                        Text("\(record.provider) · \(displayLabel(record.activity))").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(record.tokens.map { $0.totalTokens.formatted() } ?? "Not reported").font(.system(size: 12, weight: .medium)).monospacedDigit()
                        if let tokens = record.tokens { Text("\(tokens.inputTokens.formatted()) in · \(tokens.outputTokens.formatted()) out").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }.padding(.vertical, 6)
                if record.id != controller.recent.last?.id { Divider() }
            }
            if controller.hasMore {
                Button { Task { await controller.loadMore() } } label: { HStack { Text("Load more"); if controller.loadingMore { ProgressView().controlSize(.mini) } } }
                    .disabled(controller.loadingMore || controller.loading)
            } else if controller.recent.count >= 500 {
                Text("Showing the latest 500 matching requests. Export CSV for the full history.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func trackingNote(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tracked locally since \(summary.trackingStartedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "lock.shield")
                .font(.system(size: 11, weight: .medium))
            Text("NativeAgent tracking starts with this update. Earlier activity and totals from provider websites or other apps are unavailable. Missing usage is not zero; totals include only reported counts. Cache and reasoning subtotals may have less reporting coverage.")
            Text("Each entry represents an API request or a provider runtime turn. Tool follow-up requests are counted individually when reported.")
            Text("Usage totals remain after chats are archived or deleted. Records contain usage metadata, never prompts, messages or credentials.")
        }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Studio.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.line))
    }
    private func emptyState(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(Studio.accent)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }
    private func tokenText(_ value: Int64?) -> String { value.map { $0.formatted() } ?? "—" }
    private func fraction(_ value: Int64, of total: Int64) -> Double { total > 0 ? min(1, Double(value) / Double(total)) : 0 }
    private func displayLabel(_ value: String) -> String {
        value.isEmpty ? "Unspecified" : value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }
    private func chooseExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "NativeAgent-usage-\(String(Date.now.ISO8601Format().prefix(10))).csv"
        panel.title = "Export local usage"
        panel.message = "Exports every matching request, including rows whose provider did not report token counts."
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            exportTask = Task { await controller.export(to: url) }
        }
    }
}

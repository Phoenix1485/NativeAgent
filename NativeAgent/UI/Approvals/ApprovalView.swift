import SwiftUI

struct ApprovalView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let approval: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.title, systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
            if let command = approval.command {
                ScrollView { Text(command).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                    .frame(maxHeight: 260).background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if let directory = approval.workingDirectory { LabeledContent("Working directory", value: directory).font(.caption).textSelection(.enabled) }
            HStack {
                ForEach(approval.choices, id: \.self) { decision in
                    decisionButton(decision)
                }
            }
        }
        .padding(14)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.4)))
    }

    @ViewBuilder
    private func decisionButton(_ decision: ApprovalDecision) -> some View {
        if decision == .accept {
            Button(decision.label) { Task { await model.answer(approval, decision: decision) } }
                .buttonStyle(.borderedProminent)
        } else {
            Button(decision.label, role: decision == .decline || decision == .cancel ? .destructive : nil) {
                Task { await model.answer(approval, decision: decision) }
            }
            .buttonStyle(.bordered)
        }
    }
}

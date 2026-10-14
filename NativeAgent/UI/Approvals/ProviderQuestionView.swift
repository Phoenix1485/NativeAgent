import SwiftUI

struct ProviderQuestionView: View {
    @EnvironmentObject private var model: WorkspaceViewModel
    let request: ProviderQuestionRequest
    @State private var answers: [String: String] = [:]
    @State private var submitting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Agent needs your input", systemImage: "questionmark.bubble").font(.headline)
            ForEach(request.questions) { question in
                Text(question.header).font(.caption.weight(.medium))
                Text(question.text).textSelection(.enabled)
                ForEach(question.options) { option in
                    Button { answers[question.id] = option.label } label: {
                        Label(option.label + (option.description.isEmpty ? "" : " — " + option.description), systemImage: answers[question.id] == option.label ? "checkmark.circle.fill" : "circle")
                    }.buttonStyle(.plain)
                }
                if question.allowsOther || question.options.isEmpty {
                    if question.secret { SecureField("Your answer", text: answer(question.id)) }
                    else { TextField("Your answer", text: answer(question.id), axis: .vertical).lineLimit(1...5) }
                }
            }
            HStack {
                Button(submitting ? "Submitting…" : "Submit answers") {
                    submitting = true
                    Task { await model.answerQuestion(request, answers: answers); submitting = false }
                }.disabled(submitting || request.questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                Button("Stop task") { Task { await model.stop() } }
            }
            Text("Nothing is selected or submitted automatically. Answers go only to this pending provider request.").font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
    private func answer(_ id: String) -> Binding<String> { Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }) }
}

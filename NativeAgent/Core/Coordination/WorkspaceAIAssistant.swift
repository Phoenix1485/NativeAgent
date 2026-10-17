import Combine
import Foundation

@MainActor
final class WorkspaceAIAssistant: ObservableObject {
    weak var model: WorkspaceViewModel?
    @Published private(set) var request: AIAssistanceRequest?
    @Published var selectedRecipients: Set<String> = []
    @Published private(set) var answers: [AIAssistanceAnswer] = []
    @Published private(set) var isRunning = false
    @Published private(set) var notice: String?
    @Published var comparisonSelection: Set<UUID> = []
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init(model: WorkspaceViewModel) { self.model = model }

    func prepare(_ request: AIAssistanceRequest) {
        guard !isRunning else { return }
        self.request = request; answers = []; notice = nil
        guard let model else { return }
        model.refreshSavedKeys()
        let available = Set(model.aiRecipients.map(\.id))
        selectedRecipients = model.selectedAIRecipients.intersection(available)
        if selectedRecipients.isEmpty, let first = model.aiRecipients.first { selectedRecipients = [first.id] }
    }

    func run() {
        guard !isRunning, let model, let request else { return }
        guard !model.isWorking else { notice = "Wait for the current task to finish."; return }
        let recipients = model.aiRecipients.filter { selectedRecipients.contains($0.id) }
        guard recipients.count == selectedRecipients.count, !recipients.isEmpty else { notice = "Choose an available AI connection."; return }
        guard request.prompt.utf8.count <= 180_000 else { notice = "This content exceeds 180 KB. Select a smaller comparison."; return }
        do {
            guard model.authorizeAIReview(recipients, projectPath: request.projectPath) else { return }
            let jobs = try model.makeAIReviewJobs(recipients: recipients, instructions: AIAssistanceRequest.instructions, input: request.prompt, projectPath: request.projectPath)
            let token = UUID(); generation = token
            answers = recipients.map { .init(id: $0.id, name: $0.name, model: $0.model) }
            notice = nil; isRunning = true
            work = Task { [weak self] in
                await AIReviewRunner.run(jobs) { recipient, result in
                    await self?.receive(result, recipient: recipient, generation: token)
                }
                guard let self, self.generation == token else { return }
                self.isRunning = false; self.work = nil
                if Task.isCancelled { self.notice = "Stopped. Completed answers remain available; started requests may still count toward provider usage." }
            }
        } catch { notice = error.localizedDescription }
    }

    private func receive(_ result: Result<String, Error>, recipient: AIRecipient, generation: UUID) {
        guard self.generation == generation, let index = answers.firstIndex(where: { $0.id == recipient.id }) else { return }
        switch result {
        case .success(let text): answers[index].text = text
        case .failure(let error): answers[index].error = error.localizedDescription
        }
    }
    func cancel() { work?.cancel() }
    func shutdown() async { work?.cancel(); await work?.value }
}

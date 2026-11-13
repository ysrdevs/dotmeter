import Foundation
import Observation

@MainActor
@Observable
final class AnalysisSession {
    struct Turn: Identifiable {
        let id = UUID()
        var question: String?
        var answer: String
        /// The first turn is a JSON report rendered natively; follow-ups are prose.
        var isStructured: Bool { question == nil }
        var report: AnalysisReport? { isStructured ? AnalysisReport.parse(answer) : nil }
    }

    enum State: Equatable {
        case idle, streaming, done
        case failed(String)
    }

    private(set) var turns: [Turn] = []
    private(set) var state: State = .idle
    private(set) var modelUsed: String?
    /// Apps as they were when the analysis started; used for icons so the card is independent of live refreshes.
    private(set) var appsAtStart: [AppUsage] = []

    @ObservationIgnored private var transcript: [ClaudeMessage] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Supplies the storage summary when there is one; set once by the app shell.
    @ObservationIgnored var storageSummary: () -> String? = { nil }

    var isStreaming: Bool { state == .streaming }

    func analyze(snapshot: Snapshot, history: [HistoryPoint]) {
        cancel()
        turns = []
        transcript = []
        appsAtStart = Array(snapshot.apps.prefix(40))
        send(AnalysisPrompt.initialMessage(snapshot: snapshot, history: history, storage: storageSummary()), question: nil)
    }

    /// Any question. The first one in a conversation carries the snapshot with it; later ones just a line of live figures.
    func ask(_ question: String, snapshot: Snapshot?, history: [HistoryPoint] = []) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        if transcript.isEmpty || turns.isEmpty {
            guard let snapshot else { return }
            turns = []
            transcript = []
            appsAtStart = Array(snapshot.apps.prefix(40))
            send(AnalysisPrompt.questionMessage(trimmed, snapshot: snapshot, history: history, storage: storageSummary()), question: trimmed)
        } else {
            send(AnalysisPrompt.followUp(trimmed, snapshot: snapshot), question: trimmed)
        }
    }

    func stop() {
        cancel()
        if state == .streaming { state = .done }
    }

    func reset() {
        cancel()
        turns = []
        transcript = []
        state = .idle
    }

    private func cancel() {
        task?.cancel()
        task = nil
    }

    /// Debug: DOTMETER_MOCK_ANALYSIS=1 streams a canned answer so the result card can be reviewed without an API key.
    private func streamMock(question: String?) {
        turns.append(Turn(question: question, answer: ""))
        state = .streaming
        modelUsed = AppSettings.shared.modelTitle
        let text = question == nil ? """
        {"status": "busy", "verdict": "Xcode is compiling, which is what the busy cores and the warm chip are about. Nothing else is competing with it, and it will settle when the build ends.", "culprits": [{"name": "Xcode", "usage": "310% CPU", "reason": "A build is running; the compiler takes every core it is given.", "processes": ["swift-frontend", "XCBBuildService"], "concern": "none"}, {"name": "Safari", "usage": "6.4 GB", "reason": "Many tabs open. Memory is plentiful, so this costs nothing right now.", "processes": ["Safari Web Content"], "concern": "none"}, {"name": "Photos", "usage": "120% CPU", "reason": "Indexing faces and objects after an import. It pauses when you work and has been going for a while.", "processes": ["photoanalysisd"], "concern": "watch"}, {"name": "WindowServer", "usage": "38% GPU", "reason": "Drawing two displays; normal for this setup.", "processes": [], "concern": "none"}], "actions": [{"title": "Let the build finish", "detail": "Load and temperature are normal for compiling on this chip and will drop when it is done.", "quit": ""}, {"title": "Check Photos again later", "detail": "If photoanalysisd is still busy tomorrow, open Photos once and let it finish while plugged in.", "quit": ""}], "thermal": "The fans are near the bottom of their range, which matches the load; the chip has plenty of headroom before it would throttle."}
        """ : "It will finish on its own. Photos indexing is throttled to leave headroom, so you can keep working; the fans will stay at minimum unless you add a heavy export on top."
        task = Task { [weak self] in
            for word in text.split(separator: " ", omittingEmptySubsequences: false) {
                try? await Task.sleep(for: .milliseconds(18))
                guard let self, !Task.isCancelled else { return }
                let current = self.turns[self.turns.count - 1].answer
                self.turns[self.turns.count - 1].answer = current.isEmpty ? String(word) : current + " " + word
            }
            self?.state = .done
        }
    }

    private func send(_ content: String, question: String?) {
        if ProcessInfo.processInfo.environment["DOTMETER_MOCK_ANALYSIS"] == "1" {
            streamMock(question: question)
            return
        }
        let settings = AppSettings.shared
        guard let client = AIClient.current() else {
            state = .failed("Add your \(settings.provider.company) API key in Settings to analyze.")
            return
        }
        if let last = turns.last, !last.answer.isEmpty, transcript.last?.role == "user" {
            transcript.append(ClaudeMessage(role: "assistant", content: last.answer))
        }
        transcript.append(ClaudeMessage(role: "user", content: content))
        turns.append(Turn(question: question, answer: ""))
        state = .streaming
        modelUsed = settings.modelTitle

        let messages = transcript
        let structured = question == nil
        task = Task { [weak self] in
            do {
                let stream = client.stream(
                    system: structured ? AnalysisPrompt.system : AnalysisPrompt.chatSystem,
                    messages: messages,
                    format: structured ? AnalysisReport.schema : nil
                )
                for try await chunk in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.turns[self.turns.count - 1].answer += chunk
                }
                guard let self, !Task.isCancelled else { return }
                self.state = .done
            } catch {
                guard let self, !Task.isCancelled else { return }
                if self.turns.last?.answer.isEmpty == true { self.turns.removeLast() }
                if self.transcript.last?.role == "user" { self.transcript.removeLast() }
                self.state = .failed(error.localizedDescription)
            }
        }
    }
}

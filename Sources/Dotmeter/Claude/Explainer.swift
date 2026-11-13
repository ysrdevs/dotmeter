import Foundation
import Observation

/// "Explain" on an area: one focused question to Claude about that area alone, answered in place.
/// Each area keeps its own answer, so opening another one does not lose it.
@MainActor
@Observable
final class Explainer {
    struct Entry {
        var text = ""
        var streaming = false
        var failure: String?
        var askedAt = Date()
    }

    /// Keyed by area, or by anything else that can be asked about, such as one event in the timeline.
    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Supplies the storage summary and what the timeline remembers; set once by the app shell.
    @ObservationIgnored var storageSummary: () -> String? = { nil }
    @ObservationIgnored var timelineSummary: () -> String? = { nil }

    func entry(for key: String) -> Entry? { entries[key] }
    func isStreaming(_ key: String) -> Bool { entries[key]?.streaming == true }

    func dismiss(_ key: String) {
        tasks[key]?.cancel()
        tasks[key] = nil
        entries[key] = nil
    }

    /// Asks about one area. `question` replaces the standing one, for an event or anything else specific.
    func explain(_ section: AppSection, key: String? = nil, snapshot: Snapshot, history: [HistoryPoint], question: String? = nil, extra: String? = nil) {
        let key = key ?? section.rawValue
        tasks[key]?.cancel()
        entries[key] = Entry(streaming: true)
        let prompt = AnalysisPrompt.explainMessage(section: section, snapshot: snapshot, history: history, storage: storageSummary(), timeline: timelineSummary(), question: question, extra: extra)

        if ProcessInfo.processInfo.environment["DOTMETER_MOCK_ANALYSIS"] == "1" {
            let canned = Self.mock(section)
            tasks[key] = Task { [weak self] in
                for word in canned.split(separator: " ", omittingEmptySubsequences: false) {
                    try? await Task.sleep(for: .milliseconds(14))
                    guard let self, !Task.isCancelled, var entry = self.entries[key] else { return }
                    entry.text += (entry.text.isEmpty ? "" : " ") + word
                    self.entries[key] = entry
                }
                self?.entries[key]?.streaming = false
            }
            return
        }

        guard let client = AIClient.current() else {
            let provider = AppSettings.shared.provider
            entries[key] = Entry(failure: "Add your \(provider.company) API key in Settings and \(provider.assistant) can explain this.")
            return
        }
        tasks[key] = Task { [weak self] in
            do {
                for try await chunk in client.stream(system: AnalysisPrompt.explainSystem, messages: [ClaudeMessage(role: "user", content: prompt)]) {
                    guard let self, !Task.isCancelled, var entry = self.entries[key] else { return }
                    entry.text += chunk
                    self.entries[key] = entry
                }
                guard let self, !Task.isCancelled else { return }
                self.entries[key]?.streaming = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                var entry = self.entries[key] ?? Entry()
                entry.streaming = false
                entry.failure = error.localizedDescription
                self.entries[key] = entry
            }
        }
    }

    private static func mock(_ section: AppSection) -> String {
        switch section {
        case .thermal:
            return "The hottest sensor is a **performance core at 63°**, which is ordinary for light work on an M3 Ultra: the die idles in the mid 40s and only throttles past 100°. The heat is in the processor, not the graphics cores (49°) or the SSD (42°).\n\n- **Fans** are at 1,012 rpm, their minimum, so the case is quiet because nothing is asking for more.\n- **Claude** and **bun** are the only apps keeping cores warm, at about a fifth of a core each.\n\nNothing to do. If it climbs past 85° and stays there, open Processor to see which app is holding cores."
        case .network:
            return "You are online over **Wi-Fi 6E** at a 2.2 Gb/s link rate, and almost all of the 23 MB/s moving right now is **App Store** downloading an update. **Time Machine** is the upload, backing up at about 2 MB/s.\n\n- The router answers in 2 ms and the internet in about 14 ms, with one lost echo in five minutes: a healthy line.\n- A tunnel is up, so some traffic is counted under both its app and the tunnel.\n\nNothing is wrong. The download will finish on its own; pause it in the App Store if a call starts to stutter."
        case .power:
            return "The Mac is drawing **36 W**, close to its idle floor. Most of that is the baseline every Mac Studio pays for being on: power supply losses, memory, storage and the fans.\n\n- **Graphics** account for about 1 W.\n- Apps add under a watt between them; **\(App.name)** itself is the largest while this window is open.\n\nAt this rate a day costs about 0.86 kWh. Sleep is the only thing that would lower it meaningfully."
        case .gpu:
            return "The graphics cores are **16% busy**, nearly all of it **WindowServer** drawing the desktop and **Claude** rendering its window. 3.3 GB of graphics memory is in use out of 10 GB set aside.\n\nThat is idle for an 80-core GPU. A game or a local model would take this to 60% and above and bring the fans with it."
        case .storage:
            return "The disk is **70% full**: 358 GB used of 512 GB. **Photos** (59 GB) and **Apps** (53 GB) are the largest, but the easiest win is **Caches** at 47 GB, which apps rebuild as they need.\n\n- **Trash** holds another 31 GB that is already deleted in your mind.\n\nClearing caches and emptying the Trash would free about 78 GB without touching anything you made."
        case .memory:
            return "Memory is comfortable: **126 GB used of 512 GB**, no swap, normal pressure. **ChatGPT** holds the most at 11 GB, followed by **python3.12** at 3 GB.\n\nmacOS is using 43 GB to cache files it can drop the moment an app wants the space. Nothing to do."
        case .battery:
            return "The battery is at **62%** and draining at about **16 W**, which gives roughly five hours. That is ordinary for light work on this Mac.\n\n- **Health is 91%** after 214 cycles: normal wear, well short of the point where service is worth it.\n- **Xcode** is the largest drain at 4 W; everything else is under a watt.\n\nNothing to do. Quit Xcode when you are not building if you need the extra hour."
        case .cpu:
            return "The processor is **7% busy** across 32 cores, with no core pinned. **Claude** is the largest at about a third of a core, then **bun** and **ChatGPT**.\n\nThe load average of 4 means a few threads are usually waiting, which is normal with this many apps open. Nothing here would spin the fans."
        default:
            return "Everything is quiet. The processor is at **7%**, memory pressure is normal, the hottest sensor reads **63°** with the fans at their minimum, and the network is carrying a download for **App Store**.\n\nNothing needs attention."
        }
    }
}

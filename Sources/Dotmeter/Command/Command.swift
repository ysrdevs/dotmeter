import Foundation

/// The app's readings from a terminal and for AI apps. The app's own program is the command:
///
///   Dotmeter status                      the whole Mac in brief
///   Dotmeter apps --by memory --top 5    what is using the most memory
///   Dotmeter timeline --hours 24         what was recorded since yesterday
///   Dotmeter cpu --json                  any of them as JSON
///   Dotmeter mcp                         the same readings as tools for an AI app
///
/// A command opens no window, shows nothing in the menu bar, asks the Keychain for nothing, sends nothing over the
/// network and writes no file. It reads the machine with the collectors the app uses and ends, so it works while
/// the app is running and from a script.
enum Command {
    /// What can be asked for. The AI server offers the same readings as tools under these names.
    enum Reading: String, CaseIterable {
        case status, processor, graphics, memory, thermals, network, power, storage, apps, usb, timeline
    }

    enum Word: Equatable {
        case reading(Reading)
        case help
        case mcp
    }

    struct Options: Equatable {
        var json = false
        /// IP and MAC addresses, the Wi-Fi network's name, the router and the DNS servers: left out unless asked for.
        var addresses = false
        var by = AppOrder.cpu
        var top = 10
        var hours: Int?
    }

    struct Request: Equatable {
        var word: Word
        var options = Options()
    }

    enum Parsed: Equatable {
        case request(Request)
        /// What was wrong with it, in a sentence.
        case mistake(String)
    }

    static let topRange = 1...100
    static let hoursRange = 1...RecordedWeek.weekHours

    /// The words as they are typed. The processor's is `cpu`, the way everyone says it; the tool's name works too.
    static func word(_ text: String) -> Word? {
        switch text {
        case "help", "--help", "-h": return .help
        case "mcp": return .mcp
        case "cpu": return .reading(.processor)
        default: return Reading(rawValue: text).map { .reading($0) }
        }
    }

    /// Whether these arguments are a command for this, and not the app being opened. Every flag of the app itself
    /// starts with two dashes, and macOS passes nothing else when it opens an app, so anything that starts with a
    /// word is meant as a command, a mistyped one included: that gets told so, and never opens the app.
    static func handles(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return !first.hasPrefix("-") || word(first) != nil
    }

    static func parse(_ arguments: [String]) -> Parsed {
        guard let first = arguments.first else { return .mistake("No command given.") }
        guard let word = word(first) else { return .mistake("There is no command called \"\(first)\".") }
        var options = Options()
        var rest = Array(arguments.dropFirst())
        guard case .reading(let reading) = word else {
            // `help cpu` is still help. The server takes nothing: what it is asked comes down its input.
            if word == .mcp, let extra = rest.first { return .mistake("mcp takes no options, and \"\(extra)\" was given.") }
            return .request(Request(word: word))
        }
        while !rest.isEmpty {
            var name = rest.removeFirst()
            var value: String?
            if name.hasPrefix("--"), let equals = name.firstIndex(of: "=") {
                value = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            /// The value of an option that needs one: after an equals sign, or the next argument.
            func taken() -> String? {
                if let value { return value }
                return rest.isEmpty ? nil : rest.removeFirst()
            }
            switch name {
            case "--json":
                options.json = true
            case "--addresses":
                options.addresses = true
            case "--by":
                guard reading == .apps else { return .mistake("--by goes with apps.") }
                guard let text = taken(), let order = AppOrder(rawValue: text) else { return .mistake("--by takes cpu, memory, energy or gpu.") }
                options.by = order
            case "--top":
                guard reading == .apps else { return .mistake("--top goes with apps.") }
                guard let text = taken(), let count = Int(text), topRange.contains(count) else { return .mistake("--top takes a number from \(topRange.lowerBound) to \(topRange.upperBound).") }
                options.top = count
            case "--hours":
                guard reading == .timeline else { return .mistake("--hours goes with timeline.") }
                guard let text = taken(), let hours = Int(text), hoursRange.contains(hours) else { return .mistake("--hours takes a number from \(hoursRange.lowerBound) to \(hoursRange.upperBound).") }
                options.hours = hours
            default:
                return .mistake("\(first) does not take \"\(name)\".")
            }
        }
        return .request(Request(word: word, options: options))
    }

    static var usage: String {
        let name = App.name
        return """
        \(name): this Mac's meters from a terminal.

          \(name) status      the whole Mac in brief
          \(name) cpu         processor load, each core, and what is using them
          \(name) graphics    graphics load and memory
          \(name) memory      memory in use, pressure and swap
          \(name) thermals    temperatures and fans
          \(name) network     traffic, interfaces, Wi-Fi and open ports
          \(name) power       watts drawn, by part and by app, and the battery
          \(name) storage     space on the startup disk
          \(name) apps        the busiest apps      --by cpu|memory|energy|gpu  --top <n>
          \(name) usb         ports, cables and what is plugged in
          \(name) timeline    the recorded week     --hours <n>
          \(name) mcp         serve the meters to an AI app (Model Context Protocol)
          \(name) help

          --json         the reading as JSON: bytes, watts, degrees Celsius, shares from 0 to 1
          --addresses    with network: IP and MAC addresses and the Wi-Fi name, left out otherwise
        """
    }

    static func say(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Debug: DOTMETER_COMMAND_DEMO=1 answers with made-up apps, network, ports and week, for captures that show
    /// nothing of the Mac they were taken on. It is the app's own demo switches, all at once: they are read the
    /// first time a collector is used, which is after this.
    static let demo = ProcessInfo.processInfo.environment["DOTMETER_COMMAND_DEMO"] == "1"

    private static func switchDemoOn() {
        for (name, value) in [("DOTMETER_APPS_DEMO", "1"), ("DOTMETER_NET_DEMO", "1"), ("DOTMETER_USB_DEMO", "laptop"), ("DOTMETER_TIMELINE_DEMO", "1")] {
            setenv(name, value, 0)
        }
    }

    static func run(_ arguments: [String]) -> Never {
        if demo { switchDemoOn() }
        switch parse(arguments) {
        case .mistake(let message):
            say(message + "\n\n" + usage)
            exit(2)
        case .request(let request):
            switch request.word {
            case .help:
                print(usage)
            case .mcp:
                MeterServer.serve()
            case .reading(let reading):
                let gathered = Gathered(reading, reader: MeterReader())
                print(request.options.json ? gathered.json(request.options).pretty : gathered.text(request.options))
            }
            exit(0)
        }
    }

    /// What one reading needs, taken once, to be shown as text or as JSON.
    struct Gathered {
        let reading: Reading
        var snapshot: Snapshot?
        var volume: VolumeSpace?
        var usb: USBStats?
        var week: RecordedWeek?

        init(_ reading: Reading, reader: MeterReader) {
            self.reading = reading
            switch reading {
            case .status:
                // The ports and the disk are read inside the wait between the two readings, so they cost no time.
                var usb: USBStats?
                var volume: VolumeSpace?
                snapshot = reader.read {
                    usb = USBSampler().sample()
                    volume = VolumeSpace.read()
                }
                self.usb = usb
                self.volume = volume
            case .network:
                snapshot = reader.read(network: true)
            case .processor, .graphics, .memory, .thermals, .power, .apps:
                snapshot = reader.read()
            case .storage:
                volume = VolumeSpace.read()
            case .usb:
                usb = USBSampler().sample()
            case .timeline:
                week = RecordedWeek.load()
            }
        }

        func json(_ options: Options) -> JSON {
            switch reading {
            case .status: return snapshot.map { Report.status($0, volume: volume ?? VolumeSpace.read(), usb: usb) } ?? .null
            case .processor: return snapshot.map(Report.processor) ?? .null
            case .graphics: return snapshot.map(Report.graphics) ?? .null
            case .memory: return snapshot.map(Report.memory) ?? .null
            case .thermals: return snapshot.map(Report.thermals) ?? .null
            case .network: return snapshot.map { Report.network($0, addresses: options.addresses) } ?? .null
            case .power: return snapshot.map(Report.power) ?? .null
            case .apps: return snapshot.map { Report.apps($0, by: options.by, top: options.top) } ?? .null
            case .storage: return Report.storage(volume ?? VolumeSpace.read())
            case .usb: return Report.usb(usb ?? USBStats())
            case .timeline: return (week ?? RecordedWeek()).json(hours: options.hours)
            }
        }

        func text(_ options: Options) -> String {
            switch reading {
            case .status: return snapshot.map { ReportText.status($0, volume: volume ?? VolumeSpace.read(), usb: usb) } ?? ""
            case .processor: return snapshot.map(ReportText.processor) ?? ""
            case .graphics: return snapshot.map(ReportText.graphics) ?? ""
            case .memory: return snapshot.map(ReportText.memory) ?? ""
            case .thermals: return snapshot.map(ReportText.thermals) ?? ""
            case .network: return snapshot.map { ReportText.network($0, addresses: options.addresses) } ?? ""
            case .power: return snapshot.map(ReportText.power) ?? ""
            case .apps: return snapshot.map { ReportText.apps($0, by: options.by, top: options.top) } ?? ""
            case .storage: return ReportText.storage(volume ?? VolumeSpace.read())
            case .usb:
                let stats = usb ?? USBStats()
                return stats.ports.isEmpty ? "This Mac reports no ports." : USBReport.text(stats)
            case .timeline: return ReportText.timeline(week ?? RecordedWeek(), hours: options.hours)
            }
        }
    }
}

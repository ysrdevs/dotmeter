import Foundation

/// Everything the wall shows at one moment, as words and series. Comparing two tells whether to draw again.
struct WallReading: Equatable {
    struct Tile: Equatable {
        var kind: WallTile
        var number: String
        var unit: String
        /// The small line at the tile's top right.
        var detail: String
        var rgb: RGB
        /// The last five minutes: when each reading was taken and its height on the chart, 0...1.
        var times: [Double] = []
        var values: [Float] = []
        /// The heat chart colours each column by how hot it was: the temperature a full column stands for and
        /// the one an empty column does. Nil for every other chart.
        var heat: ClosedRange<Double>?
    }

    var clock: String
    /// "PM" where the clock has twelve hours.
    var clockSuffix: String
    var date: String
    /// The small line under the date: how long the Mac has been up.
    var note = ""
    var busiest: String?
    var busiestFigure: String?
    var tiles: [Tile]

    /// The charts cover this long.
    static let span: TimeInterval = 300
    /// The temperatures the heat chart runs between, as on the Thermals page.
    static let heatRange = 30.0...108.0

    static func make(snapshot: Snapshot?, history: [HistoryPoint], now: Date = Date()) -> WallReading {
        let time = clockText(now)
        var reading = WallReading(clock: time.clock, clockSuffix: time.suffix, date: dateText(now), busiest: nil, busiestFigure: nil, tiles: [])
        if let uptime = snapshot?.system.uptime, uptime > 0 { reading.note = "up \(Format.duration(uptime))" }
        let newest = history.last?.time ?? now
        let recent = history.filter { newest.timeIntervalSince($0.time) <= span }
        let times = recent.map { $0.time.timeIntervalSinceReferenceDate }
        func series(_ value: (HistoryPoint) -> Double) -> [Float] {
            recent.map { Float(min(max(value($0), 0), 1)) }
        }
        func peak(_ value: (HistoryPoint) -> Double) -> Double { recent.map(value).max() ?? 0 }

        for kind in WallTile.allCases {
            var tile = Tile(kind: kind, number: "--", unit: "", detail: "", rgb: kind.rgb, times: times)
            switch kind {
            case .cpu:
                if let cpu = snapshot?.cpu {
                    tile.number = "\(Int((cpu.total * 100).rounded()))"
                    tile.unit = "%"
                    tile.detail = Detail.clusters(cpu) ?? (cpu.perCore.isEmpty ? "" : "\(cpu.perCore.count) cores")
                }
                tile.values = series { $0.cpu }
            case .gpu:
                if let gpu = snapshot?.gpu {
                    tile.number = "\(Int((gpu.utilization * 100).rounded()))"
                    tile.unit = "%"
                    tile.detail = gpu.memoryInUse.map { "memory \(Format.bytes($0))" } ?? ""
                }
                tile.values = series { $0.gpu }
            case .memory:
                if let memory = snapshot?.memory, memory.total > 0 {
                    tile.number = "\(Int((memory.usedFraction * 100).rounded()))"
                    tile.unit = "%"
                    tile.detail = "\(Format.bytes(memory.used)) of \(Format.bytes(memory.total))"
                    if memory.pressure == .warning { tile.rgb = PX.orange }
                    if memory.pressure == .critical { tile.rgb = PX.red }
                }
                tile.values = series { $0.memory }
            case .heat:
                if let thermal = snapshot?.thermal, let hottest = thermal.hottest {
                    tile.number = "\(Int(hottest.celsius.rounded()))"
                    tile.unit = "°"
                    tile.detail = "\(hottest.group) · \(thermal.state.title)"
                    tile.rgb = heatColor(hottest.celsius)
                }
                let low = heatRange.lowerBound, range = heatRange.upperBound - heatRange.lowerBound
                tile.values = series { (($0.temperature ?? low) - low) / range }
                tile.heat = heatRange
            case .fans:
                if let thermal = snapshot?.thermal {
                    if thermal.fans.isEmpty {
                        tile.number = "NONE"
                    } else {
                        tile.number = "\(Int(thermal.averageRPM.rounded()))"
                        tile.unit = "RPM"
                        tile.detail = "\(Format.percent(thermal.averageFanPercent)) of range"
                    }
                }
                tile.values = series { $0.fan }
            case .power:
                let top = max(peak { $0.power ?? 0 }, 1)
                if let watts = snapshot?.power.total {
                    tile.number = "\(Int(watts.rounded()))"
                    tile.unit = "W"
                    tile.detail = "peak \(Int(top.rounded())) W"
                }
                let full = Self.ceiling(top, floor: 20)
                tile.values = series { ($0.power ?? 0) / full }
            case .down, .up, .disk:
                let value: (HistoryPoint) -> Double = kind == .down ? { $0.networkIn } : (kind == .up ? { $0.networkOut } : { $0.diskBytesPerSecond })
                let top = peak(value)
                if let snapshot {
                    let current = kind == .down ? snapshot.network.inBytesPerSecond : (kind == .up ? snapshot.network.outBytesPerSecond : snapshot.disk.readBytesPerSecond + snapshot.disk.writeBytesPerSecond)
                    (tile.number, tile.unit) = rate(current)
                    tile.detail = kind == .disk ? (snapshot.disk.total > 0 ? "\(Format.data(snapshot.disk.free)) free" : "") : "peak \(Format.shortRate(top))"
                }
                let full = NetScale.ceiling(top)
                tile.values = series { value($0) / full }
            }
            reading.tiles.append(tile)
        }

        if let app = snapshot?.apps.max(by: { $0.cpu < $1.cpu }), app.cpu > 0 {
            let name = DotText.drawable(app.name)
            if !name.isEmpty {
                reading.busiest = name
                reading.busiestFigure = Format.cpu(app.cpu)
            }
        }
        return reading
    }

    /// A rate as a short number and its unit: "12" and "MB/s", never more than three digits or "1.2".
    static func rate(_ bytesPerSecond: Double) -> (number: String, unit: String) {
        if bytesPerSecond >= 999.5e6 { return (String(format: "%.1f", bytesPerSecond / 1e9), "GB/s") }
        if bytesPerSecond >= 9.95e6 { return ("\(Int((bytesPerSecond / 1e6).rounded()))", "MB/s") }
        if bytesPerSecond >= 0.9995e6 { return (String(format: "%.1f", bytesPerSecond / 1e6), "MB/s") }
        if bytesPerSecond >= 1e3 { return ("\(Int((bytesPerSecond / 1e3).rounded()))", "KB/s") }
        return ("0", "KB/s")
    }

    /// The next 1-2-5 step above a value, so a chart's top is a round figure.
    static func ceiling(_ value: Double, floor: Double) -> Double {
        let value = max(value * 1.1, floor)
        let magnitude = pow(10, Foundation.floor(log10(value)))
        let leading = value / magnitude
        return (leading <= 1 ? 1 : (leading <= 2 ? 2 : (leading <= 5 ? 5 : 10))) * magnitude
    }

    // MARK: The clock

    private static let clockFormat: DateFormatter = formatter("jmm", locale: .current)
    private static let dateFormat: DateFormatter = formatter("EEEdMMM", locale: .current)
    private static let plainClock: DateFormatter = formatter("HHmm", locale: Locale(identifier: "en_GB"))
    private static let plainDate: DateFormatter = formatter("EEEdMMM", locale: Locale(identifier: "en_GB"))

    private static func formatter(_ template: String, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// The time as the Mac's region writes it, split into the digits and any "PM". A region whose digits or
    /// letters the dot font does not have gets the plain twenty-four hour clock.
    static func clockText(_ date: Date) -> (clock: String, suffix: String) {
        let text = clockFormat.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        guard text.allSatisfy(DotText.knows) else { return (plainClock.string(from: date), "") }
        let digits = text.filter { $0.isNumber || $0 == ":" || $0 == "." }
        let rest = text.filter { $0.isLetter }
        return (digits, rest)
    }

    static func dateText(_ date: Date) -> String {
        let text = dateFormat.string(from: date).replacingOccurrences(of: ".", with: "")
        return text.allSatisfy(DotText.knows) ? text : plainDate.string(from: date)
    }

    /// The longest words every tile can show, for checking that a layout has room for them.
    static var fullest: WallReading {
        let figures: [WallTile: (String, String)] = [
            .cpu: ("100", "%"), .gpu: ("100", "%"), .memory: ("100", "%"), .heat: ("118", "°"), .fans: ("9999", "RPM"),
            .power: ("9999", "W"), .down: ("1.2", "GB/s"), .up: ("999", "KB/s"), .disk: ("999", "MB/s"),
        ]
        let details: [WallTile: String] = [
            .cpu: "P 100% · E 100%", .gpu: "memory 1023 MB", .memory: "1023 GB of 1024 GB", .heat: "Storage · Critical", .fans: "100% of range",
            .power: "peak 9999 W", .down: "peak 999 MB/s", .up: "peak 999 KB/s", .disk: "999 GB free",
        ]
        return WallReading(
            clock: "12:59", clockSuffix: "PM", date: "Wed, 28 Sept", note: "up 364d 23h", busiest: "Final Cut Pro Helper (Renderer)", busiestFigure: "3200%",
            tiles: WallTile.allCases.map { kind in
                Tile(kind: kind, number: figures[kind]?.0 ?? "", unit: figures[kind]?.1 ?? "", detail: details[kind] ?? "", rgb: kind.rgb, times: [0, 2, 4], values: [0.2, 1, 0.5], heat: kind == .heat ? heatRange : nil)
            }
        )
    }
}

extension WallReading {
    /// Made-up readings (`DOTMETER_WALL_DEMO=1`): a busy afternoon on no Mac in particular, moving with the clock
    /// so the wall stays alive. Nothing of the real machine is in it but the time.
    static func demo(at now: Date) -> WallReading {
        let time = clockText(now)
        let t = now.timeIntervalSinceReferenceDate
        let times = stride(from: 150.0, through: 0, by: -1).map { t - $0 * 2 }
        // Each series is a slow swell with a faster ripple and a little grain, on its own beat.
        func wave(_ at: Double, _ slow: Double, _ fast: Double, _ phase: Double) -> Double {
            let swell = 0.5 + 0.5 * sin(at / slow + phase) * cos(at / (slow * 0.37) + phase * 2)
            let ripple = 0.5 + 0.5 * sin(at / fast + phase * 3)
            let grain = 0.5 + 0.5 * sin(at * 1.7 + phase)
            return 0.62 * swell + 0.28 * ripple + 0.10 * grain
        }
        struct Part {
            var kind: WallTile
            var low: Double
            var high: Double
            var slow: Double
            var fast: Double
        }
        let parts = [
            Part(kind: .cpu, low: 0.08, high: 0.86, slow: 23, fast: 5.1), Part(kind: .gpu, low: 0.12, high: 0.74, slow: 31, fast: 7.3),
            Part(kind: .memory, low: 0.56, high: 0.68, slow: 47, fast: 11), Part(kind: .heat, low: 0.28, high: 0.66, slow: 41, fast: 9.7),
            Part(kind: .fans, low: 0.10, high: 0.52, slow: 53, fast: 13), Part(kind: .power, low: 0.18, high: 0.82, slow: 27, fast: 6.1),
            Part(kind: .down, low: 0.02, high: 0.92, slow: 17, fast: 3.9), Part(kind: .up, low: 0.02, high: 0.70, slow: 21, fast: 4.7),
            Part(kind: .disk, low: 0.01, high: 0.88, slow: 13, fast: 3.1),
        ]
        var reading = WallReading(clock: time.clock, clockSuffix: time.suffix, date: dateText(now), note: "up 3d 4h", busiest: "Xcode", busiestFigure: "", tiles: [])
        for (index, part) in parts.enumerated() {
            let phase = Double(index) * 1.3
            let values = times.map { part.low + (part.high - part.low) * wave($0, part.slow, part.fast, phase) }
            let last = values.last ?? 0, top = values.max() ?? 0
            var tile = Tile(kind: part.kind, number: "", unit: "", detail: "", rgb: part.kind.rgb, times: times, values: values.map { Float($0) })
            switch part.kind {
            case .cpu:
                (tile.number, tile.unit, tile.detail) = ("\(Int(last * 100))", "%", "P \(Int(last * 118))% · E \(Int(last * 41))%")
                reading.busiestFigure = "\(Int(last * 640) + 12)%"
            case .gpu: (tile.number, tile.unit, tile.detail) = ("\(Int(last * 100))", "%", "memory 6.4 GB")
            case .memory: (tile.number, tile.unit, tile.detail) = ("\(Int(last * 100))", "%", "\(Int(last * 64)) GB of 64 GB")
            case .heat:
                let celsius = heatRange.lowerBound + last * (heatRange.upperBound - heatRange.lowerBound)
                (tile.number, tile.unit, tile.detail) = ("\(Int(celsius))", "°", "CPU · Nominal")
                tile.rgb = heatColor(celsius)
                tile.heat = heatRange
            case .fans: (tile.number, tile.unit, tile.detail) = ("\(Int(1200 + last * 2400))", "RPM", "\(Int(last * 100))% of range")
            case .power: (tile.number, tile.unit, tile.detail) = ("\(Int(last * 200))", "W", "peak \(Int(top * 200)) W")
            case .down, .up, .disk:
                let full = part.kind == .down ? 50e6 : (part.kind == .up ? 10e6 : 200e6)
                (tile.number, tile.unit) = rate(last * full)
                tile.detail = part.kind == .disk ? "412 GB free" : "peak \(Format.shortRate(top * full))"
            }
            reading.tiles.append(tile)
        }
        return reading
    }
}

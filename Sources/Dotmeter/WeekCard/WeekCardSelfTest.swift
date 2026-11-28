import AppKit
import SystemConfiguration

extension DebugTools {
    /// `Dotmeter --self-test card`: the week card's figures on a made-up week whose answers are known, the
    /// picture's size and content, the short and the empty week, and that app names stay off when switched off.
    /// Everything is made up here; the only file written is one PNG in a temporary folder (or in
    /// DOTMETER_CARD_TEST_DIR, to keep it), and the copy goes to a pasteboard of the test's own.
    @MainActor
    static func cardSelfTest(models: AppModels) async {
        var failed = 0, checks = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failed += 1 }
            print("\(ok ? "ok    " : "FAILED") \(what)")
        }

        // A fixed week in a fixed time zone: Sunday 22 to Saturday 28 November 2026, looked at on the Saturday afternoon.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? Date()
        }
        func minutes(from start: Date, count: Int, cpu: Float, temp: Float, watts: Float, netIn: Float = 0, netOut: Float = 0) -> [TimelineMinute] {
            let first = Int(start.timeIntervalSince1970 / 60)
            return (0..<count).map { TimelineMinute(t: first + $0, cpu: cpu, cpuPeak: min(cpu + 0.125, 1), gpu: 0, memory: 0.5, temp: temp, fan: 1000, netIn: netIn, netOut: netOut, power: watts, disk: 0) }
        }
        func event(_ kind: TimelineEvent.Kind, _ start: Date, minutes length: Double, apps: [(String, Double)]) -> TimelineEvent {
            var event = TimelineEvent(kind: kind, start: start, end: start.addingTimeInterval(length * 60), summary: "made up")
            event.apps = apps.map { .init(name: $0.0, bundlePath: nil, cpu: $0.1) }
            return event
        }
        let now = at(28, 15, 30)
        var week: [TimelineMinute] = []
        // The Saturday before: hotter, busier and hungrier than anything in the week, and outside it.
        week += minutes(from: at(21, 12), count: 60, cpu: 1, temp: 105, watts: 500)
        week += minutes(from: at(24, 10), count: 120, cpu: 0.25, temp: 50, watts: 60, netIn: 1e6, netOut: 1e5)
        week += minutes(from: at(24, 15), count: 60, cpu: 0.75, temp: 70, watts: 120)
        week += minutes(from: at(26, 14), count: 60, cpu: 0.5, temp: 60, watts: 60)
        if let index = week.firstIndex(where: { $0.date == at(26, 14, 32) }) { week[index].temp = 97 }
        let apps = ["Alpha Forge", "Gamma Sketch Two", "Delta Recorder", "Omega Render", "Beta"]
        let events = [
            event(.hot, at(21, 12, 10), minutes: 20, apps: [("Omega Render", 12)]),
            event(.hot, at(24, 15, 10), minutes: 15, apps: [("Beta", 0.5), ("Alpha Forge", 8)]),
            event(.app, at(25, 9), minutes: 10, apps: [("Gamma Sketch Two", 4)]),
            event(.hot, at(26, 14, 30), minutes: 10, apps: [("Alpha Forge", 6)]),
            event(.throttled, at(26, 14, 35), minutes: 5, apps: [("Gamma Sketch Two", 9)]),
            event(.microphone, at(26, 16), minutes: 30, apps: [("Delta Recorder", 1), ("Delta Recorder", 1), ("Delta Recorder", 1)]),
        ]
        var input = WeekCardInput(minutes: week, events: events, model: "Mac Studio", chip: "Apple M3 Ultra", price: 0.20, now: now, calendar: calendar)

        // The figures.
        let figures = WeekCardFigures(input, light: .heat)
        check(figures.recorded == 240, "240 minutes are inside the seven days, the Saturday before is left out (got \(figures.recorded))")
        check(figures.days.first == at(22, 0) && figures.days.last == at(28, 0), "the week runs from Sunday the 22nd to Saturday the 28th")
        check(figures.hottest.map { $0.value == 97 && $0.at == at(26, 14, 32) } == true, "hottest: 97° on Thursday at 14:32 (got \(figures.hottest.map { "\($0.value) at \($0.at)" } ?? "none"))")
        check(figures.busiest.map { abs($0.value - 0.75) < 1e-6 && $0.at == at(24, 15) } == true, "busiest hour: 75% on Tuesday from 15:00 (got \(figures.busiest.map { "\($0.value) at \($0.at)" } ?? "none"))")
        check(abs(figures.wattHours - 300) < 1e-6, "energy: 120 + 120 + 60 = 300 Wh (got \(figures.wattHours))")
        check(abs(figures.averageWatts - 75) < 1e-6, "average draw: 75 W (got \(figures.averageWatts))")
        check(figures.cost.map { abs($0 - 0.06) < 1e-9 } == true, "cost: 0.3 kWh at $0.20 is $0.06 (got \(figures.cost.map { "\($0)" } ?? "none"))")
        check(abs(figures.received - 7.2e9) < 1 && abs(figures.sent - 7.2e8) < 1, "data: 7.2 GB in, 720 MB out (got \(figures.received) and \(figures.sent))")
        check(figures.hotEvents == 3 && abs(figures.hotSeconds - 1800) < 1e-6, "ran hot or throttled 3 times, 30 minutes in all (got \(figures.hotEvents), \(figures.hotSeconds) s)")
        check(figures.topApp?.name == "Alpha Forge" && figures.topApp?.events == 2, "busiest app: Alpha Forge, on top twice, ahead of Gamma Sketch Two on cores (got \(figures.topApp.map { "\($0.name) \($0.events)" } ?? "none"))")
        check(abs(figures.averageLoad - 0.4375) < 1e-6 && abs(figures.peakLoad - 0.875) < 1e-6, "average load 43.75%, peak 87.5% (got \(figures.averageLoad), \(figures.peakLoad))")
        // 14:32 is the third twelve-minute column of hour 14 on the fifth day; (97 - 30) / 78 of nine rows is eight.
        let column = 14 * WeekCardFigures.columnsPerHour + 2
        check(figures.levels[4][column].map { abs($0 - 67.0 / 78) < 1e-6 } == true && figures.levels[0][0] == nil, "the grid: the hottest column is at 67/78 of the scale, an hour with no record is empty")

        // The same week by the other lights.
        let byLoad = WeekCardFigures(input, light: .cpu), byPower = WeekCardFigures(input, light: .power)
        check(byLoad.levels[2][15 * WeekCardFigures.columnsPerHour].map { abs($0 - 0.75) < 1e-6 } == true, "lit by processor, Tuesday 15:00 is at 75%")
        check(byPower.levels[2][15 * WeekCardFigures.columnsPerHour].map { abs($0 - 120 / byPower.range.high) < 1e-6 } == true && byPower.range.high >= 120, "lit by power, Tuesday 15:00 is 120 W on a scale that holds it (top \(Int(byPower.range.high)) W)")

        // What the card says.
        guard let spec = WeekCardSpec(input, light: .heat, appNames: true) else {
            print("FAILED a week with four hours in it made no card")
            print("1 FAILED")
            return
        }
        func figure(_ id: String, in spec: WeekCardSpec) -> WeekCardSpec.Figure? { spec.figures.first { $0.id == id } }
        func says(_ spec: WeekCardSpec, _ id: String, _ value: String, _ unit: String, _ detail: String) -> Bool {
            figure(id, in: spec).map { $0.value == value && $0.unit == unit && $0.detail == detail } == true
        }
        check(spec.dates == "22 - 28 Nov 2026" && spec.fileName == "\(App.name) week 2026-11-22.png", "dates \"\(spec.dates)\", file \"\(spec.fileName)\"")
        check(spec.model == "Mac Studio" && spec.chip == "M3 Ultra", "the Mac: \(spec.model), \(spec.chip)")
        check(spec.recorded == "4 hours recorded", "it says how much: \"\(spec.recorded)\"")
        check(spec.dayNames == ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], "seven days, Sunday first")
        check(spec.figures.count == 6, "six figures (got \(spec.figures.map(\.id).joined(separator: ", ")))")
        check(says(spec, "hottest", "97°", "", "Thu 14:32"), "hottest reads 97°, Thu 14:32")
        check(says(spec, "busiest", "75%", "", "Tue 15:00"), "busiest hour reads 75%, Tue 15:00")
        check(says(spec, "energy", "300", "Wh", "average 75 W"), "energy reads 300 Wh, average 75 W")
        check(says(spec, "cost", "$0.06", "", "at $0.20 per kWh"), "cost reads $0.06 at $0.20 per kWh")
        check(says(spec, "data", "7.9", "GB", "↓7.2 GB ↑720 MB"), "data moved reads 7.9 GB (got \(figure("data", in: spec).map { "\($0.value) \($0.unit), \($0.detail)" } ?? "none"))")
        check(says(spec, "app", "Alpha Forge", "", "on top 2 times"), "busiest app reads Alpha Forge, on top 2 times")
        check(spec.filled[4][column] == 8 && spec.filled[2][10 * WeekCardFigures.columnsPerHour] == 2 && spec.filled[0][0] == -1, "cells lit: 8 of 9 at the hottest, 2 at 50°, none where nothing was recorded")
        check(SystemSpecFormats.agree, "kWh from 1 kWh up, watt-hours below; under a cent still carries its dollar sign")

        // No price set: no cost, and no dollar sign anywhere.
        input.price = 0
        let free = WeekCardSpec(input, light: .heat, appNames: true)
        let freeStrings = free.map { WeekCardPlate($0).strings } ?? []
        check(free != nil && figure("cost", in: free!) == nil && !freeStrings.contains { $0.contains("$") }, "with no price set there is no cost and no dollar sign")
        check(free.map { figure("hot", in: $0).map { $0.value == "3×" && $0.detail == "30m in all" } == true } == true, "ran hot takes the cost's place: 3×, 30m in all")
        input.price = 0.20

        // What is drawn, as strings.
        let plate = WeekCardPlate(spec)
        let drawn = plate.strings.joined(separator: " ").uppercased()
        for wanted in ["Mac Studio", "M3 Ultra", "22 - 28 Nov 2026", "4 hours recorded", "97°", "$0.06", "Alpha Forge", "dotmeter.app", "Thu 14:32"] {
            check(drawn.contains(wanted.uppercased()), "the card sets \"\(wanted)\"")
        }
        check(plate.strings.allSatisfy { string in string.allSatisfy { $0 == " " || WeekCardGlyphs.rows($0).contains { $0 != 0 } } }, "every character set has a shape in the dot font")
        let lit = plate.lit.values.reduce(0) { $0 + $1.count }
        let bounds = CGRect(x: 0, y: 0, width: WeekCardPlate.width, height: WeekCardPlate.height)
        let whole = (Array(plate.lit.values.joined()) + Array(plate.dim.values.joined())).allSatisfy { $0 == $0.integral && bounds.contains($0) }
        check(lit > 500 && whole, "\(lit) lit cells, every cell on whole pixels and inside the card")

        // App names off: none of them, anywhere in what is set.
        let quiet = WeekCardSpec(input, light: .heat, appNames: false)
        let quietDrawn = (quiet.map { WeekCardPlate($0).strings } ?? []).joined(separator: "\n").uppercased()
        let words = Set(apps.flatMap { $0.uppercased().split(separator: " ").map(String.init) })
        check(quiet != nil && figure("app", in: quiet!) == nil && !words.contains { quietDrawn.contains($0) }, "with App names off, no app's name is set (looked for \(words.sorted().joined(separator: ", ")))")
        check(words.contains { drawn.contains($0) } && !drawn.contains("DELTA") && !drawn.contains("OMEGA"), "with it on, only the busiest app is named: not the one on the microphone, not last week's")

        // Nothing private: the card does not know who or where it is.
        var privates = [NSUserName(), NSFullUserName()]
        if let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? { privates.append(computer) }
        privates = privates.map { $0.uppercased() }.filter { $0.count >= 3 }
        check(!privates.contains { drawn.contains($0) }, "neither the user's name nor the computer's is on the card")

        // The picture.
        let image = WeekCardRenderer.render(plate)
        check(image?.width == WeekCardPlate.width && image?.height == WeekCardPlate.height, "the picture is \(image?.width ?? 0) by \(image?.height ?? 0) pixels")
        let data = image.flatMap(WeekCardRenderer.png)
        let folder = ProcessInfo.processInfo.environment["DOTMETER_CARD_TEST_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let scratch = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(App.name)-card-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent(spec.fileName)
        try? data?.write(to: file)
        if let read = NSBitmapImageRep(data: (try? Data(contentsOf: file)) ?? Data()) {
            var bright = 0
            let black = read.colorAt(x: 4, y: 4).map { $0.redComponent + $0.greenComponent + $0.blueComponent < 0.01 } == true
            for y in stride(from: 0, to: read.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: read.pixelsWide, by: 3) {
                    guard let color = read.colorAt(x: x, y: y) else { continue }
                    if color.redComponent + color.greenComponent + color.blueComponent > 0.6 { bright += 1 }
                }
            }
            check(read.pixelsWide == WeekCardPlate.width && read.pixelsHigh == WeekCardPlate.height && !read.hasAlpha, "the PNG reads back at \(read.pixelsWide) by \(read.pixelsHigh), with no transparency")
            check(black && bright > 400, "it is not blank: a black corner, and \(bright) bright samples of one in nine")
        } else {
            check(false, "the PNG could not be read back from \(file.path)")
        }
        if folder == nil { try? FileManager.default.removeItem(at: scratch) } else { print("       kept \(file.path)") }

        // The window's model: draws off the main thread, copies, and has nothing to offer when there is nothing.
        let shown = WeekCardModel(light: .heat, appNames: true, remembers: false) { input }
        for _ in 0..<100 where shown.image == nil { try? await Task.sleep(for: .milliseconds(20)) }
        check(shown.image != nil && shown.png != nil && shown.settled && !shown.isEmpty, "the window's card is drawn")
        let board = NSPasteboard(name: NSPasteboard.Name("\(App.bundleID).card-test.\(UUID().uuidString)"))
        let copied = shown.copy(to: board)
        let pasted = board.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
        check(copied && pasted?.pixelsWide == WeekCardPlate.width && board.data(forType: .tiff) != nil, "Copy puts the PNG and a TIFF on the pasteboard (a pasteboard of the test's own)")
        let panel = shown.savePanel()
        check(panel?.nameFieldStringValue == "\(App.name) week 2026-11-22.png" && panel?.allowedContentTypes == [.png], "Save… offers a PNG named \"\(panel?.nameFieldStringValue ?? "")\" (the panel is made, not shown)")
        shown.light = .power
        for _ in 0..<100 where !(shown.spec?.legend.hasPrefix("Power") == true && shown.settled) { try? await Task.sleep(for: .milliseconds(20)) }
        check(shown.spec?.legend == "Power · 0 to 200 W", "choosing Power relights it: \"\(shown.spec?.legend ?? "")\"")

        // Ten minutes of history.
        let recent = Int(now.timeIntervalSince1970 / 60) - 18
        let short = WeekCardInput(minutes: (0..<10).map { TimelineMinute(t: recent + $0, cpu: 0.125, cpuPeak: 0.25, gpu: 0, memory: 0.5, temp: 48, fan: 0, netIn: 2000, netOut: 500, power: 30, disk: 0) }, events: [], model: "MacBook Air", chip: "Apple M4", price: 0, now: now, calendar: calendar)
        if let little = WeekCardSpec(short, light: .heat, appNames: true) {
            let strings = WeekCardPlate(little).strings
            check(little.recorded == "10 minutes recorded" && strings.contains("10 minutes recorded"), "ten minutes of history: the card says \"\(little.recorded)\"")
            check(says(little, "hottest", "48°", "", "Sat 15:12") && says(little, "energy", "5.0", "Wh", "average 30 W") && says(little, "hot", "0×", "", "not once"), "and makes honest figures of them: 48°, 5.0 Wh, ran hot 0×")
            check(figure("app", in: little) == nil && figure("cost", in: little) == nil && little.figures.count >= 4, "\(little.figures.count) figures, none for an app or a cost that there is no record of")
            check(little.filled.joined().filter { $0 > 0 }.count == 1, "one column of the grid is lit, the rest is dark")
            check(WeekCardRenderer.render(WeekCardPlate(little)) != nil, "and it draws")
        } else {
            check(false, "ten minutes of history made no card")
        }
        check(WeekCardSpec.recorded(1) == "1 minute recorded" && WeekCardSpec.recorded(60) == "1 hour recorded" && WeekCardSpec.recorded(180) == "3 hours recorded", "\"1 minute recorded\", \"1 hour recorded\", \"3 hours recorded\"")

        // Nothing at all.
        let none = WeekCardInput(minutes: [], events: events, model: "Mac Studio", chip: "Apple M3 Ultra", price: 0.20, now: now, calendar: calendar)
        check(WeekCardSpec(none, light: .heat, appNames: true) == nil, "an empty week makes no card")
        let old = WeekCardInput(minutes: minutes(from: at(21, 12), count: 60, cpu: 1, temp: 105, watts: 500), events: [], model: "Mac Studio", chip: "Apple M3 Ultra", price: 0, now: now, calendar: calendar)
        check(WeekCardSpec(old, light: .heat, appNames: true) == nil, "nor does a record that ended before the week began")
        let blank = WeekCardModel(light: .heat, appNames: true, remembers: false) { none }
        check(blank.isEmpty && blank.image == nil && blank.png == nil && blank.spec == nil && blank.savePanel() == nil && !blank.copy(to: board), "the window then says there is nothing yet and offers no picture")
        board.releaseGlobally()

        // Long names, and weeks that cross a month or a year.
        check(WeekCardSpec.dates(from: at(22, 0).addingTimeInterval(8 * 86_400), to: at(22, 0).addingTimeInterval(14 * 86_400), calendar: calendar) == "30 Nov - 6 Dec 2026", "a week across two months reads \"30 Nov - 6 Dec 2026\"")
        check(WeekCardSpec.dates(from: at(22, 0).addingTimeInterval(37 * 86_400), to: at(22, 0).addingTimeInterval(43 * 86_400), calendar: calendar) == "29 Dec 2026 - 4 Jan 2027", "and across two years \"29 Dec 2026 - 4 Jan 2027\"")
        let two = WeekCardPlate.name("Gamma Sketch Two", width: 296), long = WeekCardPlate.name("Supercalifragilistic", width: 296)
        check(two.lines == ["Gamma", "Sketch Two"] && long.lines.count == 1 && long.lines[0].hasSuffix("…") && WeekCardPlate.width(long.lines[0], pitch: long.pitch) <= 296, "a long app name breaks in two (\(two.lines.joined(separator: " / "))); one long word is cut (\(long.lines[0]))")
        let wide = WeekCardPlate.fit("MacBook Pro (16-inch, Nov 2024)", width: 936, pitches: [9, 8, 6, 5, 4])
        check(wide.text == "MacBook Pro (16-inch, Nov 2024)" && WeekCardPlate.width(wide.text, pitch: wide.pitch) <= 936, "a long model name is set smaller, whole (cells \(wide.pitch) pixels apart)")

        // How long a full week takes: the made-up week the Timeline's demo uses, every minute recorded.
        let demo = TimelineDemo.make()
        let full = WeekCardInput(minutes: demo.minutes, events: demo.events, model: "Mac Studio", chip: "Apple M3 Ultra", price: 0.16)
        var figuresTime = 0.0, plateTime = 0.0, drawTime = 0.0, pngTime = 0.0
        let runs = 5
        for _ in 0..<runs {
            let a = CFAbsoluteTimeGetCurrent()
            guard let spec = WeekCardSpec(full, light: .heat, appNames: true) else { break }
            let b = CFAbsoluteTimeGetCurrent()
            let plate = WeekCardPlate(spec)
            let c = CFAbsoluteTimeGetCurrent()
            let image = WeekCardRenderer.render(plate)
            let d = CFAbsoluteTimeGetCurrent()
            _ = image.flatMap(WeekCardRenderer.png)
            let e = CFAbsoluteTimeGetCurrent()
            figuresTime += b - a; plateTime += c - b; drawTime += d - c; pngTime += e - d
        }
        let scale = 1000 / Double(runs)
        print(String(format: "       a full week, mean of %d: figures %.1f ms (main thread), cells %.1f ms, picture %.1f ms, PNG %.1f ms", runs, figuresTime * scale, plateTime * scale, drawTime * scale, pngTime * scale))
        check((figuresTime + plateTime + drawTime) * scale < 500, "a full week is worked out and drawn in well under a second")

        print(failed == 0 ? "all \(checks) checks pass" : "\(failed) of \(checks) FAILED")
    }
}

/// The card's own number formats, checked in one place.
private enum SystemSpecFormats {
    static var agree: Bool {
        let energy = [(0.4, "0.4", "Wh"), (300.0, "300", "Wh"), (999.4, "999", "Wh"), (1000.0, "1.00", "kWh"), (9840.0, "9.84", "kWh"), (12_480.0, "12.5", "kWh"), (123_400.0, "123", "kWh")]
        let money = [(0.004, "<$0.01"), (0.06, "$0.06"), (12.479, "$12.48"), (1248.3, "$1,248")]
        return energy.allSatisfy { WeekCardSpec.energy($0.0) == ($0.1, $0.2) } && money.allSatisfy { WeekCardSpec.dollars($0.0) == $0.1 }
    }
}

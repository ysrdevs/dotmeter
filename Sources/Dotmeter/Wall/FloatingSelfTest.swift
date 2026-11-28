import AppKit

extension DebugTools {
    /// `--self-test floating`: where the meter goes across made-up arrangements of screens, and the words on it.
    /// Shows nothing and saves nothing.
    @MainActor
    static func floatingSelfTest(models: AppModels) async {
        var failed = 0
        func check(_ ok: Bool, _ note: String) {
            if !ok { failed += 1 }
            print("\(ok ? "ok" : "FAILED") \(note)")
        }
        func text(_ point: CGPoint) -> String { "\(Int(point.x)),\(Int(point.y))" }

        // Screens as macOS arranges them: the main one at the origin, the others round it, y upward.
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let mainVisible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let right = CGRect(x: 1920, y: -180, width: 2560, height: 1440)
        let above = CGRect(x: 240, y: 1080, width: 1440, height: 900)
        let left = CGRect(x: -1080, y: -400, width: 1080, height: 1920)
        let size = CGSize(width: 247, height: 40)
        func whole(_ corner: CGPoint, on screens: [CGRect]) -> Bool {
            let frame = CGRect(x: corner.x, y: corner.y - size.height, width: size.width, height: size.height)
            return screens.contains { $0.contains(frame) }
        }

        let fresh = FloatingPlacement.topLeft(saved: nil, size: size, screens: [main], mainVisible: mainVisible)
        check(fresh == CGPoint(x: 1920 - 247 - 16, y: 1055 - 12) && whole(fresh, on: [main]), "never moved: the top right corner of the main screen, under the menu bar (\(text(fresh)))")

        let kept = FloatingPlacement.topLeft(saved: CGPoint(x: 2400, y: 900), size: size, screens: [main, right], mainVisible: mainVisible)
        check(kept == CGPoint(x: 2400, y: 900), "left on the second screen: stays exactly there (\(text(kept)))")

        let gone = FloatingPlacement.topLeft(saved: CGPoint(x: 2400, y: 900), size: size, screens: [main], mainVisible: mainVisible)
        check(whole(gone, on: [main]) && gone == CGPoint(x: 1920 - 247, y: 900), "that screen unplugged: brought back to the nearest edge of the one that is left (\(text(gone)))")

        let high = FloatingPlacement.topLeft(saved: CGPoint(x: 600, y: 1900), size: size, screens: [main, right], mainVisible: mainVisible)
        check(whole(high, on: [main, right]) && high == CGPoint(x: 600, y: 1080), "the screen above gone: comes down to the top of the main one (\(text(high)))")

        let leftSide = FloatingPlacement.topLeft(saved: CGPoint(x: -900, y: 1400), size: size, screens: [main, left], mainVisible: mainVisible)
        check(leftSide == CGPoint(x: -900, y: 1400), "on a screen stood on its side to the left, at negative coordinates: stays (\(text(leftSide)))")

        let straddling = FloatingPlacement.clamp(CGPoint(x: 1850, y: 600), size: size, screens: [main, right])
        check(whole(straddling, on: [main, right]) && straddling == CGPoint(x: 1920, y: 600), "left across the seam of two screens: moved wholly onto the one it mostly covers (\(text(straddling)))")

        let corner = FloatingPlacement.clamp(CGPoint(x: -500, y: -500), size: size, screens: [main, right, above])
        check(whole(corner, on: [main, right, above]) && corner == CGPoint(x: 0, y: 40), "far off every screen: the nearest corner (\(text(corner)))")

        let between = FloatingPlacement.clamp(CGPoint(x: 100, y: 1500), size: size, screens: [main, above])
        check(whole(between, on: [main, above]), "in the dead space beside a smaller screen above: back onto a screen (\(text(between)))")

        let wide = CGSize(width: 424, height: 40)
        let grown = FloatingPlacement.clamp(CGPoint(x: 1700, y: 500), size: wide, screens: [main])
        check(grown == CGPoint(x: 1920 - 424, y: 500), "grown wider near the right edge: slides left to fit (\(text(grown)))")

        let tiny = FloatingPlacement.clamp(CGPoint(x: 50, y: 30), size: size, screens: [CGRect(x: 0, y: 0, width: 200, height: 30)])
        check(tiny == CGPoint(x: 0, y: 30), "a screen smaller than the meter: its top left corner is the one kept on it (\(text(tiny)))")

        check(FloatingPlacement.layoutKey([main, right]) == FloatingPlacement.layoutKey([right, main]) && FloatingPlacement.layoutKey([main, right]) != FloatingPlacement.layoutKey([main, above]) && FloatingPlacement.layoutKey([main]) == "0,0,1920,1080", "an arrangement of screens has one name whatever order they are listed in, and a different one from any other")

        // The words.
        check(FloatingReadings.percent(0.234) == "23%" && FloatingReadings.percent(1) == "100%" && FloatingReadings.percent(1.7) == "100%" && FloatingReadings.percent(0) == "0%", "a load reads 23%, 100% at most, 0% at least")
        check(FloatingReadings.degrees(58.4) == "58°" && FloatingReadings.degrees(117.6) == "118°", "a temperature reads 58° and 118°")
        check(FloatingReadings.watts(86.2) == "86W" && FloatingReadings.watts(1240.4) == "1240W" && FloatingReadings.watts(-3) == "0W", "a draw reads 86W and 1240W")
        let blank = FloatingReadings()
        check(blank.cpu == "--%" && blank.gpu == "--%" && blank.temperature == "--°" && blank.power == "--W", "before the first reading the figures are dashes")

        let all = FloatingStrip(readings: .demo, figures: FloatingFigure.allCases, opacity: 0.85)
        let usual = FloatingStrip(readings: .demo, figures: FloatingFigure.usual, opacity: 0.85)
        check(usual.segments.map(\.label) == ["CPU", "GPU", "TEMP", "POWER"] && usual.segments.map(\.figure) == ["37%", "92%", "71°", "148W"], "the usual four: processor, graphics, temperature, power")
        check(all.segments.count == 7 && all.segments.suffix(2).map(\.label) == ["↓ MB/s", "↑ MB/s"] && all.segments.suffix(2).map(\.figure) == ["24", "1.8"], "the network is two figures, each with its unit above it")
        check(usual.size == CGSize(width: 247, height: 40) && all.size.height == 40 && all.size.width > usual.size.width, "the usual strip is 247 by 40 points, and wider with more on it (\(Int(all.size.width)))")
        // The longest thing each figure can read fits the room it keeps.
        var longest = FloatingReadings()
        (longest.cpu, longest.gpu, longest.temperature, longest.power, longest.memory) = ("100%", "100%", "118°", "999W", "100%")
        (longest.down, longest.downUnit, longest.up, longest.upUnit) = ("999", "KB/s", "1.2", "GB/s")
        let full = FloatingStrip(readings: longest, figures: FloatingFigure.allCases, opacity: 1)
        check(full.segments.allSatisfy { $0.figure.count <= $0.room && CGFloat(DotText.columns($0.label)) * FloatingStrip.labelPitch <= FloatingStrip.width($0) } && full.size == all.size, "the longest figures fit their places, and the strip is no wider for them")
        longest.power = "1240W"
        let kilowatt = FloatingStrip(readings: longest, figures: FloatingFigure.allCases, opacity: 1)
        check(kilowatt.segments.first { $0.label == "POWER" }?.room == 5 && kilowatt.size.width == full.size.width + 6 * FloatingStrip.pitch, "a draw over a kilowatt gets a fifth place")
        let characters = Set((full.segments + all.segments + FloatingStrip(readings: blank, figures: FloatingFigure.allCases, opacity: 1).segments).flatMap { $0.label + $0.figure })
        let unknown = characters.filter { !DotText.knows($0) }
        check(unknown.isEmpty, "the dot font has all \(characters.count) characters the meter uses\(unknown.isEmpty ? "" : ", but not: " + String(unknown.sorted()))")

        // The picture: something lit where the first figure is, nothing outside the rounded card.
        if let image = BitmapPen.render(size: usual.size, scale: 2, { usual.draw($0, usual.size, scale: 2) }), let data = image.dataProvider?.data, let pixels = CFDataGetBytePtr(data) {
            func alpha(_ x: Int, _ y: Int) -> Int { Int(pixels[y * image.bytesPerRow + x * 4 + 3]) }
            func brightest(_ x: Int, _ y: Int) -> Int { let p = y * image.bytesPerRow + x * 4; return Int(max(pixels[p], pixels[p + 1], pixels[p + 2])) }
            var lit = 0
            for y in 36..<64 { for x in 24..<116 where brightest(x, y) > 150 { lit += 1 } }
            let middle = alpha(image.width / 2, 4)
            check(image.width == 494 && image.height == 80 && alpha(0, 0) == 0 && alpha(image.width - 1, image.height - 1) == 0 && abs(middle - Int(0.85 * 255)) <= 26 && lit > 150, "drawn at 2x: clear corners, a backdrop at 85%, and a lit first figure (\(lit) bright pixels)")
        } else {
            check(false, "the strip could be drawn")
        }

        // Settings: which figures a saved list means.
        check(FloatingMeterSettings.figures(named: nil) == FloatingFigure.usual && FloatingMeterSettings.figures(named: []) == FloatingFigure.usual && FloatingMeterSettings.figures(named: ["network", "cpu", "nonsense"]) == [.cpu, .network], "a list of figures is kept in the usual order, and an empty or unknown one means the usual four")
        check(FloatingMeterController.level.rawValue > NSWindow.Level.popUpMenu.rawValue && FloatingMeterController.behavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]), "the panel's level is above menus and it joins every space, full-screen ones too (level \(FloatingMeterController.level.rawValue))")
        let menu = FloatingMeterController.shared.contextMenu()
        let titles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        let levels = menu.items.first { $0.title == "Opacity" }?.submenu?.items.map(\.title) ?? []
        check(titles == ["Processor", "Graphics", "Temperature", "Power", "Memory", "Network", "-", "Opacity", "Click Through", "-", "Hide"] && levels == ["40%", "55%", "70%", "85%", "100%"] && menu.items.allSatisfy { $0.isSeparatorItem || $0.submenu != nil || ($0.target != nil && $0.action != nil) }, "a right-click offers the six figures, five opacities, Click Through and Hide")
        check(FloatingMeterController.shared.clickThroughItem() == nil, "the menu bar's Click Through item is only there while the meter shows")
        check(!FloatingMeterController.shared.isOn, "the meter is not shown by a self-test")

        print(failed == 0 ? "all floating checks pass" : "\(failed) FAILED")
    }
}

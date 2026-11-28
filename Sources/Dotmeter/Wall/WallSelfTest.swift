import AppKit

extension DebugTools {
    /// `--self-test wall`: the lattice and the layout for a range of screens, the dot font, the two pictures, and
    /// the layers as the graphics card composes them. Opens nothing and saves nothing.
    @MainActor
    static func wallSelfTest(models: AppModels) async {
        var failed = 0
        func check(_ ok: Bool, _ note: String) {
            if !ok { failed += 1 }
            print("\(ok ? "ok" : "FAILED") \(note)")
        }

        // Screens in pixels: 4K, 1440p, 1080p, 5K, 6K, two MacBooks, an ultra-wide, small ones, one on its side.
        let screens = [(3840, 2160), (2560, 1440), (1920, 1080), (5120, 2880), (6016, 3384), (3456, 2234), (2940, 1912), (3440, 1440), (5120, 1440), (1366, 768), (1280, 720), (1024, 768), (2160, 3840), (1440, 2560)]
        let fullest = WallReading.fullest
        for (width, height) in screens {
            let layout = WallLayout(width: width, height: height)
            var faults: [String] = []
            if layout.pitch < 3 || layout.dot < 1 || layout.dot >= layout.pitch || layout.lead + layout.dot > layout.pitch { faults.append("pitch \(layout.pitch) with \(layout.dot) lit") }
            // The lattice covers the screen wherever the picture has drifted to, and the safe dots stay on it.
            let period = 16 * layout.pitch * layout.pitch
            var furthest = 0, longestStep = 0
            var last = layout.driftOffset(step: 0)
            for step in 0...period {
                let offset = layout.driftOffset(step: step)
                furthest = max(furthest, abs(offset.x), abs(offset.y))
                longestStep = max(longestStep, abs(offset.x - last.x), abs(offset.y - last.y))
                last = offset
                let left = layout.originX + offset.x, top = layout.originY + offset.y
                if left > 0 || top > 0 || left + layout.cols * layout.pitch < width || top + layout.rows * layout.pitch < height { faults.append("lattice edge in view at step \(step)"); break }
                let safeLeft = left + layout.safe.x * layout.pitch, safeTop = top + layout.safe.y * layout.pitch
                if safeLeft < 0 || safeTop < 0 || left + layout.safe.maxX * layout.pitch > width || top + layout.safe.maxY * layout.pitch > height { faults.append("safe dots off screen at step \(step)"); break }
            }
            if furthest > layout.drift { faults.append("drifts \(furthest) px") }
            if longestStep > max(1, layout.pitch / 4) { faults.append("steps \(longestStep) px") }
            if furthest == 0 { faults.append("never drifts") }
            if !layout.safe.contains(layout.content) || !layout.content.contains(layout.header) { faults.append("header outside") }
            for (index, tile) in layout.tiles.enumerated() {
                if !layout.content.contains(tile) { faults.append("tile \(index) outside") }
                for other in layout.tiles[(index + 1)...] where tile.x < other.maxX && other.x < tile.maxX && tile.y < other.maxY && other.y < tile.maxY { faults.append("tiles overlap") }
                let parts = layout.parts(tile)
                if parts.chart.height < 8 || !tile.contains(parts.chart) { faults.append("chart of \(parts.chart.height) rows") }
            }
            if layout.tiles.count != WallTile.allCases.count || layout.rule <= layout.header.maxY - 1 || layout.rule >= (layout.tiles.first?.y ?? 0) { faults.append("rule or tile count") }
            // The longest figure of every tile fits the narrowest tile.
            let narrowest = layout.tiles.map(\.width).min() ?? 0
            let figures = WallLayout.longest + fullest.tiles.map { ($0.number, $0.unit) } + [("100", "%"), ("118", "°"), ("1.2", "GB/s")]
            for figure in figures {
                let wide = WallLayout.figureColumns(figure.0, figure.1, scale: layout.figureScale, unitScale: layout.unitScale)
                if wide > narrowest { faults.append("\(figure.0)\(figure.1) is \(wide) dots in a tile of \(narrowest)") }
            }
            // Drawn with the longest words everywhere, nothing lands off the lattice or outside the content.
            let canvas = WallPicture.draw(fullest, layout: layout)
            if canvas.clipped > 0 { faults.append("\(canvas.clipped) dots off the lattice") }
            if let bounds = canvas.litBounds { if !layout.content.contains(bounds) { faults.append("lit dots outside the content") } } else { faults.append("nothing lit") }
            // A tile's words stay inside it: the column of gap to its right stays dark.
            for (index, tile) in layout.tiles.enumerated() where tile.maxX < layout.content.maxX {
                let parts = layout.parts(tile)
                if (parts.labelY..<parts.chart.y).contains(where: { canvas.isLit(tile.maxX, $0) || canvas.isLit(tile.maxX + 1, $0) }) { faults.append("tile \(index) spills to the right") }
            }
            let tile = layout.tiles[0]
            check(faults.isEmpty, "\(width)x\(height): pitch \(layout.pitch) px with \(layout.dot) lit, \(layout.cols) by \(layout.rows) dots, figures x\(layout.figureScale), tiles \(tile.width) by \(tile.height), charts \(layout.parts(tile).chart.height) rows, drift within \(furthest) px\(faults.isEmpty ? "" : " — " + faults.joined(separator: "; "))")
        }
        check(WallLayout(width: 3840, height: 2160).pitch == 8 && WallLayout(width: 2560, height: 1440).pitch == 5 && WallLayout(width: 1920, height: 1080).pitch == 4, "pitch is 8, 5 and 4 pixels at 4K, 1440p and 1080p")

        // Every character the wall can show is in the font, and is drawn as wide as it is measured.
        var used = Set("0123456789.:%°/ ·,-")
        for tile in WallTile.allCases { used.formUnion(tile.label) }
        for text in ["RPM", "W", "KB/s", "MB/s", "GB/s", "NONE", "BUSIEST APP", "peak", "of range", "memory", "cores", "free", "up", "P E", "AM PM", "d h m", "TB GB MB KB B", "Nominal Fair Serious Critical", "CPU GPU SoC Storage Memory Power Airflow"] { used.formUnion(text) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for month in 1...12 {
            for day in [1, 8, 15, 22, 28] {
                guard let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: (month * 2) % 24, minute: day)) else { continue }
                used.formUnion(WallReading.dateText(date))
                let clock = WallReading.clockText(date)
                used.formUnion(clock.clock + clock.suffix)
            }
        }
        let unknown = used.filter { !DotText.knows($0) }
        check(unknown.isEmpty, "the dot font has all \(used.count) characters the wall uses\(unknown.isEmpty ? "" : ", but not: " + String(unknown.sorted()))")
        var misdrawn: [Character] = []
        for character in used.sorted() where character != " " {
            for scale in [1, 2, 4] {
                var canvas = DotCanvas(cols: 40, rows: 40)
                let width = canvas.text(String(character), x: 3, y: 3, scale: scale, ink: DotInk(.white))
                let wanted = DotRect(x: 3, y: 3, width: DotText.columns(String(character)) * scale, height: 7 * scale)
                guard let bounds = canvas.litBounds, wanted.contains(bounds), bounds.height <= 7 * scale, width == wanted.width, canvas.clipped == 0 else { misdrawn.append(character); break }
            }
        }
        check(misdrawn.isEmpty, "each is drawn inside the box it is measured as, at one, two and four dots to a dot\(misdrawn.isEmpty ? "" : ": not " + String(misdrawn))")
        check(DotFont.rows("°") == [0b01100, 0b10010, 0b10010, 0b01100, 0, 0, 0], "the degree sign is a ring at the top of its cell")
        check(DotText.columns("1.2") == 14 && DotText.columns("14:32") == 5 * 4 + 2 + 4 && DotText.columns("100%") == 23, "a full stop and a colon take two columns, every other character five")
        check(DotText.drawable("Café ☕ Pro") == "Caf  Pro" && DotText.fitted("Final Cut Pro", columns: 47, scale: 1) == "Final Cu", "a name loses what the font cannot draw and is cut to fit")

        // The words on the tiles.
        let rates: [(Double, String, String)] = [(0, "0", "KB/s"), (380_400, "380", "KB/s"), (999_400, "999", "KB/s"), (999_600, "1.0", "MB/s"), (9_940_000, "9.9", "MB/s"), (12_400_000, "12", "MB/s"), (999_400_000, "999", "MB/s"), (1_240_000_000, "1.2", "GB/s")]
        let wrong = rates.filter { WallReading.rate($0.0).number != $0.1 || WallReading.rate($0.0).unit != $0.2 }
        check(wrong.isEmpty, "rates read 0 KB/s, 380 KB/s, 999 KB/s, 1.0 MB/s, 9.9 MB/s, 12 MB/s, 999 MB/s, 1.2 GB/s\(wrong.isEmpty ? "" : ": not \(wrong.map { "\($0.0)" })")")
        check(WallReading.ceiling(64, floor: 20) == 100 && WallReading.ceiling(3, floor: 20) == 20 && WallReading.ceiling(170, floor: 20) == 200, "a chart's top is the next round figure above its peak")
        let empty = WallReading.make(snapshot: nil, history: [])
        check(empty.tiles.count == 9 && empty.tiles.allSatisfy { $0.number == "--" } && empty.busiest == nil, "with no reading yet every tile shows two dashes")
        let demo = WallReading.demo(at: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let demoLayout = WallLayout(width: 1920, height: 1080)
        let demoFits = demo.tiles.allSatisfy { WallLayout.figureColumns($0.number, $0.unit, scale: demoLayout.figureScale, unitScale: demoLayout.unitScale) <= demoLayout.tiles[0].width }
        check(demo.tiles.count == 9 && demoFits && demo.tiles.allSatisfy { $0.values.count == 151 && $0.values.allSatisfy { $0 >= 0 && $0 <= 1 } }, "the made-up readings fill nine tiles with five minutes each")

        // The charts.
        let columns = WallPicture.buckets(times: [0, 100, 300], values: [0.2, 0.9, 0.5], columns: 7, span: 300)
        check(columns.count == 7 && columns[0] == 0.2 && columns[1] == 0.2 && columns[2] == 0.9 && columns[6] == 0.5, "a chart puts the newest reading in its last column and carries a value across a gap")
        check(WallPicture.buckets(times: [0, 400, 700], values: [1, 0.5, 0.25], columns: 4, span: 300) == [0.5, 0.5, 0.5, 0.25], "readings older than five minutes are left out")

        // The two pictures: a lit dot keeps its colour, the dots beside it pick up a little, far ones none.
        var canvas = DotCanvas(cols: 40, rows: 30)
        let ink = DotInk(RGB(r: 1, g: 1, b: 1))
        canvas.fill(DotRect(x: 10, y: 10, width: 4, height: 4), ink)
        canvas.markTrack(DotRect(x: 30, y: 20, width: 5, height: 5))
        if let pictures = canvas.pictures(), let dots = bytes(of: pictures.dots), let glow = bytes(of: pictures.glow) {
            func dot(_ x: Int, _ y: Int) -> Int { Int(dots[(y * 40 + x) * 4]) }
            func halo(_ x: Int, _ y: Int) -> Int { Int(glow[(y * 40 + x) * 4]) }
            check(pictures.dots.width == 40 && pictures.dots.height == 30 && pictures.glow.width == 40, "the pictures are a pixel a dot")
            check(dot(11, 11) == Int(ink.r) && dot(14, 11) > dot(0, 0) && dot(14, 11) < Int(ink.r) / 2 && dot(25, 5) == dot(0, 0), "a lit dot keeps its colour, the one beside it picks up a little, far ones nothing (\(dot(11, 11)), \(dot(14, 11)), \(dot(0, 0)))")
            check(dot(32, 22) > dot(0, 0), "an unlit dot inside a chart shows brighter than the lattice round it (\(dot(32, 22)) against \(dot(0, 0)))")
            check(halo(11, 11) > halo(14, 11) && halo(14, 11) > halo(16, 11) && halo(18, 11) == 0 && halo(11, 11) < 128, "the glow falls away over three dots and never closes the gaps (\(halo(11, 11)), \(halo(14, 11)), \(halo(16, 11)), \(halo(18, 11)))")
        } else {
            check(false, "the pictures could be made")
        }

        // The layers as the graphics card puts them together, at 1080p and on a screen whose pitch is odd.
        for (width, height, minute) in [(1920, 1080, 0), (2560, 1440, 3)] {
            let surface = WallSurface()
            surface.resize(pixelWidth: width, pixelHeight: height, scale: 1)
            surface.drift(step: minute)
            surface.show(fullest)
            guard let layout = surface.layout, let image = surface.rendered(), let pixels = bytes(of: image) else {
                check(false, "\(width)x\(height): the layers could be rendered")
                continue
            }
            let drawn = WallPicture.draw(fullest, layout: layout)
            let offset = surface.driftOffset
            // A pixel's brightness, as the largest of its three colours.
            func level(_ x: Int, _ y: Int) -> Int {
                guard x >= 0, y >= 0, x < width, y < height else { return -1 }
                let p = (y * image.bytesPerRow) + x * 4
                return Int(max(pixels[p], pixels[p + 1], pixels[p + 2]))
            }
            func corner(_ column: Int, _ row: Int) -> (x: Int, y: Int) {
                (layout.originX + offset.x + column * layout.pitch + layout.lead, layout.originY + offset.y + row * layout.pitch + layout.lead)
            }
            var faults: [String] = []
            // A lit dot of the clock, bright from corner to corner, with darker gaps on each side of it.
            var found = false
            search: for row in layout.header.y..<layout.header.maxY {
                for column in layout.header.x..<layout.header.maxX where drawn.isLit(column, row) {
                    let at = corner(column, row)
                    let inside = [level(at.x, at.y), level(at.x + layout.dot - 1, at.y + layout.dot - 1), level(at.x + layout.dot / 2, at.y + layout.dot / 2)]
                    let gaps = [level(at.x + layout.dot, at.y), level(at.x, at.y + layout.dot)]
                    if inside.min() ?? 0 < 200 { faults.append("a lit dot reads \(inside)") }
                    if (gaps.max() ?? 255) > 170 { faults.append("the gap beside a lit dot reads \(gaps)") }
                    if (gaps.min() ?? 0) < 8 { faults.append("no glow in the gap beside a lit dot: \(gaps)") }
                    found = true
                    break search
                }
            }
            if !found { faults.append("no lit dot in the header") }
            // An unlit dot in the margin, far from any light: dim but there, and its gaps black.
            let quiet = corner(layout.safe.x, layout.safe.maxY - 1)
            let unlit = level(quiet.x + layout.dot / 2, quiet.y + layout.dot / 2), gap = level(quiet.x + layout.dot, quiet.y + layout.dot)
            if unlit < 4 || unlit > 30 { faults.append("an unlit dot reads \(unlit)") }
            if gap != 0 { faults.append("the gap between unlit dots reads \(gap)") }
            if image.width != width || image.height != height { faults.append("\(image.width)x\(image.height)") }
            check(faults.isEmpty, "\(width)x\(height), \(minute) minutes into its drift (\(offset.x),\(offset.y) px): the layers render sharp dots, dark gaps and a glow\(faults.isEmpty ? "" : " — " + faults.joined(separator: "; "))")
        }

        // The screens to choose from, as this Mac has them now.
        let choices = WallScreens.choices
        check(!choices.isEmpty && Set(choices.map(\.id)).count == choices.count && WallScreens.target("") != nil && WallScreens.screen(for: "no such screen") == nil, "this Mac's \(choices.count == 1 ? "one screen" : "\(choices.count) screens") can be told apart, and a screen that is gone falls back to the pointer's")
        check(!WallController.shared.isOpen && !WallController.shared.isHoldingAwake, "the wall is closed and holds nothing awake until it is opened")

        print(failed == 0 ? "all wall checks pass" : "\(failed) FAILED")
    }

    /// The raw bytes of a picture, four to a pixel.
    private static func bytes(of image: CGImage) -> [UInt8]? {
        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: CFDataGetLength(data)))
    }
}

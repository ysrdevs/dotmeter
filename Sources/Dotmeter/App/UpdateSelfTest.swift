import AppKit
import DotmeterShared

extension DebugTools {
    /// `Dotmeter --self-test update`: versions, GitHub's answer, and the signature check.
    ///
    /// With DOTMETER_UPDATE_TEST_IMAGE=<a notarized Dotmeter disk image> it also runs a whole install, on a copy of
    /// this app made in a temporary folder: download (from the file), check, put in place. It never touches the
    /// app it is run from and never starts anything.
    static func updateSelfTest() async {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ got: Any = "") {
            if !ok { failed += 1 }
            print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : " (got \(got))")")
        }
        func version(_ text: String) -> AppVersion { AppVersion(text)! }

        check("2.0.10 comes after 2.0.9", version("2.0.10") > version("2.0.9"))
        check("v2.1 is 2.1.0", version("v2.1") == version("2.1.0"))
        check("2.0.2 is not newer than itself", !(version("2.0.2") > version("2.0.2")))
        check("a tag that is not a version is refused", AppVersion("latest") == nil && AppVersion("2.0-beta") == nil && AppVersion("") == nil && AppVersion("1..2") == nil)

        func feed(tag: String = "v2.1", asset: String = "https://github.com/ysrdevs/dotmeter/releases/download/v2.1/Dotmeter-2.1.dmg", name: String = "Dotmeter-2.1.dmg", extra: String = "") -> Data {
            Data("""
            {"tag_name":"\(tag)","name":"Dotmeter 2.1","draft":false,"prerelease":false\(extra),"html_url":"https://github.com/ysrdevs/dotmeter/releases/tag/v2.1",
             "body":"Lighter.\\r\\n\\r\\n## Fixed\\r\\n\\r\\n- One thing.\\r\\n\\r\\n## Install\\r\\n\\r\\nDownload the image below.\\r\\n\\r\\n## Checksum\\r\\n\\r\\nabc",
             "assets":[{"name":"notes.txt","browser_download_url":"https://example.com/notes.txt","size":3},{"name":"\(name)","browser_download_url":"\(asset)","size":10248709}]}
            """.utf8)
        }
        let parsed = UpdateFeed.parse(feed(), localFiles: false)
        check("GitHub's answer gives the version, the image and its size", parsed?.version == "2.1" && parsed?.image.lastPathComponent == "Dotmeter-2.1.dmg" && parsed?.size == 10_248_709, parsed as Any)
        check("the notes stop before Install", parsed?.notes == "Lighter.\n\n## Fixed\n\n- One thing.", parsed?.notes as Any)
        check("an image that does not come over HTTPS is refused", UpdateFeed.parse(feed(asset: "http://example.com/Dotmeter-2.1.dmg"), localFiles: false) == nil)
        check("a local image is refused unless the feed is a local one", UpdateFeed.parse(feed(asset: "file:///tmp/Dotmeter-2.1.dmg"), localFiles: false) == nil && UpdateFeed.parse(feed(asset: "file:///tmp/Dotmeter-2.1.dmg"), localFiles: true) != nil)
        check("a release with no disk image is refused", UpdateFeed.parse(feed(name: "Dotmeter-2.1.zip"), localFiles: false) == nil)
        check("a tag that is not a version is refused", UpdateFeed.parse(feed(tag: "nightly"), localFiles: false) == nil)
        check("an answer that is not a release is refused", UpdateFeed.parse(Data("{\"message\":\"Not Found\"}".utf8), localFiles: false) == nil && UpdateFeed.parse(Data("<html>".utf8), localFiles: false) == nil)

        let fm = FileManager.default
        let own = Bundle.main.bundleURL
        check("a folder that cannot be changed is noticed", UpdateInstaller.whyNotInPlace(URL(fileURLWithPath: "/System/Applications/Calculator.app")) != nil)
        check("so is a copy macOS runs from a temporary place", UpdateInstaller.whyNotInPlace(URL(fileURLWithPath: "/private/var/folders/xx/T/AppTranslocation/1234/d/Dotmeter.app")) != nil)

        // Whatever this copy is, another developer's app must not pass for Dotmeter.
        var refusedOther = false
        do { try UpdateInstaller.verify(URL(fileURLWithPath: "/System/Applications/Calculator.app"), newerThan: version("0")) } catch { refusedOther = (error as? UpdateError) == .signature }
        check("another app is refused", refusedOther)
        var ownResult = "accepted"
        do { try UpdateInstaller.verify(own, newerThan: version("0")) } catch { ownResult = "\(error)" }
        print("     this copy, checked as an update: \(ownResult)")

        guard let imagePath = ProcessInfo.processInfo.environment["DOTMETER_UPDATE_TEST_IMAGE"] else {
            print(failed == 0 ? "all checks pass (no install: DOTMETER_UPDATE_TEST_IMAGE is not set)" : "\(failed) FAILED")
            return
        }
        guard own.pathExtension == "app" else { print("FAIL the install test needs the app bundle, not the bare program"); return }

        let scratch = fm.temporaryDirectory.appendingPathComponent("\(App.name)-update-test-\(UUID().uuidString)", isDirectory: true)
        let folder = scratch.appendingPathComponent("Applications", isDirectory: true)
        let installed = folder.appendingPathComponent(own.lastPathComponent)
        defer {
            chmod(folder.path, 0o755)
            try? fm.removeItem(at: scratch)
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: own, to: installed)
        } catch {
            print("FAIL could not make the scratch copy: \(error.localizedDescription)")
            return
        }
        func shortVersion(_ app: URL) -> String { (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "?" }
        func program(_ app: URL) -> Data { (try? Data(contentsOf: app.appendingPathComponent("Contents/MacOS/\(App.name)"))) ?? Data() }
        let size = ((try? fm.attributesOfItem(atPath: imagePath))?[.size] as? NSNumber)?.int64Value ?? 0
        let feedFile = scratch.appendingPathComponent("latest.json")
        try? feed(tag: "v99.0", asset: URL(fileURLWithPath: imagePath).absoluteString, name: "Dotmeter-99.0.dmg").write(to: feedFile)
        var release = try? await UpdateFeed.latest(from: feedFile)
        release?.size = size
        check("a local feed is read", release?.version == "99.0" && release?.image.isFileURL == true, release as Any)
        guard let release else { print("\(failed) FAILED"); return }

        // An old release must not be put back over a newer copy.
        var notNewer = false
        do { _ = try await UpdateInstaller.prepare(release, destination: installed, running: version("98.0"), report: { _ in }) } catch { if case .notNewer = error as? UpdateError { notNewer = true } }
        check("a version that is not newer is refused", notNewer)
        check("and the copy is left as it was", program(installed) == program(own))

        // A folder the app may not change: the checked image is kept for the person to open.
        chmod(folder.path, 0o555)
        if case .byHand(let image, let why)? = try? await UpdateInstaller.prepare(release, destination: installed, running: version("0.1"), report: { _ in }) {
            check("where it cannot replace itself, the checked image is kept (\(why))", fm.fileExists(atPath: image.path))
            try? fm.removeItem(at: image.deletingLastPathComponent())
        } else {
            check("where it cannot replace itself, the checked image is kept", false)
        }
        chmod(folder.path, 0o755)

        // A file that is not a disk image.
        let junk = scratch.appendingPathComponent("junk.dmg")
        try? Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: junk)
        var junkRefused = false
        do { _ = try await UpdateInstaller.prepare(UpdateRelease(version: "99.0", notes: "", page: release.page, image: junk, size: 4096), destination: installed, running: version("0.1"), report: { _ in }) } catch { junkRefused = (error as? UpdateError) == .image }
        check("a file that is not a disk image is refused", junkRefused)

        // The real thing.
        final class Steps: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [String] = []
            func add(_ step: String) { lock.lock(); seen.append(step); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return seen }
        }
        let steps = Steps()
        do {
            let prepared = try await UpdateInstaller.prepare(release, destination: installed, running: version("0.1")) { step in
                if case .checking = step { steps.add("checking") }
            }
            guard case .staged(let staged, let work) = prepared else { check("the image is checked and a copy made ready", false, prepared); print("\(failed) FAILED"); return }
            check("the image is checked and a copy made ready", fm.fileExists(atPath: staged.path) && steps.all == ["checking"], steps.all)
            let newVersion = shortVersion(staged)
            let newProgram = program(staged)
            try UpdateInstaller.swap(staged: staged, work: work, destination: installed)
            check("the new copy takes the old one's place (\(shortVersion(own)) to \(newVersion))", program(installed) == newProgram && !newProgram.isEmpty && shortVersion(installed) == newVersion)
            check("the old copy and the working folder are gone", !fm.fileExists(atPath: work.path))
            var stillGood = true
            do { try UpdateInstaller.verify(installed, newerThan: version("0.1")) } catch { stillGood = false }
            check("what was installed is signed by the developer and notarized", stillGood)
        } catch {
            check("the install goes through", false, error)
        }

        // The installed copy is now a notarized one: change one byte of it three ways.
        for (what, path) in [("its program", "Contents/MacOS/\(App.name)"), ("its Info.plist", "Contents/Info.plist"), ("its helper", "Contents/MacOS/\(App.name)Helper")] {
            let copy = scratch.appendingPathComponent("changed.app")
            try? fm.removeItem(at: copy)
            try? fm.copyItem(at: installed, to: copy)
            let file = copy.appendingPathComponent(path)
            var changed = false
            if var data = try? Data(contentsOf: file), !data.isEmpty {
                data[data.count / 2] ^= 0x01
                changed = (try? data.write(to: file)) != nil
            }
            var refused = false
            do { try UpdateInstaller.verify(copy, newerThan: version("0.1")) } catch { refused = (error as? UpdateError) == .signature }
            check("a copy with one bit of \(what) changed is refused", changed && refused, "changed \(changed), refused \(refused)")
        }

        let left = (try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path))?.filter { $0.hasPrefix("\(App.name)-update-") && !$0.hasPrefix("\(App.name)-update-test-") } ?? []
        check("no download or opened image is left behind", left.isEmpty, left)
        print("     own copy untouched: \(shortVersion(own)) at \(own.path)")
        print(failed == 0 ? "all checks pass" : "\(failed) FAILED")
    }
}

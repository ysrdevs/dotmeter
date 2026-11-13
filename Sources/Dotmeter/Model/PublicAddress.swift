import Foundation
import Observation

/// The address the rest of the internet sees this Mac at, which only something outside the network can tell it.
///
/// It is asked of Cloudflare's resolver at `1.1.1.1`, the same host the latency echoes already go to: one small
/// HTTPS request for its plain-text trace page, whose `ip=` line is the caller's address. It is asked only while
/// a view that shows it is open, at most once every five minutes for the same connection, and not at all when
/// the setting is off.
@MainActor
@Observable
final class PublicAddress {
    enum State: Equatable {
        case unknown, looking, failed
        case known(String)
    }

    private(set) var state: State = .unknown
    /// Where the answer says this Mac appears to be: the country its address is registered in, and the
    /// Cloudflare site that took the request, which is near wherever the traffic leaves for the internet. Both
    /// are in the page that carries the address, so they cost nothing more. With a VPN or a relay they are the
    /// tunnel's far end, which is the point of showing them.
    private(set) var place: Place?

    struct Place: Equatable {
        /// "CA"
        var country: String?
        /// "YVR": the airport code Cloudflare names its sites by.
        var site: String?

        /// "Canada · leaves near YVR"
        var text: String? {
            var parts: [String] = []
            if let country { parts.append(Locale.current.localizedString(forRegionCode: country) ?? country) }
            if let site { parts.append("leaves near \(site)") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
    @ObservationIgnored private var checkedAt: Date?
    @ObservationIgnored private var checkedFor: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// By literal address, so no name is looked up first, and IPv4 first because that is the address people mean.
    nonisolated private static let sources = ["https://1.1.1.1/cdn-cgi/trace", "https://[2606:4700:4700::1111]/cdn-cgi/trace"]
    private static let keepFor: TimeInterval = 300

    var address: String? {
        if case .known(let address) = state { return address }
        return nil
    }

    /// `connection` names the way out (interface, local address, router): a different one is asked about afresh.
    func lookUp(for connection: String, force: Bool = false) {
        if NetworkSampler.demo {
            // A documentation address, and nothing leaves the Mac.
            state = .known("203.0.113.42")
            place = Place(country: "CA", site: "YVR")
            return
        }
        if !force, checkedFor == connection, let checkedAt, Date().timeIntervalSince(checkedAt) < Self.keepFor, state != .failed { return }
        if task != nil, checkedFor == connection { return }
        task?.cancel()
        if checkedFor != connection || address == nil {
            state = .looking
            place = nil
        }
        checkedFor = connection
        task = Task { [weak self] in
            let found = await Self.fetch()
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.checkedAt = Date()
            self.state = (found?.address).map(State.known) ?? .failed
            self.place = found?.place
        }
    }

    /// Forgets what was found, for when the lookup is switched off.
    func clear() {
        task?.cancel()
        task = nil
        checkedAt = nil
        checkedFor = nil
        state = .unknown
        place = nil
    }

    nonisolated private static func fetch() async -> (address: String, place: Place?)? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for source in sources {
            guard let url = URL(string: source), let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data.prefix(4096), encoding: .utf8) else { continue }
            if let address = parse(text) { return (address, parsePlace(text)) }
        }
        return nil
    }

    /// The `loc=` and `colo=` lines of the same page: two letters for the country, three for the site. Anything
    /// else is dropped.
    nonisolated static func parsePlace(_ text: String) -> Place? {
        var place = Place()
        for line in text.split(whereSeparator: \.isNewline) {
            func value(_ key: String, length: Int) -> String? {
                guard line.hasPrefix(key) else { return nil }
                let value = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces).uppercased()
                return value.count == length && value.allSatisfy { $0.isLetter && $0.isASCII } ? value : nil
            }
            if let country = value("loc=", length: 2), country != "XX" { place.country = country }
            if let site = value("colo=", length: 3) { place.site = site }
        }
        return place.country == nil && place.site == nil ? nil : place
    }

    /// The `ip=` line of the trace page, accepted only if it looks like an address.
    nonisolated static func parse(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("ip=") {
            let value = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")
            guard (3...45).contains(value.count), value.unicodeScalars.allSatisfy(allowed.contains), value.contains(".") || value.contains(":") else { return nil }
            return value
        }
        return nil
    }
}

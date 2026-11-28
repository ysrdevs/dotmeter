import Foundation
import Network
import Security

/// How two Macs reach each other: TCP, with TLS keyed by the group code.
///
/// Neither end has a certificate. Both hold a key made from the code, and the TLS handshake only completes when
/// the two keys are the same, so a Mac with another code (or none) never gets as far as a first message.
enum MacsTransport {
    static let serviceType = "_dotmeter._tcp"

    static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let key = MacsCode.key(for: code).withUnsafeBytes { DispatchData(bytes: $0) }
        // The identity only names which key is meant; every Mac uses the same one and it says nothing.
        let identity = Data("dotmeter-macs".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
        // Pre-shared keys are a TLS 1.2 arrangement in Network.framework, with this suite.
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(options, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 6
        // A Mac that falls asleep or leaves the network says nothing on its way out. These let TCP give up on it
        // in seconds, not the minutes it would otherwise keep trying.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 8
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        tcp.connectionDropTime = 15
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
}

/// One connection between two Macs, either way round, as whole messages. Everything happens on the main queue.
@MainActor
final class MacsLink {
    enum End: Equatable {
        /// The handshake failed: the other end holds another code.
        case refused
        /// It never opened: nothing is listening there, or it cannot be reached.
        case unreachable
        /// It opened and has now ended.
        case closed
    }

    var onReady: (() -> Void)?
    var onMessage: ((MacsWire.Message) -> Void)?
    var onEnd: ((End) -> Void)?

    private let connection: NWConnection
    private var buffer = MacsLineBuffer()
    private(set) var ready = false
    private(set) var ended = false
    private(set) var started = Date()
    /// When anything last arrived.
    private(set) var lastHeard = Date()
    /// Messages handed to the connection that it has not sent yet.
    private(set) var unsent = 0
    /// Why it ended, as the system put it. For the self-test.
    private(set) var lastError: String?

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        started = Date()
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(to: state) }
        }
        connection.start(queue: .main)
    }

    private func changed(to state: NWConnection.State) {
        guard !ended else { return }
        switch state {
        case .ready:
            ready = true
            lastHeard = Date()
            onReady?()
            receive()
        case .waiting(let error):
            // Network.framework would keep trying by itself. The model decides when to try again, so stop here.
            finish(ready ? .closed : Self.reason(error), error)
        case .failed(let error):
            finish(ready ? .closed : Self.reason(error), error)
        case .cancelled:
            finish(.closed, nil)
        default:
            break
        }
    }

    /// Why a connection that never opened did not. TLS giving up is the other end refusing the key; anything
    /// from the network itself is the other end not being there.
    private static func reason(_ error: NWError) -> End {
        switch error {
        case .tls: return .refused
        case .posix(let code):
            // A listener that drops the connection in the middle of the handshake is refusing the key as well.
            return code == .ECONNRESET || code == .EPIPE || code == .ENOTCONN ? .refused : .unreachable
        default: return .unreachable
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.ended else { return }
                if let data, !data.isEmpty {
                    self.lastHeard = Date()
                    for line in self.buffer.append(data) {
                        if let message = MacsWire.message(from: line) { self.onMessage?(message) }
                        if self.ended { return }
                    }
                    if self.buffer.overflowed {
                        self.finish(.closed, nil)
                        return
                    }
                }
                if complete || error != nil { self.finish(.closed, error) } else { self.receive() }
            }
        }
    }

    func send(_ message: MacsWire.Message) { send(MacsWire.line(message)) }

    func send(_ line: Data) {
        guard ready, !ended else { return }
        unsent += 1
        connection.send(content: line, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.unsent -= 1
                if let error { self.finish(.closed, error) }
            }
        })
    }

    func close() { finish(.closed, nil) }

    private func finish(_ end: End, _ error: NWError?) {
        guard !ended else { return }
        ended = true
        if let error { lastError = "\(error)" }
        connection.stateUpdateHandler = nil
        connection.cancel()
        onEnd?(end)
    }

    /// The suite the handshake settled on, as its number in the TLS registry. For the self-test.
    var suite: UInt16? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
    }
}

/// Waits for other Macs to connect.
@MainActor
final class MacsListener {
    enum Place: Equatable {
        /// On this Mac only, at that port (0 takes any free one), and not advertised. For tests: nothing leaves
        /// the Mac, so macOS has nothing to ask about.
        case loopback(UInt16)
        /// On the network, advertised to the other Macs under that name.
        case network(service: String)
    }

    enum State: Equatable {
        case starting
        case ready(port: UInt16)
        /// macOS is not letting the app use the local network.
        case blocked
        case failed(String)
    }

    var onLink: ((MacsLink) -> Void)?
    var onState: ((State) -> Void)?
    private(set) var state = State.starting

    private let listener: NWListener

    init?(code: String, place: Place) {
        let parameters = MacsTransport.parameters(code: code)
        parameters.allowLocalEndpointReuse = true
        do {
            switch place {
            case .loopback(let port):
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
                parameters.acceptLocalOnly = true
                listener = try NWListener(using: parameters)
            case .network(let service):
                listener = try NWListener(using: parameters)
                listener.service = NWListener.Service(name: service, type: MacsTransport.serviceType)
            }
        } catch {
            return nil
        }
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(to: state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                self.onLink?(MacsLink(connection))
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    private func changed(to new: NWListener.State) {
        switch new {
        case .ready: state = .ready(port: listener.port?.rawValue ?? 0)
        case .waiting(let error), .failed(let error): state = MacsBrowser.isPolicy(error) ? .blocked : .failed("\(error)")
        default: return
        }
        onState?(state)
    }
}

/// Looks for the other Macs' advertisements on the local network.
@MainActor
final class MacsBrowser {
    /// Every advertisement in sight, by the name it goes under.
    var onResults: (([String: NWEndpoint]) -> Void)?
    /// macOS is not letting the app look at the local network, or is again.
    var onBlocked: ((Bool) -> Void)?

    private let browser: NWBrowser

    init() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        browser = NWBrowser(for: .bonjour(type: MacsTransport.serviceType, domain: nil), using: parameters)
    }

    func start() {
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.onBlocked?(false)
                case .waiting(let error), .failed(let error): if Self.isPolicy(error) { self?.onBlocked?(true) }
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                var found: [String: NWEndpoint] = [:]
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint { found[name] = result.endpoint }
                }
                self?.onResults?(found)
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser.stateUpdateHandler = nil
        browser.browseResultsChangedHandler = nil
        browser.cancel()
    }

    /// The error Bonjour gives when the user has said no under Privacy & Security › Local Network.
    nonisolated static func isPolicy(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }
        return false
    }
}

// MARK: - HTTPServer.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The TCP side of the DLNA server: device descriptions, SOAP control, GENA
// subscription stubs, and media delivery.
//
// Concurrency model
// -----------------
//   • HTTPServer (actor) owns the NWListener and the table of live connections.
//   • Each accepted connection is handed to its own HTTPConnection (actor), which
//     owns that socket's parse buffer and streaming state. No state is shared
//     between connections, so there are no locks anywhere in the request path and
//     a slow media transfer cannot delay a concurrent Browse.
//   • Network.framework delivers its callbacks on a dedicated DispatchQueue; each
//     callback immediately hops into the owning actor and does nothing else, so
//     the queue is never blocked by request handling.

import Foundation
import Network
import Synchronization
import System

// MARK: - HTTPServer
actor HTTPServer: Loggable {
    nonisolated static let logTag = "[HTTPServer]"

    // Errors surfaced to the menu bar as a concrete status string. Distinguishing
    // these is the whole point: "port in use" and "no local network permission"
    // demand completely different fixes, and a generic failure message would leave
    // the user guessing at exactly the moment this app is supposed to be helping.
    enum StartError: Error, Sendable {
        case portInUse(UInt16)
        case failed(String)

        var displayText: String {
            switch self {
            case .portInUse(let port): return "Port \(port) is already in use"
            case .failed(let reason):  return "Server error: \(reason)"
            }
        }
    }

    private let contentIndex: ContentIndex
    // Fired whenever the number of in-flight transfers changes, so the menu bar can
    // show the serving state live rather than only when the menu is opened.
    private let onActiveStreamCountChanged: @Sendable (Int, UInt64) -> Void
    private let queue = DispatchQueue(label: "app.LANStream.http", qos: .userInitiated)

    // MARK: - Active transfers
    // One entry per media transfer currently in flight. This is the app's answer to
    // "is anyone watching something right now", which both the port-change and quit
    // confirmations need before they interrupt the network.
    //
    // Only media streams count. Idle keep-alive connections and one-shot description
    // fetches are not somebody's film stopping mid-scene, and warning about them
    // would train the user to click through the very prompt that matters.
    struct ActiveStream: Sendable, Equatable {
        let peer: String
        let title: String
        let startedAt: Date
    }

    private var streams: [UUID: ActiveStream] = [:]

    // Monotonic counter stamped onto each stream-count notification.
    //
    // The notification hops to the main actor through an unstructured Task, and
    // unstructured Tasks carry no ordering guarantee relative to one another. Two
    // rapid changes — a transfer ending as another begins — could therefore be
    // applied out of order and leave the menu bar showing "serving" over an idle
    // server, or the reverse. The receiver discards anything older than what it has
    // already applied.
    private var streamCountGeneration: UInt64 = 0

    private var listener: NWListener?
    private var connections: [UUID: HTTPConnection] = [:]
    private var boundPort: UInt16?

    // True between the listener reporting .ready and it being torn down or failing.
    // Read by DLNAServer's recovery path, which must be able to distinguish "the
    // HTTP side is fine, only discovery broke" from "the listener is gone" — the
    // two need completely different remedies, and guessing wrong either restarts a
    // healthy transfer or leaves a dead socket in place.
    private var isListenerReadyFlag = false

    // Upper bound on simultaneously accepted connections.
    //
    // Nothing legitimate comes close: a player opens one control connection and one
    // transfer, and even a household of clients plus a couple of phone control apps
    // stays in single digits. The cap exists for the pathological case — a client
    // that opens a socket per seek and never closes any, or something on the LAN
    // scanning ports — where an unbounded table means unbounded file descriptors and
    // memory, and the first symptom is the whole server dying rather than one
    // misbehaving peer being refused.
    private static let maxConnections = 48

    // Rejections are logged, but a scanner hammering the port would otherwise fill
    // the log with thousands of identical lines and bury whatever else went wrong.
    // One line per rejection burst plus a periodic tally keeps the fact visible
    // without destroying the log's usefulness.
    private var rejectedConnectionCount = 0
    private var lastRejectionLogAt: Date?

    // MARK: - Per-peer behavior tracking
    // Diagnostic only: nothing here changes what the server does, and no request is
    // ever refused on the strength of it.
    //
    // It exists because of a failure this log could not describe. A player hard-froze
    // while browsing a large folder and had to be power-cycled, and reconstructing
    // what led up to it meant reading raw timestamps by hand and inferring the reboot
    // from ephemeral port numbers happening to jump ranges. The two facts that would
    // have said it outright were both invisible: how fast that client was opening and
    // discarding connections, and the moment it stopped talking.
    //
    // Neither is visible anywhere else. The connection CAP cannot see it — a client
    // that opens and closes a dozen sockets in eight seconds never has more than two
    // or three open at once, so it stays an order of magnitude under the limit while
    // doing precisely the thing worth noticing. And a peer going silent is an absence,
    // which nothing in a request-driven server is ever called to observe.
    private struct PeerRecord {
        var sessionStartedAt: Date
        var lastAcceptedAt: Date
        var connectionsThisSession: Int
        // Accept times inside the churn window, oldest first.
        var recentAccepts: [Date]
        // Highest number of connections seen inside one window this session.
        var peakChurnThisSession: Int
        var lastChurnLogAt: Date?
    }

    private var peerRecords: [String: PeerRecord] = [:]

    private static let churnWindow: TimeInterval = 10

    // Deliberately NOT set to a level that catches the browsing burst.
    //
    // The first draft of this put the threshold just under the rate observed before
    // the freeze, on the assumption that the burst was itself the anomaly. Replaying
    // three days of traffic disproved that: the peak preceding the freeze was twelve
    // connections in ten seconds, and ordinary untroubled browsing on the other
    // player peaked at thirteen. No threshold separates them, because the burst is
    // simply what browsing a large folder looks like — so a threshold placed there
    // would have fired constantly during healthy use and still not have been the
    // thing that identified the fault.
    //
    // What it is set to instead is an outlier tripwire: a rate that nothing observed
    // in normal use comes close to, worth a line purely because it would mean
    // something genuinely new. The burst itself is reported where it is actually
    // useful — as context on the session summary below, which costs no extra lines.
    private static let churnThreshold = 30
    private static let churnLogInterval: TimeInterval = 30

    // A gap this long from a peer that had been busy ends its session. Chosen to sit
    // above the pauses ordinary browsing produces and below the time a player takes
    // to reboot and come back.
    private static let peerSilenceThreshold: TimeInterval = 45
    // Sessions shorter than this were not a burst and their gaps are not interesting.
    private static let peerSessionMinimumConnections = 6
    // Ceiling on the table. A home LAN has a handful of peers; this only bounds the
    // pathological case of something walking the address space.
    private static let maxTrackedPeers = 64

    // Server header value, also used as the SSDP SERVER token so both agree.
    nonisolated static let serverToken: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        // The UPnP/1.0 token in the middle is required by the spec's SERVER header
        // grammar and is parsed by some clients to decide which quirks to apply.
        return "macOS/15.0 UPnP/1.0 LANStream/\(version)"
    }()

    init(contentIndex: ContentIndex,
         onActiveStreamCountChanged: @escaping @Sendable (Int, UInt64) -> Void) {
        self.contentIndex = contentIndex
        self.onActiveStreamCountChanged = onActiveStreamCountChanged
    }

    var port: UInt16? { boundPort }

    // MARK: - Lifecycle
    func start(port requestedPort: UInt16) async throws {
        stop()

        let parameters = NWParameters.tcp
        // Allow an immediate rebind after a restart instead of waiting out the
        // kernel's TIME_WAIT window — without this, quitting and relaunching the
        // app within a few seconds fails to bind, which would read as a bug.
        parameters.allowLocalEndpointReuse = true
        // The server speaks IPv4 only. The Oppo's DLNA client is IPv4, and every
        // URL advertised over SSDP is an IPv4 literal, so accepting IPv6 here would
        // only create a path whose responses reference an address the client never
        // asked about.
        if let ipOptions = parameters.defaultProtocolStack
            .internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        // Disable Nagle's algorithm. Nagle withholds a sub-MSS segment until every
        // previously sent byte has been acknowledged, which is the right trade for
        // an interactive terminal and the wrong one for an HTTP server. A player
        // that probes a container's header with hundreds of small range requests
        // has nothing to send back between them, so it holds each acknowledgment
        // for its delayed-ACK interval — 40 ms on the Oppo — and every one of those
        // requests pays that toll before its body is allowed onto the wire.
        if let tcpOptions = parameters.defaultProtocolStack
            .transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            // Detect a peer that disappears without closing — a player powered off
            // or dropped off Wi-Fi mid-session. Such a socket is indistinguishable
            // from an idle one at the application layer, and on a keep-alive
            // connection between range requests nothing would notice it for the full
            // five-minute idle timeout, holding both a connection slot and an open
            // file descriptor.
            //
            // Deliberately does NOT affect paused playback. A client that pauses
            // stops reading, its receive window closes, and TCP enters persist mode
            // where keepalives are not sent — so a paused film is not at risk from
            // these values, which is the property that matters most here.
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 60
            tcpOptions.keepaliveInterval = 15
            tcpOptions.keepaliveCount = 4
        }

        guard let endpointPort = NWEndpoint.Port(rawValue: requestedPort) else {
            throw StartError.failed("Invalid port \(requestedPort)")
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: endpointPort)
        } catch {
            // POSIXErrorCode.EADDRINUSE surfaces here when another DLNA server (or a
            // stale copy of this one) already holds the port.
            if let nwError = error as? NWError,
               case .posix(let code) = nwError, code == .EADDRINUSE {
                throw StartError.portInUse(requestedPort)
            }
            throw StartError.failed(error.localizedDescription)
        }

        self.listener = listener

        // Bridge the listener's callback-based startup into async/await so callers
        // learn about a bind failure at the call site rather than out of band.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The continuation must be resumed exactly once; the listener can report
            // .ready and later .failed, so this flag gates the first transition only.
            let resumeState = ResumeGuard()

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    // On the startup path start() records readiness itself, in-line
                    // after the await, so the bound port is known before it returns.
                    // This hop covers only a .ready that arrives after startup settled.
                    if resumeState.tryResume() {
                        continuation.resume()
                    } else {
                        Task { await self?.handleListenerReady() }
                    }
                case .failed(let error):
                    if resumeState.tryResume() {
                        if case .posix(let code) = error, code == .EADDRINUSE {
                            continuation.resume(throwing: StartError.portInUse(requestedPort))
                        } else {
                            continuation.resume(throwing: StartError.failed(
                                error.localizedDescription))
                        }
                    } else {
                        Task { await self?.handleListenerFailure(error) }
                    }
                case .waiting(let error):
                    // .waiting means the listener cannot bind yet but Network
                    // intends to retry — typically no usable interface at login,
                    // before the network comes up. It is NOT resumed here: doing so
                    // would report a permanent failure for a condition that usually
                    // clears on its own within seconds, and the path monitor in
                    // DLNAServer restarts the server if it does not. The startup
                    // timeout below is what prevents this from hanging forever.
                    Self.log("Listener waiting to bind port \(requestedPort): \(error.localizedDescription)")
                case .cancelled:
                    if resumeState.tryResume() {
                        continuation.resume(throwing: StartError.failed(
                            "Listener was canceled during startup"))
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }

            listener.start(queue: queue)

            // Backstop against a listener that reaches neither .ready nor .failed —
            // the .waiting case above deliberately does not resume, so without this
            // the await would never return and the menu bar would sit on "Starting…"
            // indefinitely with no explanation.
            let queue = self.queue
            queue.asyncAfter(deadline: .now() + Self.startTimeoutSeconds) {
                if resumeState.tryResume() {
                    continuation.resume(throwing: StartError.failed(
                        "Timed out binding port \(requestedPort)"))
                }
            }
        }

        // Recorded here, synchronously, rather than only from a hop scheduled by the
        // state handler. That hop and this method's own resumption are two separate
        // enqueues onto this actor with no ordering between them, so the caller —
        // which reads `port` the moment this returns to decide what to advertise —
        // could find it still nil and fall back to the PREFERRED port. On the
        // fallback ladder that is exactly the port some other process holds, so
        // discovery would announce an address this server is not listening on.
        handleListenerReady(fallbackPort: requestedPort)
    }

    // Upper bound on how long start() waits for the listener to become ready.
    private static let startTimeoutSeconds: TimeInterval = 10.0

    private func handleListenerReady(fallbackPort: UInt16? = nil) {
        guard let listener else { return }
        boundPort = listener.port?.rawValue ?? fallbackPort
        isListenerReadyFlag = true
        Self.log("Listening on TCP port \(boundPort.map(String.init) ?? "?").")
    }

    // Whether the listener is currently bound and accepting. Deliberately reports
    // the observed state rather than inferring it from 'listener != nil': a
    // listener object outlives its usable socket in exactly the failure this is
    // asked about.
    func isListenerReady() -> Bool {
        listener != nil && isListenerReadyFlag
    }

    // Connection-table size, for the health watchdog's periodic report.
    var connectionCount: Int { connections.count }

    // A listener that fails AFTER a successful start was previously only logged.
    // Nothing recovered from it: isRunning stays true, so DLNAServer's path monitor
    // (which only restarts a server it believes is down) never intervenes, and the
    // app sits with a dead HTTP listener while SSDP keeps announcing an address that
    // no longer answers — the same "healthy from the inside, invisible from the
    // outside" shape as the LOCATION bug. The owner is told so it can rebuild.
    private func handleListenerFailure(_ error: NWError) {
        Self.log("ERROR: HTTP listener failed after startup on port "
                 + "\(boundPort.map(String.init) ?? "?"): \(error.localizedDescription) "
                 + "(\(NetworkDescription.describe(error))). \(connections.count) connection(s) were open. "
                 + "Asking the server coordinator to rebuild the listener.")
        isListenerReadyFlag = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
        onListenerFailure?()
    }

    // Set by DLNAServer after start(). Optional because HTTPServer is constructed
    // before its owner is ready to receive callbacks.
    private var onListenerFailure: (@Sendable () -> Void)?

    func setListenerFailureHandler(_ handler: @escaping @Sendable () -> Void) {
        onListenerFailure = handler
    }

    func stop() {
        for connection in connections.values {
            Task { await connection.close() }
        }
        connections.removeAll()
        lastStreamReport.removeAll()
        // Peer history describes a listener that no longer exists; keeping it would
        // report a spurious silence gap against the next one.
        peerRecords.removeAll()
        if !streams.isEmpty {
            streams.removeAll()
            publishStreamCount()
        }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
        isListenerReadyFlag = false
    }

    // MARK: - Connection acceptance
    private func accept(_ nwConnection: NWConnection) {
        guard connections.count < Self.maxConnections else {
            rejectedConnectionCount += 1
            // Throttled to one line every 30 seconds, but the first rejection after
            // a quiet period always prints, so the condition can never occur without
            // appearing in the log.
            let now = Date()
            if lastRejectionLogAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
                lastRejectionLogAt = now
                Self.log("ERROR: Refusing connection from "
                    + "\(NetworkDescription.describe(endpoint: nwConnection.endpoint)) — the connection "
                    + "limit of \(Self.maxConnections) is already reached "
                    + "(\(rejectedConnectionCount) refusal(s) so far). Existing peers: "
                    + "\(peerSummary()). This means a client is opening connections "
                    + "faster than it closes them, or something is scanning the port.")
            }
            nwConnection.cancel()
            return
        }
        noteAccept(from: nwConnection.endpoint)

        let id = UUID()
        let connection = HTTPConnection(
            id: id,
            connection: nwConnection,
            contentIndex: contentIndex,
            queue: queue,
            // The listener's own port first: a connection can be accepted in the
            // instant between the listener going ready and start() recording it.
            boundPort: boundPort ?? listener?.port?.rawValue
                ?? UInt16(Preferences.serverPort),
            onFinish: { [weak self] finishedID in
                Task { await self?.removeConnection(finishedID) }
            },
            onStreamChange: { [weak self] streamID, sequence, stream in
                Task { await self?.setStream(stream, for: streamID, sequence: sequence) }
            })
        connections[id] = connection
        Task { await connection.start() }
    }

    // Records one accepted connection against its peer and emits a line when the
    // peer's behavior crosses one of the two thresholds above. Called on every
    // accept, so it does no allocation beyond the peer's own small record.
    private func noteAccept(from endpoint: NWEndpoint?) {
        let peer = NetworkDescription.hostOnly(NetworkDescription.describe(endpoint: endpoint))
        let now = Date()

        guard var record = peerRecords[peer] else {
            if peerRecords.count >= Self.maxTrackedPeers { prunePeerRecords(before: now) }
            peerRecords[peer] = PeerRecord(sessionStartedAt: now,
                                           lastAcceptedAt: now,
                                           connectionsThisSession: 1,
                                           recentAccepts: [now],
                                           peakChurnThisSession: 1,
                                           lastChurnLogAt: nil)
            return
        }

        // A gap ends the previous session. Reported when that session was a real
        // burst, because "this client was working hard and then said nothing for
        // seventy-six seconds" is the signature of a client that died rather than
        // one that finished — and it is the line whose absence made the freeze so
        // laborious to reconstruct.
        let silence = now.timeIntervalSince(record.lastAcceptedAt)
        if silence >= Self.peerSilenceThreshold {
            if record.connectionsThisSession >= Self.peerSessionMinimumConnections {
                let span = record.lastAcceptedAt.timeIntervalSince(record.sessionStartedAt)
                Self.log("PEER SESSION ENDED: \(peer) went silent for "
                    + silence.fixed(0)
                    + "s and is connecting again now. The session before the gap ran "
                    + "\(record.connectionsThisSession) connection(s) over "
                    + span.fixed(0)
                    + "s, peaking at \(record.peakChurnThisSession) connection(s) per "
                    + "\(Int(Self.churnWindow))s. This line is a bookmark, not a "
                    + "fault: a client that pauses browsing produces it just as a "
                    + "client that crashed and rebooted does. What it gives is the "
                    + "exact boundary of the gap and the shape of the activity that "
                    + "ran into it, so the requests immediately above are known to be "
                    + "the last ones that peer handled before it stopped.")
            }
            record.sessionStartedAt = now
            record.connectionsThisSession = 0
            record.peakChurnThisSession = 0
            record.recentAccepts.removeAll(keepingCapacity: true)
        }

        record.lastAcceptedAt = now
        record.connectionsThisSession += 1
        record.recentAccepts.append(now)
        let windowStart = now.addingTimeInterval(-Self.churnWindow)
        record.recentAccepts.removeAll { $0 < windowStart }
        record.peakChurnThisSession = max(record.peakChurnThisSession,
                                          record.recentAccepts.count)

        if record.recentAccepts.count >= Self.churnThreshold {
            let quiet = record.lastChurnLogAt
                .map { now.timeIntervalSince($0) >= Self.churnLogInterval } ?? true
            if quiet {
                record.lastChurnLogAt = now
                Self.log("PEER CHURN: \(peer) has opened \(record.recentAccepts.count) "
                    + "connection(s) in the last \(Int(Self.churnWindow))s, which is "
                    + "well beyond anything ordinary browsing produces (measured peak "
                    + "on this network: thirteen). Currently \(connections.count) "
                    + "connection(s) open in total. Nothing has been refused — the "
                    + "connection limit is \(Self.maxConnections) — but a client "
                    + "opening sockets at this rate is either malfunctioning or is "
                    + "not a media player.")
            }
        }

        peerRecords[peer] = record
    }

    // Drops peers that have been silent far longer than a session gap. Only runs
    // when the table is full, which on any ordinary network is never.
    private func prunePeerRecords(before now: Date) {
        let cutoff = now.addingTimeInterval(-Self.peerSilenceThreshold * 4)
        peerRecords = peerRecords.filter { $0.value.lastAcceptedAt >= cutoff }
    }

    private func removeConnection(_ id: UUID) {
        connections.removeValue(forKey: id)
        lastStreamReport.removeValue(forKey: id)
        // A connection that dies mid-transfer must not leave a phantom stream
        // behind, or the quit prompt would keep warning about a film nobody is
        // watching and the menu bar would stay lit.
        if streams.removeValue(forKey: id) != nil { publishStreamCount() }
    }

    // MARK: - Stream registry
    // Highest report sequence applied per connection.
    //
    // Each report reaches this actor through its own unstructured Task, and those
    // carry no ordering between them. A short transfer — one of the bare header
    // probes a player fires while browsing, reset by the client after its first
    // chunk — reports its start and its end within milliseconds, and the end could
    // be applied first. The start then registered a stream nothing would ever
    // clear: the menu bar stuck on "serving" and the quit prompt warning about a
    // film nobody was watching, until the app was restarted.
    private var lastStreamReport: [UUID: UInt64] = [:]

    private func setStream(_ stream: ActiveStream?, for id: UUID, sequence: UInt64) {
        // A report from a connection already removed (or dropped by stop()) is
        // stale by definition, however it was ordered.
        guard connections[id] != nil else { return }
        if let last = lastStreamReport[id], sequence <= last { return }
        lastStreamReport[id] = sequence

        let before = streams.count
        if let stream {
            streams[id] = stream
        } else {
            streams.removeValue(forKey: id)
        }
        if streams.count != before { publishStreamCount() }
    }

    private func publishStreamCount() {
        streamCountGeneration &+= 1
        onActiveStreamCountChanged(streams.count, streamCountGeneration)
    }

    var activeStreams: [ActiveStream] {
        streams.values.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Diagnostics helpers
    // Compact "peer × count" list, so a rejection line names WHO filled the table
    // rather than only reporting that it is full.
    private func peerSummary() -> String {
        var counts: [String: Int] = [:]
        for stream in streams.values { counts[stream.peer, default: 0] += 1 }
        let streaming = counts.isEmpty
            ? "none streaming"
            : counts.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: ", ")
        return "\(connections.count) open, \(streaming)"
    }

}

// MARK: - ResumeGuard
// One-shot flag protecting a CheckedContinuation from a double resume when
// Network.framework reports several terminal-ish states in quick succession.
//
// Internal rather than private, and deliberately shared: SSDPResponder needs the
// identical guard for the identical reason, and carried its own byte-for-byte copy
// under a second name until both were folded in here.
final class ResumeGuard: Sendable {
    private let hasResumed = Mutex(false)

    func tryResume() -> Bool {
        hasResumed.withLock { hasResumed in
            if hasResumed { return false }
            hasResumed = true
            return true
        }
    }
}

// MARK: - NetworkDescription
// Renders Network.framework values into text a log reader can act on months later.
//
// Both helpers previously existed as private copies inside HTTPServer,
// HTTPConnection and SSDPResponder — three copies of the endpoint formatter and two
// of the error classifier, differing only in a local variable name. They are pure
// functions of their argument with no actor state, so there was never anything for
// the isolation to protect; only the duplication was real.
enum NetworkDescription {

    // Turns an NWError into something identifiable in a log. localizedDescription
    // alone collapses distinct causes ("Operation timed out", "Network is down")
    // into prose with no code attached, which makes two different faults look the
    // same weeks later when the log is all that is left.
    static func describe(_ error: NWError) -> String {
        switch error {
        // Errno's description (the strerror text) rather than the enum's own:
        // POSIXErrorCode renders several codes as "POSIXErrorCode(rawValue: 49)",
        // which is exactly the opposite of what this function exists to provide.
        case .posix(let code):
            return "POSIX \(code.rawValue) \(Errno(rawValue: code.rawValue))"
        case .dns(let code):   return "DNS \(code)"
        case .tls(let code):   return "TLS \(code)"
        case .wifiAware(let code): return "Wi-Fi Aware \(code)"
        @unknown default:      return "unclassified NWError"
        }
    }

    // "host:port", with any "%en0" interface scope stripped — it is meaningful only
    // on this machine and noise in a line about a remote peer.
    //
    // Optional because the SSDP path reads a message's remoteEndpoint, which
    // genuinely can be absent. The callers that pass a non-optional endpoint are
    // unaffected by that arm.
    static func describe(endpoint: NWEndpoint?) -> String {
        guard let endpoint else { return "unknown" }
        guard case .hostPort(let host, let port) = endpoint else { return "\(endpoint)" }
        let hostText = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
        return "\(hostText):\(port.rawValue)"
    }

    // The host half of a string produced by describe(endpoint:), without its
    // ephemeral port. Split from the RIGHT: an address can itself contain colons,
    // and taking the first component instead returns an empty host for any of them.
    // The one rule every caller shares — a CALLBACK check, the per-peer table, and
    // the peer shown in a confirmation dialog previously each carried a copy.
    static func hostOnly(_ peer: String) -> String {
        guard let separator = peer.lastIndex(of: ":") else { return peer }
        return String(peer[peer.startIndex..<separator])
    }
}

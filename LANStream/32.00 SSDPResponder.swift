// MARK: - SSDPResponder.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// SSDP discovery: the UDP half of DLNA that makes the server visible at all.
//
// Three obligations, all of which must be met before a player will list the
// device:
//   1. Answer M-SEARCH queries with a UNICAST response to the sender, after a
//      random delay bounded by the query's MX value.
//   2. Announce ssdp:alive periodically so clients that missed the initial
//      announcement still find the device, and so caches do not expire.
//   3. Announce ssdp:byebye on shutdown so the device disappears immediately
//      rather than lingering as an unreachable entry for up to 30 minutes.
//
// Each obligation is discharged for all five advertised notification types: the
// root device, the UUID, the MediaServer device type, and both service types.
// Announcing fewer is a common shortcut that works with lenient clients and
// fails silently with strict ones.

import Foundation
import Network

actor SSDPResponder: Loggable {
    nonisolated static let logTag = "[SSDP]"

    // MARK: - Protocol constants
    private static let multicastHost = "239.255.255.250"
    private static let multicastPort: UInt16 = 1900

    // Advertised cache lifetime. 1800 seconds is the conventional value; alive
    // announcements are re-sent at half this interval so a single lost datagram
    // cannot let a client's cache expire.
    private static let cacheMaxAge = 1800

    // The announcement interval is user-configurable; see the discussion on
    // Preferences.announceIntervalSeconds for what it does and does not control.

    // Upper bound on the randomized M-SEARCH response delay, in milliseconds.
    // See the discussion at the call site for why this is capped far below MX.
    private static let maximumResponseDelayMilliseconds = 400
    private static var announceInterval: Duration {
        .seconds(Preferences.announceIntervalSeconds)
    }

    // MARK: - State
    private let queue = DispatchQueue(label: "app.LANStream.ssdp", qos: .utility)
    private var group: NWConnectionGroup?
    // Identifies the CURRENT multicast group, so callbacks belonging to a group
    // that has already been torn down can be recognized and ignored.
    //
    // Network.framework's handlers hop into this actor through an unstructured
    // Task, so a state change or a datagram observed just before a teardown can be
    // delivered after the replacement group is already running. Without this the
    // consequences were real, not cosmetic: an old group's .cancelled arrived after
    // the new one reported .ready and logged "SSDP group canceled" underneath a
    // healthy group, and an old group's .failed would have escalated a recovery
    // against a group that no longer existed.
    private var groupGeneration: UInt64 = 0
    private var announceTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    // Serializes outgoing M-SEARCH replies.
    //
    // handleDatagram suspends on the randomized response delay, so two searches
    // arriving close together — two players waking at once, or one player probing
    // several targets — interleave and each try to open a reply connection. Those
    // connections cannot both hold port 1900, and the loser's datagrams disappear
    // without an error, which is the same silent-loss failure that made the server
    // undiscoverable in the first place. Chaining the sends means at most one reply
    // connection exists at any moment.
    private var replyChain: Task<Void, Never>?

    // MARK: - Reachability diagnostics
    // A DLNA server that nobody can see produces no error of its own: the sends
    // succeed, the socket is bound, and the failure lives entirely in what does
    // NOT arrive. On a Mac running Little Snitch, or one where Local Network
    // access was never granted, that silence is the only symptom — so these
    // counters exist to turn it into an explicit, actionable log line rather than
    // leaving "it didn't show up" as the sole piece of evidence.
    private var receivedDatagramCount = 0
    // Datagrams that did NOT originate in this process.
    //
    // receivedDatagramCount alone cannot answer the question the diagnostics are
    // actually asking. This app is a prolific multicast sender — five ssdp:alive
    // NOTIFYs per announcement interval plus a heartbeat every five seconds — and
    // every one of those loops straight back through the group it was sent to. So
    // the total is dominated by this app talking to itself, and it stays reassuringly
    // nonzero on a machine where not one datagram from any other device is getting
    // in. A field trace made the size of the gap plain: 73,286 datagrams over 57
    // hours, arriving at a near-constant 0.354/s against 0.362/s predicted from this
    // app's own emissions alone — the network contributed nothing measurable, and
    // "inbound multicast is working" was reported the entire time.
    //
    // That is the exact shape of a Little Snitch rule or a VLAN that does not pass
    // multicast between clients: the TCC grant is fine, loopback is fine, and the
    // server is still deaf to every player on the LAN. Counting foreign traffic
    // separately is what lets the report tell those two situations apart.
    private var externalDatagramCount = 0
    private var receivedMSearchCount = 0
    private var answeredSearchCount = 0
    private var lastDatagramAt: Date?
    private var httpPort: UInt16 = UInt16(Preferences.defaultServerPort)
    private var bootID: Int = Int(Date().timeIntervalSince1970)

    // MARK: - Failure escalation
    // Called when discovery has broken in a way this actor cannot fix from the
    // inside. The HTTP side has had an equivalent since the listener-loss fix; the
    // UDP side had nothing, so a multicast group that died after startup was logged
    // once and then left alone — the app stayed "running", the menu bar stayed
    // green, and the device was simply gone from every player on the network with
    // no further trace in the log.
    private var onFailure: (@Sendable (String) -> Void)?
    // One escalation per start(). Recovery restarts this responder, which resets the
    // flag, so a genuinely persistent fault still re-escalates on the next cycle and
    // the owner's backoff decides how often that may happen. Without the flag a
    // failing group would call the owner on every datagram and every announcement.
    private var hasEscalated = false
    // Consecutive failed multicast sends. One failure is noise (a transient
    // ENOBUFS); a run of them means the socket is no longer usable even though the
    // group never reported a state change.
    private var consecutiveSendFailures = 0
    private static let sendFailureEscalationThreshold = 5

    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onFailure = handler
    }

    // MARK: - Local Network permission (TCC)
    // macOS offers no API to query the Local Network privacy grant: there is no
    // status accessor, no request call, and no notification when the user changes
    // it in System Settings. Everything here is inferred from what the kernel does
    // to our traffic.
    //
    // The first version of this watched for EHOSTUNREACH on sends, which is the
    // documented folklore. Testing an actual revocation showed that is not what
    // happens, and the real behavior is worth recording because it defeats the
    // obvious implementation:
    //
    //   1. At the instant the grant is withdrawn, the LIVE multicast group is torn
    //      out from under us and its in-flight sends fail with EPIPE (POSIX 32,
    //      "Broken pipe") — not EHOSTUNREACH.
    //   2. The socket is then rebuilt, joins the group without complaint, and every
    //      subsequent send completes with NO ERROR AT ALL. From the send path the
    //      server looks perfectly healthy forever.
    //   3. What actually stops is INBOUND. Not one datagram arrives — not other
    //      devices' NOTIFY chatter, not our own announcements looping back, not an
    //      M-SEARCH. That silence is the only durable symptom.
    //
    // So a successful send proves nothing and is not treated as evidence of access.
    // Only inbound traffic proves access, and a sustained absence of inbound traffic
    // is what condemns it. Nothing polls for this: the announcement loop's send
    // completions and the existing 20 s/300 s reachability report already run on
    // their own, and both now feed this verdict.
    enum LocalNetworkAccess: Sendable, Equatable {
        // No evidence either way yet — nothing has arrived and nothing has failed.
        case unknown
        // Inbound multicast is arriving, which cannot happen through a denied grant.
        case granted
        // Either the tear-out signature on sends, or a sustained inbound silence.
        case denied
    }

    private var localNetworkAccess: LocalNetworkAccess = .unknown
    private var blockedSendSignatureCount = 0
    // Thresholds differ by error code because the two signatures are not equally
    // trustworthy, and a single shared counter was quietly defeating the fast path
    // for the one case it was supposed to serve:
    //
    //   • EPIPE trips on the FIRST occurrence. Testing an actual revocation (see the
    //     note on isBlockedTrafficSignature) showed the tear-out is a one-shot event
    //     — Network.framework rebuilds and rejoins the group on its own, silently,
    //     before the next send. A live alive-burst is five datagrams sent back to
    //     back, but usually only the one in flight at the instant of revocation ever
    //     sees EPIPE; the rest already go out over the newly rejoined socket without
    //     error. A threshold of 2 here does not "confirm" anything — it just misses
    //     the one piece of evidence a genuine revocation actually produces, and
    //     detection silently falls back to the 20s/300s reachability report. EPIPE
    //     is also not a code routers or interfaces ordinarily raise on their own, so
    //     a false positive from requiring only one is not expected in practice — and
    //     if one ever slips through, it self-corrects within moments: any inbound
    //     datagram (including this app's own announcement looping back to itself)
    //     immediately flips the verdict back to granted.
    //   • EHOSTUNREACH keeps requiring two consecutive occurrences. This is the
    //     ordinary "no route yet" refusal a Mac can raise transiently while an
    //     interface is still settling — Wi-Fi association, DHCP, waking from sleep —
    //     none of which are a permission revocation, so one instance of it must not
    //     raise the warning.
    private static let blockedSendThresholdEPIPE = 1
    private static let blockedSendThresholdEHOSTUNREACH = 2

    private var onAccessChange: (@Sendable (LocalNetworkAccess) -> Void)?

    func setLocalNetworkAccessHandler(
        _ handler: @escaping @Sendable (LocalNetworkAccess) -> Void
    ) {
        onAccessChange = handler
        // The owner starts out assuming nothing; hand it whatever is known now so a
        // handler installed after the first announcement is not left stale.
        handler(localNetworkAccess)
    }

    // Recognizes the two errors that mean "the system took this socket away from
    // us", as opposed to ENOBUFS or EADDRNOTAVAIL, which are ordinary transient
    // conditions with entirely different fixes.
    //
    //   • EPIPE          — observed when the Local Network grant is revoked while
    //                      the app is running; the group is torn out mid-flight.
    //   • EHOSTUNREACH   — the classic "no route on a routable interface" refusal.
    private nonisolated static func isBlockedTrafficSignature(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return code == .EPIPE || code == .EHOSTUNREACH
    }

    // Inbound traffic is the ONLY positive proof. See the discussion above for why a
    // successful send is not: a denied app's sends keep succeeding indefinitely.
    private func noteInboundTrafficObserved() {
        blockedSendSignatureCount = 0
        updateAccess(.granted)
    }

    private func noteBlockedSend(_ error: NWError) {
        // The counter is shared rather than kept per-code deliberately: whichever
        // signature shows up, each occurrence is evidence toward the same verdict,
        // and a mix (e.g. EHOSTUNREACH while an interface settles, immediately
        // followed by an EPIPE) is exactly the kind of run that should not need to
        // start counting over. Only the threshold reached — which is decided by the
        // code that arrived just now — differs.
        blockedSendSignatureCount += 1
        let threshold: Int
        if case .posix(.EPIPE) = error {
            threshold = Self.blockedSendThresholdEPIPE
        } else {
            threshold = Self.blockedSendThresholdEHOSTUNREACH
        }
        guard blockedSendSignatureCount >= threshold else { return }
        updateAccess(.denied)
    }

    private func updateAccess(_ new: LocalNetworkAccess) {
        guard localNetworkAccess != new else { return }
        let previous = localNetworkAccess
        localNetworkAccess = new
        switch new {
        case .denied:
            Self.log("LAN TRAFFIC BLOCKED: SSDP discovery traffic is not reaching this "
                + "app. The likeliest cause by far is Local Network access being denied "
                + "in System Settings > Privacy & Security; a third-party firewall or a "
                + "network that does not pass multicast between clients produce the same "
                + "symptom. Nothing on the LAN can see this server until it is resolved. "
                + "This is now shown in the menu bar.")
        case .granted:
            if previous == .denied {
                Self.log("LAN traffic restored — SSDP datagrams are arriving again.")
            } else {
                Self.log("LAN traffic confirmed working — inbound SSDP datagrams are "
                    + "arriving.")
            }
        case .unknown:
            break
        }
        onAccessChange?(new)
    }

    private func escalate(_ reason: String) {
        guard !hasEscalated else {
            Self.log("Discovery fault persists (\(reason)) — recovery has already been "
                + "requested for this session; not requesting it again.")
            return
        }
        hasEscalated = true
        Self.log("SELF-HEAL TRIGGER (discovery): \(reason). Asking the server "
            + "coordinator to rebuild the discovery layer.")
        onFailure?(reason)
    }

    // MARK: - Heartbeat
    // Why this exists: every piece of evidence about the Local Network grant used to
    // arrive on someone else's schedule. The tear-out (EPIPE) is only visible on a
    // send, and the only thing sending was the announcement loop — a user-configurable
    // interval that is thirty seconds by default and can be fifteen minutes. So a
    // revocation was noticed somewhere between instantly and one whole interval later,
    // which is exactly the 15-30 s lag this was reported as, and why it felt "almost
    // instant" on a build where an announcement happened to land right after the
    // switch was flipped. The other witness — the reachability report — is worse: it
    // runs at 20 s and then every 300 s, and its inbound test is a count of datagrams
    // received SINCE STARTUP, which stops being zero forever after the first one, so
    // it can never detect a revocation that happens later in a session at all.
    //
    // The heartbeat replaces "whenever the announcement loop next happens to fire"
    // with a fixed five-second cadence that is independent of the user's setting. It
    // carries the same two kinds of evidence the announcement burst does, at 6x the
    // resolution of the default interval:
    //
    //   • Its send either fails with the tear-out signature (fast revocation
    //     detection) or does not.
    //   • Its datagram loops back to this app through the multicast group, which is
    //     positive proof that inbound works (fast restoration detection) — and a
    //     sustained absence of it is proof that inbound has stopped.
    //
    // It is deliberately not an announcement. ST is this device's own UUID, so no
    // other device on the network can match it and none will reply; the only machine
    // that sees anything is this one. It is also marked with a header so the
    // datagram is recognized on the way back in and dropped before the answering
    // path, rather than making this app answer itself every five seconds.
    static let heartbeatHeaderName = "X-LANStream-Heartbeat"
    private static let heartbeatInterval: Duration = .seconds(5)

    // How long a total inbound silence must last before it condemns the grant.
    // Three missed heartbeats rather than one: a single datagram lost to ordinary
    // multicast unreliability must not raise the warning.
    private static let heartbeatSilenceLimit: TimeInterval = 16

    // The silence rule is armed only after a heartbeat has actually been seen coming
    // back at least once. Multicast loopback is expected here and observed in
    // practice, but it is a property of the interface and the network stack, not a
    // guarantee this app can make — and on a machine where it does not happen, an
    // unconditional silence rule would report a blocked LAN on an idle but perfectly
    // healthy network. Self-calibrating this way means the rule can only ever fire
    // where its own premise has been demonstrated.
    private var heartbeatLoopbackObserved = false

    // When the heartbeat loop last actually ran, and the point from which silence is
    // measured after a gap in that loop.
    //
    // These exist because of a false alarm observed across a real sleep/wake cycle.
    // The silence rule condemns the Local Network grant after 16 s with no inbound
    // datagram — but a sleeping Mac produces no inbound datagrams for as long as it
    // sleeps, and the loop that measures the silence is suspended along with it. On
    // waking from a 285 s sleep the first evaluation therefore compared "now" against
    // a timestamp from before the sleep, found 279 s of silence, and announced LAN
    // TRAFFIC BLOCKED — in the same millisecond as the reachability report was saying
    // inbound multicast was working. It corrected itself 14 s later, but not before
    // putting a false warning in the menu bar and starting a recovery loop over a
    // condition that never existed.
    //
    // The loop now notices that far more wall-clock time passed than it asked to
    // sleep for, treats that as the process having been suspended rather than as
    // evidence about the network, and re-bases the silence window on the wake.
    private var lastHeartbeatTickAt: Date?
    private var silenceBaseline: Date?

    // Announces whether the silence rule is armed. The menu bar needs to know this,
    // not just the verdict: "the traffic witness says clear" is only a statement
    // about the last sixteen seconds while the rule that enforces that window is
    // running. Where it is not armed, the same verdict could be minutes old, and a
    // decision made on its freshness would be a guess.
    private var onTrafficWitnessLiveChange: (@Sendable (Bool) -> Void)?

    func setTrafficWitnessLiveHandler(
        _ handler: @escaping @Sendable (Bool) -> Void
    ) {
        onTrafficWitnessLiveChange = handler
        handler(heartbeatLoopbackObserved)
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        // A rebuilt group has not proven loopback yet, whatever the previous one did.
        if heartbeatLoopbackObserved { onTrafficWitnessLiveChange?(false) }
        heartbeatLoopbackObserved = false
        lastHeartbeatTickAt = nil
        silenceBaseline = Date()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runHeartbeatTick()
                do { try await Task.sleep(for: SSDPResponder.heartbeatInterval) }
                catch { return }
            }
        }
    }

    // One iteration: send, then judge the silence — unless the loop has just come
    // back from a suspension, in which case there is nothing to judge yet.
    private func runHeartbeatTick() {
        let wasSuspended = noteHeartbeatTick()
        sendHeartbeat()
        if !wasSuspended { evaluateHeartbeatSilence() }
    }

    // Records this tick and reports whether the gap since the previous one is too
    // large to have been an ordinary sleep. Three times the interval is comfortably
    // beyond any scheduling jitter and far below the shortest sleep a machine can
    // take, so it separates the two cases cleanly.
    private func noteHeartbeatTick() -> Bool {
        let now = Date()
        defer { lastHeartbeatTickAt = now }
        guard let previous = lastHeartbeatTickAt else { return false }

        let elapsed = now.timeIntervalSince(previous)
        let interval = Double(Self.heartbeatInterval.components.seconds)
        guard elapsed > interval * 3 else { return false }

        silenceBaseline = now
        Self.log("Discovery heartbeat resumed after a "
            + elapsed.fixed(0)
            + "s gap, which is far longer than its \(Int(interval))s interval — this "
            + "process was suspended (almost certainly system sleep) rather than the "
            + "network having gone quiet. The inbound-silence window restarts from now "
            + "instead of counting the suspension as evidence that the LAN is blocked.")
        return true
    }

    private func sendHeartbeat() {
        guard group != nil else { return }
        let message = """
        M-SEARCH * HTTP/1.1\r
        HOST: \(Self.multicastHost):\(Self.multicastPort)\r
        MAN: "ssdp:discover"\r
        MX: 1\r
        ST: uuid:\(Preferences.serverUUID)\r
        \(Self.heartbeatHeaderName): 1\r
        \r\n
        """
        sendMulticast(message)
    }

    // Not logged: this runs every five seconds for the life of the process, and a
    // line per evaluation would bury everything else in the file. The verdict change
    // it produces is logged by updateAccess, which is the part worth keeping.
    private func evaluateHeartbeatSilence() {
        guard group != nil, heartbeatLoopbackObserved else { return }
        guard let last = lastDatagramAt else { return }
        // Measured from the later of the last datagram and the most recent
        // re-baselining, so time this process spent suspended is never counted as
        // network silence. lastDatagramAt itself is left honest for the reachability
        // report, which wants the real answer to "how long since anything arrived".
        let reference = max(last, silenceBaseline ?? .distantPast)
        guard Date().timeIntervalSince(reference) >= Self.heartbeatSilenceLimit else { return }
        updateAccess(.denied)
    }

    // MARK: - Notification types
    // (NT value, USN suffix) pairs. The USN for the UUID entry is the bare UUID;
    // for all others it is "uuid:<id>::<type>".
    private var advertisedTypes: [(notificationType: String, uniqueServiceName: String)] {
        let uuid = "uuid:\(Preferences.serverUUID)"
        return [
            (UPnP.rootDeviceType,        "\(uuid)::\(UPnP.rootDeviceType)"),
            (uuid,                       uuid),
            (UPnP.mediaServerDeviceType, "\(uuid)::\(UPnP.mediaServerDeviceType)"),
            (UPnP.contentDirectoryType,  "\(uuid)::\(UPnP.contentDirectoryType)"),
            (UPnP.connectionManagerType, "\(uuid)::\(UPnP.connectionManagerType)")
        ]
    }

    // MARK: - Lifecycle
    enum StartError: Error, Sendable {
        case multicastUnavailable(String)

        var displayText: String {
            switch self {
            case .multicastUnavailable(let reason):
                return "Discovery unavailable: \(reason)"
            }
        }
    }

    func start(httpPort: UInt16) async throws {
        await stop()
        self.httpPort = httpPort
        // BootID must increase across restarts; clients use it to detect that a
        // device rebooted and that their cached description may be stale. Whole
        // seconds alone are not enough on their own here: the blocked-LAN recovery
        // loop rebuilds this responder as often as every five seconds, and two
        // rebuilds inside one second would re-announce with an unchanged BOOTID —
        // which tells a client nothing happened at the exact moment something did.
        // Taking the greater of the clock and the previous value keeps it strictly
        // increasing without letting it run away from wall time.
        self.bootID = max(bootID + 1, Int(Date().timeIntervalSince1970))
        receivedDatagramCount = 0
        externalDatagramCount = 0
        receivedMSearchCount = 0
        answeredSearchCount = 0
        lastDatagramAt = nil
        hasEscalated = false
        consecutiveSendFailures = 0
        // Not reset to .unknown: a restart is exactly when a revoked grant is most
        // likely to still be revoked, and blanking the state would make the menu bar
        // warning flicker away and back on every network change. The next send
        // result re-confirms it either way.
        blockedSendSignatureCount = 0

        guard let port = NWEndpoint.Port(rawValue: Self.multicastPort) else {
            throw StartError.multicastUnavailable("Invalid SSDP port")
        }

        let multicastEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(Self.multicastHost), port: port)

        let multicastGroup: NWMulticastGroup
        do {
            multicastGroup = try NWMulticastGroup(for: [multicastEndpoint])
        } catch {
            throw StartError.multicastUnavailable(error.localizedDescription)
        }

        let parameters = NWParameters.udp
        // Several DLNA servers commonly coexist on one machine during testing, and
        // the SSDP port is shared by every UPnP participant on the host by design.
        parameters.allowLocalEndpointReuse = true
        if let ipOptions = parameters.defaultProtocolStack
            .internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }

        let group = NWConnectionGroup(with: multicastGroup, using: parameters)
        self.group = group
        groupGeneration &+= 1
        let generation = groupGeneration

        group.setReceiveHandler(maximumMessageSize: 8192,
                                rejectOversizedMessages: true) { [weak self] message, content, _ in
            guard let content, !content.isEmpty else { return }
            Task { await self?.handleDatagram(content, message: message,
                                              generation: generation) }
        }

        group.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleGroupState(state, generation: generation) }
        }

        group.start(queue: queue)
    }

    // Asynchronous because the byebye datagrams must be confirmed sent BEFORE the
    // group is canceled. Queuing the sends and canceling in the same turn — the
    // obvious synchronous implementation — discards them: cancel() tears down the
    // socket while the writes are still pending, and the device then lingers in the
    // player's list as an unreachable entry until its cache expires half an hour
    // later. Awaiting each send is what makes "quit" actually remove the device.
    // 'sendingGoodbye' is false when the local address has already changed out from
    // under us. byebye must be sent from the address it is retracting, and once that
    // address is gone every datagram fails with EADDRNOTAVAIL — five useless errors
    // and a delay on a path where the immediately following alive burst already
    // tells clients everything they need.
    func stop(sendingGoodbye: Bool = true) async {
        // Any fault observed from here on is a consequence of this teardown, not a
        // reason to trigger another one.
        hasEscalated = true
        announceTask?.cancel()
        announceTask = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        replyChain?.cancel()
        replyChain = nil

        if group != nil && sendingGoodbye {
            await sendByebye()
        }

        // The state handler is deliberately NOT cleared here. Unlike NWListener,
        // which honors a post-start handler change, NWConnectionGroup refuses one
        // outright — it logs "failed to set state changed handler because group has
        // already been started" and keeps the original handler, so the assignment
        // was pure console noise that bought nothing. The proof is in this app's own
        // log: "Ignoring a canceled report from a superseded multicast group" can
        // only ever be printed by a handler that was supposedly cleared a moment
        // earlier. The generation guard in handleGroupState is what actually makes
        // a superseded group's callbacks harmless, and it does the job on its own.
        group?.cancel()
        group = nil
    }

    private func handleGroupState(_ state: NWConnectionGroup.State,
                                  generation: UInt64) {
        guard generation == groupGeneration else {
            Self.log("Ignoring a \(state) report from a superseded multicast group "
                + "(generation \(generation), current \(groupGeneration)).")
            return
        }
        switch state {
        case .ready:
            Self.log("Joined SSDP multicast group \(Self.multicastHost):\(Self.multicastPort).")
            startAnnounceLoop()
            startDiagnostics()
            startHeartbeat()
        case .failed(let error):
            // On macOS 15 the overwhelmingly likely cause is Local Network privacy:
            // the app has not been granted access, so multicast is dropped. Naming
            // that possibility here is worth far more than the raw error string,
            // because the fix is entirely outside the app.
            Self.log("ERROR: SSDP multicast group failed: \(error.localizedDescription) "
                + "(\(NetworkDescription.describe(error))) after \(receivedDatagramCount) datagram(s) "
                + "received and \(answeredSearchCount) search(es) answered. The device is "
                + "no longer discoverable. If this persists, check System Settings › "
                + "Privacy & Security › Local Network and confirm LAN Stream is enabled.")
            if Self.isBlockedTrafficSignature(error) {
                // Same reasoning as on the send path: recovery cannot fix TCC.
                updateAccess(.denied)
            } else {
                escalate("multicast group entered .failed (\(NetworkDescription.describe(error)))")
            }
        case .waiting(let error):
            // Not a failure yet: Network.framework intends to retry. It is logged
            // because a group that waits forever looks identical, from every other
            // vantage point in the app, to one that is working.
            Self.log("WARNING: SSDP multicast group is waiting to become ready: "
                + "\(error.localizedDescription) (\(NetworkDescription.describe(error))). Discovery is "
                + "not functioning until this clears.")
            // .waiting(EHOSTUNREACH) is how a denied grant usually presents at
            // startup: Network.framework intends to retry forever, and every retry
            // will be refused for the same reason.
            if Self.isBlockedTrafficSignature(error) { updateAccess(.denied) }
        case .cancelled:
            Self.log("SSDP group canceled.")
        case .setup:
            break
        @unknown default:
            Self.log("SSDP group reported an unrecognized state: \(state).")
        }
    }

    // MARK: - Diagnostics reporting
    private func startDiagnostics() {
        diagnosticsTask?.cancel()
        let generation = groupGeneration
        diagnosticsTask = Task { [weak self] in
            // 'try?' on these sleeps was a trap. Cancellation makes the sleep throw,
            // 'try?' swallows it, and execution falls straight into the report — so
            // tearing the responder down during a recovery fired the initial verdict
            // immediately, against counters the restart had just reset to zero. The
            // log then carried a full DISCOVERY WARNING ("no datagrams received since
            // startup") about a responder that had been working perfectly a second
            // earlier, which is precisely the kind of false alarm that makes a log
            // useless. Cancellation now ends the task, as it always should have.
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            await self?.reportReachability(initial: true, generation: generation)

            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                await self?.reportReachability(initial: false, generation: generation)
            }
        }
    }

    private func reportReachability(initial: Bool, generation: UInt64) async {
        guard group != nil else { return }
        // Belt and braces alongside the cancellation check above: a report must
        // describe the group whose statistics it is reading.
        guard generation == groupGeneration else { return }

        if receivedDatagramCount == 0 {
            // Total inbound silence is the durable signature of a blocked LAN, and
            // on this path it is authoritative rather than merely suggestive: by the
            // time this runs the app has been in the multicast group for at least
            // twenty seconds and has sent at least three announcement bursts, every
            // one of which loops back to ourselves on a working network. Zero of
            // everything cannot happen while traffic is flowing.
            updateAccess(.denied)
            // The one failure mode worth spelling out in full, because the fix is
            // entirely outside the app and undiscoverable from inside it. Built by
            // concatenation rather than as a multi-line literal so it lands in the
            // log as a single grep-able line instead of a block of ragged
            // continuation whitespace.
            Self.log("DISCOVERY WARNING: no SSDP datagrams of any kind have been received since "
                + "startup, although announcements are being sent successfully. Outbound multicast "
                + "appears to work while inbound does not, which means something is filtering it. "
                + "Check, in order: (1) System Settings > Privacy & Security > Local Network — "
                + "LAN Stream must be enabled; (2) a third-party firewall such as Little Snitch — "
                + "inbound UDP to port 1900 and membership of 239.255.255.250 must be permitted; "
                + "(3) the network itself — some Wi-Fi networks and VLAN setups block multicast "
                + "between clients. Players may still find this server from its periodic "
                + "announcements, but they will not be able to search for it.")
            return
        }

        let sinceLast = lastDatagramAt.map {
            Date().timeIntervalSince($0).fixed(0) + "s ago"
        } ?? "never"

        let verdict: String
        var line: String

        if externalDatagramCount == 0 {
            // The failure this app spent a long time unable to describe. Everything
            // the old report measured was nonzero and everything it said was
            // reassuring, because the traffic it was counting was this app's own
            // announcements looping back. Not one datagram from any other device on
            // the network had arrived, which is a different fault from a denied TCC
            // grant and has a different fix.
            verdict = "DISCOVERY BLINDED"
            line = "\(verdict): \(receivedDatagramCount) datagram(s) received (last "
                + "\(sinceLast)), but every one of them was this app's own traffic "
                + "looping back — nothing from any other device on the network has "
                + "arrived. Local Network access is working (loopback proves it) and "
                + "outbound announcements are being sent, so players can still find "
                + "this server from its periodic ssdp:alive, but it is deaf to "
                + "M-SEARCH and will therefore take up to one full announcement "
                + "interval to appear rather than answering instantly. Check, in "
                + "order: (1) a third-party firewall such as Little Snitch — inbound "
                + "UDP to port 1900 and membership of 239.255.255.250 must be "
                + "permitted; (2) the network itself — some Wi-Fi networks and VLAN "
                + "setups do not pass multicast between clients."
        } else if receivedMSearchCount == 0 {
            // Traffic from other devices IS arriving, so the inbound path is
            // genuinely open and the absence of searches really is just an absence
            // of searches.
            verdict = "DISCOVERY NOTE"
            line = "\(verdict): inbound multicast is working "
                + "(\(externalDatagramCount) datagram(s) from other devices, "
                + "\(receivedDatagramCount) in total, last \(sinceLast)), but no "
                + "M-SEARCH has arrived yet. That is normal if no player has looked "
                + "for a media server since this app started."
        } else {
            verdict = initial ? "DISCOVERY OK" : "Discovery health"
            line = "\(verdict): \(receivedDatagramCount) datagram(s) received "
                + "(\(externalDatagramCount) from other devices, last \(sinceLast)), "
                + "\(receivedMSearchCount) M-SEARCH(es), \(answeredSearchCount) answered."
        }

        // Counts alone are not health. Throughout the outage that motivated this,
        // every number on this line looked perfect while the server was advertising
        // an address no client could reach. So the periodic report re-verifies the
        // advertisement itself; the awaits below suspend rather than block, so
        // inbound datagrams continue to be handled while the check runs.
        //
        // Skipped on the initial report because the startup self-check has just
        // covered the same ground and there is no value in saying it twice.
        var brokenReason: String?
        if !initial {
            if let location = locationURL() {
                let outcome = await SelfCheck.verifyDescription(at: location,
                                                                udn: Preferences.serverUUID)
                if outcome.isPass {
                    line += " Advertised \(location) — verified reachable."
                } else {
                    line += " ADVERTISEMENT BROKEN: \(outcome.detail)"
                    brokenReason = "periodic health check could not reach the advertised "
                        + "description at \(location): \(outcome.detail)"
                }
            } else {
                line += " ADVERTISEMENT BROKEN: this machine currently has no address "
                    + "usable in an advertisement, so nothing can find this server."
                brokenReason = "periodic health check found no advertisable local IPv4 "
                    + "address"
            }
        }

        Self.log(line)
        if let brokenReason { escalate(brokenReason) }
    }

    // Applies a changed announcement interval immediately.
    //
    // Re-reading the preference at the top of each loop iteration would be simpler
    // but would not take effect until the CURRENT sleep elapsed — so lowering the
    // interval from fifteen minutes to ten seconds would still leave the user
    // waiting fifteen minutes to see the change work, which is exactly the
    // frustration the setting exists to relieve.
    func announcementIntervalChanged() {
        guard group != nil else { return }
        Self.log("Announcement interval changed to \(Preferences.announceIntervalSeconds)s — restarting announcements.")
        startAnnounceLoop()
    }

    private func startAnnounceLoop() {
        announceTask?.cancel()
        announceTask = Task { [weak self] in
            guard let self else { return }

            // The UPnP architecture requires the initial announcement to be sent
            // more than once, because UDP multicast is lossy and a single dropped
            // datagram would leave the device invisible until the next interval.
            for attempt in 0..<3 {
                if Task.isCancelled { return }
                await self.sendAlive()
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: SSDPResponder.announceInterval)
                } catch {
                    return
                }
                await self.sendAlive()
            }
        }
    }

    private func sendAlive() {
        guard let location = locationURL() else {
            Self.log("Skipping ssdp:alive — no usable local IPv4 address.")
            return
        }

        for advertised in advertisedTypes {
            let message = """
            NOTIFY * HTTP/1.1\r
            HOST: \(Self.multicastHost):\(Self.multicastPort)\r
            CACHE-CONTROL: max-age=\(Self.cacheMaxAge)\r
            LOCATION: \(location)\r
            NT: \(advertised.notificationType)\r
            NTS: ssdp:alive\r
            SERVER: \(HTTPServer.serverToken)\r
            USN: \(advertised.uniqueServiceName)\r
            BOOTID.UPNP.ORG: \(bootID)\r
            CONFIGID.UPNP.ORG: 1\r
            \r\n
            """
            sendMulticast(message)
        }
        Self.log("Sent ssdp:alive for \(advertisedTypes.count) notification types (LOCATION \(location)).")
    }

    private func sendByebye() async {
        for advertised in advertisedTypes {
            let message = """
            NOTIFY * HTTP/1.1\r
            HOST: \(Self.multicastHost):\(Self.multicastPort)\r
            NT: \(advertised.notificationType)\r
            NTS: ssdp:byebye\r
            USN: \(advertised.uniqueServiceName)\r
            BOOTID.UPNP.ORG: \(bootID)\r
            CONFIGID.UPNP.ORG: 1\r
            \r\n
            """
            await sendMulticastAwaiting(message)
        }
        Self.log("Sent ssdp:byebye for \(advertisedTypes.count) notification types.")
    }

    // Awaitable multicast send, used on the shutdown path where the caller must
    // know the datagram has actually been handed to the transport before tearing
    // the group down.
    private func sendMulticastAwaiting(_ message: String) async {
        guard let group else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.send(content: Data(message.utf8)) { error in
                if let error {
                    Self.log("WARNING: byebye send failed: \(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
    }

    // Appends a reply to the serial chain. Deliberately does not await the send:
    // holding the actor for the duration would block incoming datagrams, and the
    // ordering guarantee comes from the chain rather than from the caller waiting.
    private func enqueueReply(_ payloads: [Data], to endpoint: NWEndpoint) {
        let previous = replyChain
        replyChain = Task { [weak self] in
            await previous?.value
            await self?.sendUnicastReplies(payloads, to: endpoint)
        }
    }

    // MARK: - Unicast M-SEARCH reply
    // Replies go out through a dedicated UDP socket bound to port 1900, NOT through
    // the multicast connection group.
    //
    // The group's send(content:to:) accepts an arbitrary peer endpoint and reports
    // no error, but the datagram never arrives: a multicast NWConnectionGroup will
    // not deliver a unicast reply to a non-member address. That silent discard is
    // the worst failure this protocol can have — the log says "Answered", every
    // counter looks healthy, and the device is invisible to anything that discovers
    // by searching. It was only caught by listening for the reply from outside the
    // app and finding nothing there.
    //
    // Every datagram for one search goes over ONE connection. This is not a tidiness
    // preference: connections cannot share the bind on port 1900, so a second one
    // opened while the first is alive loses its datagram without reporting an error.
    // An "ssdp:all" search needs ten datagrams (five USNs, each sent twice) and a
    // connection-per-datagram delivered six of them.
    //
    // The source port matters as well. SSDP responses are expected to originate from
    // 1900, and control points that check will drop a reply from an ephemeral port,
    // so the socket is explicitly bound there (with reuse, since the group already
    // holds it). If that bind is refused the send still proceeds from whatever port
    // the system assigns: a reply that might be filtered beats no reply at all.
    private nonisolated func sendUnicastReplies(_ payloads: [Data],
                                                to endpoint: NWEndpoint) async {
        guard !payloads.isEmpty else { return }

        func replyParameters(bindingSourcePort: Bool) -> NWParameters {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            if let ipOptions = parameters.defaultProtocolStack
                .internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }
            if bindingSourcePort, let sourcePort = NWEndpoint.Port(rawValue: Self.multicastPort) {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: sourcePort)
            }
            return parameters
        }

        var connection = NWConnection(to: endpoint,
                                      using: replyParameters(bindingSourcePort: true))
        if await !Self.waitUntilReady(connection) {
            connection.cancel()
            // The fallback the note above promises: from an ephemeral port rather than
            // not at all.
            Self.log("WARNING: could not open a reply channel to \(endpoint) from port "
                + "\(Self.multicastPort); replying from an ephemeral port instead.")
            connection = NWConnection(to: endpoint,
                                      using: replyParameters(bindingSourcePort: false))
            guard await Self.waitUntilReady(connection) else {
                connection.cancel()
                Self.log("WARNING: could not open reply channel to \(endpoint).")
                return
            }
        }
        defer { connection.cancel() }

        for payload in payloads {
            // Each response is sent twice. UDP does not retransmit, and a lost reply
            // means the device silently fails to appear; control points key on USN
            // and discard the duplicate.
            for _ in 0..<2 {
                if let error = await Self.send(payload, over: connection) {
                    Self.log("WARNING: M-SEARCH reply to \(endpoint) failed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    private nonisolated static func waitUntilReady(_ connection: NWConnection) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let guardState = ResumeGuard()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guardState.tryResume() { continuation.resume(returning: true) }
                // .waiting counts as failure. For UDP it means there is no usable path
                // to the searcher right now, and Network.framework would sit in it
                // indefinitely — and because replies are chained, one reply that never
                // resolved here would silently hold back every later one until the
                // responder was torn down.
                case .waiting, .failed, .cancelled:
                    if guardState.tryResume() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }

    private nonisolated static func send(_ data: Data,
                                         over connection: NWConnection) async -> NWError? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NWError?, Never>) in
            connection.send(content: data,
                            completion: .contentProcessed { continuation.resume(returning: $0) })
        }
    }

    private func sendMulticast(_ message: String) {
        guard let group else {
            Self.log("WARNING: Dropping an outbound SSDP datagram — the multicast group "
                + "is not open. Discovery is down.")
            return
        }
        // The first line of the datagram identifies which announcement failed, so a
        // partial failure (say, only byebye going missing) is distinguishable from a
        // socket that stopped working outright.
        let summary = message.split(separator: "\r\n").prefix(1).joined()
        group.send(content: Data(message.utf8),
                   completion: multicastCompletion(summary: summary,
                                                   generation: groupGeneration))
    }

    // Built in a nonisolated context so the closure is plainly Sendable rather than
    // inheriting this actor's isolation, which the concurrency checker refuses to
    // hand to Network.framework.
    private nonisolated func multicastCompletion(
        summary: String,
        generation: UInt64
    ) -> @Sendable (NWError?) -> Void {
        { [weak self] error in
            Task {
                await self?.noteMulticastSendResult(error, summary: summary,
                                                    generation: generation)
            }
        }
    }

    private func noteMulticastSendResult(_ error: NWError?, summary: String,
                                         generation: UInt64) {
        // A send completing against a group that has been replaced says nothing
        // about the health of the one now running.
        guard generation == groupGeneration else { return }
        guard let error else {
            if consecutiveSendFailures > 0 {
                Self.log("Multicast sending recovered after \(consecutiveSendFailures) "
                    + "consecutive failure(s).")
            }
            consecutiveSendFailures = 0
            // Deliberately does NOT mark access as granted. A denied app's multicast
            // sends succeed forever; treating that as proof was the bug that made
            // this whole mechanism report "confirmed working" while the server was
            // invisible to the entire network.
            return
        }
        consecutiveSendFailures += 1
        Self.log("WARNING: Multicast send failed (\(summary)): "
            + "\(error.localizedDescription) (\(NetworkDescription.describe(error))). "
            + "\(consecutiveSendFailures) consecutive failure(s).")

        // A denied Local Network grant is not a fault this app can repair, so it
        // must not drive the self-heal machinery. Rebuilding the server would fail
        // in precisely the same way, and the backoff would then spend the rest of
        // the session tearing down and rebuilding a server whose only real problem
        // is a switch in System Settings. It is reported to the user instead.
        if Self.isBlockedTrafficSignature(error) {
            noteBlockedSend(error)
            return
        }

        if consecutiveSendFailures >= Self.sendFailureEscalationThreshold {
            escalate("\(consecutiveSendFailures) consecutive multicast send failures, "
                + "last was \(NetworkDescription.describe(error))")
        }
    }

    // MARK: - M-SEARCH handling
    private func handleDatagram(_ data: Data, message: NWConnectionGroup.Message,
                                generation: UInt64) async {
        // A datagram delivered from a group that has since been replaced would
        // otherwise be counted against the new group's statistics and answered with
        // a reply sent from a socket that no longer exists.
        guard generation == groupGeneration else { return }
        // Counted before any filtering. What matters diagnostically is whether the
        // multicast group delivers ANYTHING at all — our own announcements looping
        // back, other devices' NOTIFY chatter, searches from control points. Zero
        // of everything is the signature of a blocked inbound path; a nonzero count
        // with no M-SEARCH is a very different problem and needs a different fix.
        receivedDatagramCount += 1
        lastDatagramAt = Date()
        // Inbound multicast is arriving, which cannot happen through a denied grant.
        // This is both the only positive proof of access and what clears the warning
        // promptly when the user flips the switch back on.
        //
        // Deliberately still driven by ANY datagram, this app's own loopback
        // included. Loopback is delivered through the same multicast group
        // membership that the Local Network grant gates, so it remains a sound
        // — and fast — proof of that grant. What it is NOT is proof that anything
        // on the LAN can reach this server, which is why the foreign-traffic
        // accounting below exists and reports separately.
        noteInboundTrafficObserved()

        guard let text = String(data: data, encoding: .utf8) else { return }

        // Headers are parsed for every datagram rather than only for searches,
        // because classifying the sender has to happen before the M-SEARCH filter
        // below: this app's own ssdp:alive NOTIFYs are the single largest source of
        // inbound traffic, and they would otherwise be discarded at that filter
        // without ever being recognized as ours.
        let headers = SSDPMessage.parseHeaders(text)

        // Ours, by any of the three marks this app leaves on what it sends: the
        // heartbeat header, the self-check probe header, or a USN naming this
        // server's own UDN (every alive and byebye NOTIFY carries one).
        let isSelfOriginated = headers[Self.heartbeatHeaderName.lowercased()] != nil
            || headers[SelfCheck.probeHeaderName.lowercased()] != nil
            || headers["usn"]?.contains(Preferences.serverUUID) == true
        if !isSelfOriginated { externalDatagramCount += 1 }

        // Only M-SEARCH is of interest. The group also receives every other
        // participant's NOTIFY traffic, which is ignored — LAN Stream is a server,
        // not a control point.
        guard text.hasPrefix("M-SEARCH") else { return }

        // This app's own heartbeat, arriving back through the multicast group. It has
        // already done its whole job above — it was counted as inbound traffic, which
        // is the proof of access it exists to produce — so it stops here rather than
        // going on to be answered. Answering it would open a reply connection on port
        // 1900 every five seconds to tell ourselves something we already know.
        if headers[Self.heartbeatHeaderName.lowercased()] != nil {
            if !heartbeatLoopbackObserved {
                heartbeatLoopbackObserved = true
                onTrafficWitnessLiveChange?(true)
            }
            return
        }

        // A search this app sent to itself is answered normally but not counted:
        // the statistics below exist to describe what PLAYERS are doing, and
        // folding our own probes into them would make the health report a
        // description of its own traffic.
        let isSelfProbe = headers[SelfCheck.probeHeaderName.lowercased()] != nil
        if !isSelfProbe { receivedMSearchCount += 1 }
        // MAN is a quoted token and its case is fixed by the spec, but it is
        // compared case-insensitively for the same reason the search target is:
        // being strict here buys nothing and costs discoverability.
        guard headers["man"]?.lowercased().contains("ssdp:discover") == true else { return }

        let searchTarget = headers["st"]?.trimmingCharacters(in: .whitespaces) ?? "ssdp:all"
        let maxWait = min(5, max(1, Int(headers["mx"] ?? "") ?? 1))

        // Search targets are matched case-insensitively. The spec treats these URNs
        // as case-sensitive, but a player that sends a differently-cased variant is
        // far better served by an answer than by silence, and no other device type
        // is close enough to match by accident.
        let matches = advertisedTypes.filter { advertised in
            searchTarget.caseInsensitiveCompare("ssdp:all") == .orderedSame
                || searchTarget.caseInsensitiveCompare(advertised.notificationType) == .orderedSame
        }
        // The requester's address is logged on both paths. Without it there is no
        // way to tell "the player never searched" from "the player searched and our
        // reply was dropped on the way back" — two problems with entirely different
        // causes that look identical from inside this app.
        let requester = NetworkDescription.describe(endpoint: message.remoteEndpoint)

        guard !matches.isEmpty else {
            Self.log("Ignoring M-SEARCH from \(requester) for unadvertised ST '\(searchTarget)'.")
            return
        }

        guard let location = locationURL(preferring: message.localEndpoint) else {
            Self.log("Cannot answer M-SEARCH for '\(searchTarget)' — no usable local IPv4 address.")
            return
        }

        // The spec says to wait a random interval between 0 and MX seconds before
        // replying, so that many devices on a busy network do not all answer in the
        // same millisecond and collide.
        //
        // Spreading across the full MX range is spec-compliant and, in practice, a
        // good way to be missed. Measured against VLC (MX=5), replies landed at
        // 4.16 s and 4.90 s — technically inside the window, yet the server still
        // intermittently failed to appear, because control points stop collecting at
        // or slightly before their own deadline. The jitter only has to be large
        // enough to de-synchronize simultaneous responders, and a few hundred
        // milliseconds achieves that completely on a home LAN. So the delay is
        // capped well below MX: still randomized, still collision-avoiding, but
        // delivered while the client is unambiguously still listening.
        let jitterCeiling = min(maxWait * 1000, Self.maximumResponseDelayMilliseconds)
        let delay = Duration.milliseconds(Int.random(in: 0...jitterCeiling))
        try? await Task.sleep(for: delay)
        // The group may have been replaced while this search waited out its jitter —
        // a port change or a recovery rebuild. 'location' was built before the wait
        // from the port that was current then, and answering with it would send the
        // player to a port nothing is listening on any more. The replacement group
        // announces itself, so the searcher loses nothing by this reply being dropped.
        guard generation == groupGeneration else { return }

        var payloads: [Data] = []
        for advertised in matches {
            // ST always carries this server's canonical spelling of the type
            // rather than echoing the client's. For an ssdp:all search the spec
            // requires the specific type anyway, and for a targeted search echoing
            // a miscased target back would only propagate the client's error into a
            // field other devices may compare against.
            let responseTarget = advertised.notificationType

            let response = """
            HTTP/1.1 200 OK\r
            CACHE-CONTROL: max-age=\(Self.cacheMaxAge)\r
            DATE: \(HTTPDate.now())\r
            EXT: \r
            LOCATION: \(location)\r
            SERVER: \(HTTPServer.serverToken)\r
            ST: \(responseTarget)\r
            USN: \(advertised.uniqueServiceName)\r
            BOOTID.UPNP.ORG: \(bootID)\r
            CONFIGID.UPNP.ORG: 1\r
            \r\n
            """
            payloads.append(Data(response.utf8))
        }

        if let remote = message.remoteEndpoint {
            enqueueReply(payloads, to: remote)
        }

        // Counted and logged only for real searches, so that the answered tally
        // always refers to the same population as the received tally.
        if isSelfProbe {
            Self.log("Answered self-check M-SEARCH from \(requester) ST='\(searchTarget)' (not counted in discovery statistics).")
        } else {
            answeredSearchCount += 1
            Self.log("Answered M-SEARCH from \(requester) ST='\(searchTarget)' (MX=\(maxWait), waited \(delay)) with \(matches.count) response(s), \(matches.count * 2) datagram(s) sent.")
        }
    }

    // MARK: - LOCATION construction
    // The URL of the device description document. Built from the local address on
    // the interface the search arrived on when that is known, so a multi-homed Mac
    // always answers with an address the searcher can reach.
    private func locationURL(preferring localEndpoint: NWEndpoint? = nil) -> String? {
        if let localEndpoint,
           case .hostPort(let host, _) = localEndpoint,
           case .ipv4(let address) = host {
            let text = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
            // Only trust this address if it is genuinely one of ours. For a datagram
            // received on a multicast connection group, Network.framework reports the
            // GROUP address as the local endpoint — 239.255.255.250 — and the earlier
            // form of this check rejected only the wildcard, so every M-SEARCH was
            // answered with "LOCATION: http://239.255.255.250:8201/description.xml".
            // Players accepted the reply, failed to fetch a description document from
            // a multicast address, and silently never appeared. Announcements were
            // unaffected because they pass no endpoint and fall through to the
            // primary-address lookup below, which is what made this look like a
            // discovery failure rather than a malformed URL.
            // Two independent conditions, because they fail differently. The address
            // must be one this machine actually holds (the group address is not),
            // and it must be one a client could connect to at all.
            let isOurs = NetworkInterface.activeIPv4Addresses().contains { $0.ipv4 == text }
            if isOurs && SelfCheck.isAdvertisableIPv4(text) {
                return "http://\(text):\(httpPort)\(UPnP.Path.deviceDescription)"
            }
        }

        // The fallback is validated too. Advertising a bad address from here would
        // fail exactly as invisibly as advertising one from the branch above.
        guard let address = NetworkInterface.primaryIPv4Address(),
              SelfCheck.isAdvertisableIPv4(address) else { return nil }
        return "http://\(address):\(httpPort)\(UPnP.Path.deviceDescription)"
    }

}

// MARK: - SSDPMessage
// Parsing shared between the responder and the self-check, which read the same
// datagrams off the same wire and previously each carried their own copy of this.
enum SSDPMessage {

    // SSDP reuses HTTP's header syntax. Names are lowercased because clients vary
    // in capitalization and the spec treats them case-insensitively.
    static func parseHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        // Split on CR-LF but tolerate a bare LF: SSDP implementations in the wild
        // are not uniformly careful about line endings, and a single sloppy sender
        // should not render its search unparseable.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            // Header VALUES are preserved verbatim. Lowercasing them — which this
            // function used to do — silently broke discovery outright: a search
            // target arrives as "urn:schemas-upnp-org:device:MediaServer:1", and
            // lowercasing it made the comparison against the advertised type
            // constant fail every time. The device then answered only the
            // undirected "ssdp:all" sweep and stayed invisible to any player that
            // searches for MediaServer:1 specifically, which most of them do.
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            // A line beginning with ":" has no name to key on. Storing it under the
            // empty string is not useful to any caller and would let one malformed
            // line shadow another, so it is skipped.
            guard !name.isEmpty else { continue }
            headers[name] = value
        }
        return headers
    }
}

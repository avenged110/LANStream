// MARK: - DLNAServer.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Coordinator that owns the content index, the HTTP listener, and the SSDP
// responder, and keeps the menu bar's status in sync with all three.
//
// Startup ordering is deliberate: the index is built first, then HTTP begins
// listening, and only then does SSDP announce. Announcing before the listener is
// accepting connections would invite a client to fetch a description document
// from a port nothing is bound to, and a client that fails its first fetch may
// not retry until its cache expires.

import Foundation
import AppKit
import Network

// MARK: - ServerStatus
// The main-actor-observable state the menu bar renders. This is the only piece of
// server state that lives on the main actor; everything else stays inside the
// actors below and is pushed here in summarized form.
@MainActor
@Observable
final class ServerStatus {

    enum State: Equatable {
        case stopped
        case starting
        case indexing
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    var state: State = .stopped
    var fileCount = 0
    var folderCount = 0
    var unreachableFolders: [String] = []
    var address: String?
    // Number of media transfers in flight. Mirrored here from the server actor so
    // the menu bar can reflect "currently serving" live, without the menu being
    // open and without polling.
    private(set) var activeStreamCount = 0

    // Generation of the most recently applied count; see HTTPServer for why.
    @ObservationIgnored private var lastStreamCountGeneration: UInt64 = 0

    func applyStreamCount(_ count: Int, generation: UInt64) {
        guard generation > lastStreamCountGeneration else { return }
        lastStreamCountGeneration = generation
        activeStreamCount = count
    }

    // Re-arms the generation guard for a newly started server.
    func prepareForRestart() {
        lastStreamCountGeneration = 0
        activeStreamCount = 0
    }

    func resetStreamCount() {
        // Not generation-guarded: a stopped server has no transfers by definition,
        // and this must win over any late notification still in flight.
        lastStreamCountGeneration = .max
        activeStreamCount = 0
    }

    var isServingContent: Bool { activeStreamCount > 0 }

    // True when discovery traffic is being refused by the system in the way a denied
    // Local Network privacy grant refuses it. Set from SSDPResponder, which is the
    // only part of the app in a position to observe it; see the discussion there for
    // why this is inferred from send errors rather than queried.
    //
    // Kept separate from `state` on purpose. The server can be perfectly healthy by
    // every internal measure — listener bound, index built, announcements queued —
    // and still be invisible to every device on the network, so this is an
    // independent axis rather than another failure case.
    var isLocalNetworkBlocked = false

    // The two witnesses behind isLocalNetworkBlocked, mirrored here so the menu can
    // tell them apart at the instant it is built. See DLNAServer's blocked-LAN
    // verdict section for what each one knows, and StatusMenuController for the one
    // decision that needs to distinguish them.
    var isLANBlockedByTrafficWitness = false
    var isLANBlockedBySelfCheckWitness = false

    // True while the responder's heartbeat is proving inbound traffic on a fixed
    // cadence, which is what makes a clear traffic verdict a statement about the
    // last few seconds rather than about some unknown earlier moment.
    var isTrafficWitnessLive = false

    // The port the listener actually bound, and the one the user asked for. They
    // differ when the preferred port was taken and the fallback ladder found another;
    // see DLNAServer.bindListener.
    var activePort: UInt16?
    var preferredPort: UInt16?

    var isUsingFallbackPort: Bool {
        guard let activePort, let preferredPort else { return false }
        return activePort != preferredPort
    }

    // Single-line summary shown as the menu's status item.
    //
    // The counts describe what is SERVABLE RIGHT NOW, not what is configured. A
    // folder whose drive has been unplugged contributes nothing a client can browse
    // or play, so counting it here would have the menu promise content that does not
    // exist. The fact that something is missing is not lost — it is reported on its
    // own line, with its own glyph, which is a better place for it than a number that
    // silently disagrees with what the player shows.
    var summary: String {
        switch state {
        case .stopped:
            return "Server stopped"
        case .starting:
            return "Starting…"
        case .indexing:
            return "Scanning folders…"
        case .failed(let reason):
            return reason
        case .running:
            if folderCount == 0 {
                // "None shared" and "none reachable" are different situations and a
                // user in the second one is mid-problem; telling them they have not
                // shared anything would send them looking in the wrong place.
                return unreachableFolders.isEmpty
                    ? "Running – no folders shared"
                    : "Running – no folders available"
            }
            return "Serving \(folderPhrase), \(filePhrase)"
        }
    }

    // How many configured folders cannot currently be read, and how to say it.
    var unavailableFolderCount: Int { unreachableFolders.count }

    var unavailableFolderPhrase: String {
        unavailableFolderCount == 1
            ? "1 folder unavailable"
            : "\(unavailableFolderCount) folders unavailable"
    }

    // "3 folders" / "1 folder", pluralized.
    var folderPhrase: String {
        folderCount == 1 ? "1 folder" : "\(folderCount) folders"
    }

    var filePhrase: String {
        fileCount == 1 ? "1 file" : "\(fileCount) files"
    }

    // The one-line status shown at the bottom of the Shared Folders tab, where there
    // is room to name the address inline rather than on a second row — and room for
    // the unavailable count, which the menu has to give its own row to.
    //
    // The unavailable suffix appears only while something IS still being served. With
    // nothing left available the guard below has already handed off to 'summary',
    // which says "Running — no folders available" — and "no folders available
    // (2 folders unavailable)" would be the same fact told twice in one line.
    var servingSummaryWithAddress: String {
        guard case .running = state else { return summary }
        guard folderCount > 0 else { return summary }

        var line = "Serving \(folderPhrase), \(filePhrase)"
        // Address folded in when there is one. There may not be, briefly, between an
        // interface going away and discovery being rebuilt.
        if let address { line += " at \(address)" }
        if unavailableFolderCount > 0 { line += " (\(unavailableFolderPhrase))" }
        return line
    }

    // Secondary line: the address a player would reach. Nil when there is nothing
    // useful to add.
    //
    // This used to be overloaded — it returned an "Unavailable: …" warning INSTEAD of
    // the address whenever a folder could not be read. That made the two facts
    // mutually exclusive for no reason: a user whose drive has just dropped off still
    // wants to know where the server is, and losing the address at exactly the moment
    // something went wrong is the opposite of helpful. The unavailable count now has
    // its own row and this says only what it is named for.
    var detail: String? {
        guard case .running = state else { return nil }
        return address
    }
}

// MARK: - DLNAServer
actor DLNAServer: Loggable {
    nonisolated static let logTag = "[DLNAServer]"

    // Fallback re-scan interval, used ONLY for shared folders on remote volumes.
    //
    // Local folders are watched with FSEvents and are not polled at all. FSEvents
    // cannot report changes made by another host to a network mount, though — no
    // notification is ever generated for them — so for those a periodic re-walk is
    // the only mechanism that works. It is deliberately slow: it exists to catch
    // what the watcher structurally cannot see, not to be the primary path.
    private static let remoteFallbackRescanInterval: Duration = .seconds(300)

    private let contentIndex = ContentIndex()
    private let status: ServerStatus
    private let folderStore: FolderStore

    private lazy var httpServer = HTTPServer(contentIndex: contentIndex,
                                             onActiveStreamCountChanged: { [status] count, generation in
        // ServerStatus is main-actor isolated, so the hop is mandatory; the closure
        // itself is invoked from the server actor whenever a transfer starts or ends.
        Task { @MainActor in status.applyStreamCount(count, generation: generation) }
    })
    private lazy var ssdpResponder = SSDPResponder()

    private var rescanTask: Task<Void, Never>?
    private var isRunning = false
    // True from the moment start() is entered until it settles.
    //
    // start() suspends several times before it can set isRunning, so two callers
    // arriving in that window both pass the isRunning guard and both try to bind
    // the listener. The path monitor makes this reachable in practice: it fires as
    // soon as it is installed, and if the address is still settling during launch
    // it can call start() while the original start() is mid-flight.
    private var isStarting = false

    // Filesystem watcher for the shared folders. Lazily created so the callback can
    // capture this actor without a chicken-and-egg initializer problem.
    private var folderWatcher: FolderWatcher?
    // The path set the watcher is currently installed over, and whether the
    // fallback timer is wanted. Both are compared before acting so a routine
    // rescan does not needlessly rebuild the event stream.
    private var watchedPaths: [String] = []
    private var isUsingFallbackPolling: Bool?

    // Rescan coalescing. A rescan has several suspension points, so this actor is
    // reentrant across them and two rescans could otherwise interleave — easy to
    // trigger by adding several folders quickly, or by hitting "Rescan Now" while
    // the periodic one is running. Overlapping scans are wasteful rather than
    // corrupting (the index swap is atomic), but a request that arrives mid-scan
    // must not simply be dropped either, or a folder added at the wrong moment
    // would not appear until the next timer tick five minutes later. So: at most
    // one scan runs, and at most one more is remembered as pending.
    private var isRescanning = false
    private var rescanRequestedWhileRunning = false

    // Watches for the machine's network situation changing underneath a running
    // server: an address change, an interface coming back after a router reboot.
    private var pathMonitor: NWPathMonitor?
    private var lastAdvertisedAddress: String?
    // Last reported path satisfaction, so the UP EDGE can be acted on even when the
    // address is unchanged. An interface that drops and returns on the same DHCP
    // lease leaves multicast membership dead while every address comparison says
    // "nothing changed" — the server then looks perfectly healthy and is invisible.
    private var lastPathSatisfied: Bool?

    // MARK: - Self-healing state
    // Retry ladder for a start or a recovery that failed. Bounded and increasing:
    // a port held by another process usually clears in seconds, an interface that
    // has not appeared yet usually appears in seconds, and anything still broken
    // after five minutes is a standing condition that is better retried slowly
    // than hammered.
    private static let recoveryRetryDelays: [Duration] =
        [.seconds(5), .seconds(15), .seconds(60), .seconds(300)]
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0

    // Guards against overlapping recoveries. Several triggers can fire at once —
    // wake, path change, and the discovery escalation that the wake itself caused —
    // and three concurrent rebuilds of the same listener is a way to manufacture the
    // outage being recovered from.
    private var isRecovering = false
    private var lastRecoveryAt: Date?
    // Floor between two recoveries requested by independent triggers. Anything
    // arriving inside this window is logged and dropped: it is almost certainly the
    // same event observed a second way.
    private static let recoveryCooldown: TimeInterval = 30

    // How many times the outside-in self-check has been remediated for the current
    // advertisement. Reset whenever the address changes or the server restarts, so
    // each new advertisement gets one automatic repair attempt and no more —
    // a check that still fails after a rebuild is describing something outside this
    // process, and looping on it would only fill the log.
    private var selfCheckRemediations = 0
    private var lastSelfCheckedAddress: String?
    // Identifies the self-check currently in flight, so a result that arrives after
    // its task has already been replaced cannot clear the tracking slot belonging to
    // its successor. Without it, a late result set selfCheckTask to nil under a newer
    // task, that task became invisible to cancellation, and the next schedule started
    // a second check alongside it.
    private var selfCheckGeneration: UInt64 = 0

    // Whether the filesystem watcher is actually installed. False forces the
    // periodic fallback rescan on regardless of volume locality.
    private var isWatcherHealthy = true

    // Periodic internal audit; see startHealthWatchdog.
    private var healthWatchdogTask: Task<Void, Never>?
    private static let healthWatchdogInterval: Duration = .seconds(60)

    // Set while the machine is asleep, so the wake handler can say how long the
    // outage lasted and can distinguish a wake from an ordinary path change.
    private var sleptAt: Date?

    // Verifies the advertisement from the outside once the server has settled.
    // Held so it can be canceled on stop() and replaced when the address changes,
    // rather than leaving a stale check to report on an advertisement that has
    // already been withdrawn.
    private var selfCheckTask: Task<Void, Never>?

    init(status: ServerStatus, folderStore: FolderStore) {
        self.status = status
        self.folderStore = folderStore
    }

    // MARK: - Shared idioms
    // The port discovery should advertise: whatever the listener actually bound,
    // falling back to the configured preference when it is not bound yet. Both
    // halves matter — reading the preference alone would advertise a port nothing
    // is listening on whenever the fallback ladder was walked.
    private func currentBoundPort() async -> UInt16 {
        await httpServer.port ?? UInt16(Preferences.serverPort)
    }

    // SSDP failures arrive as a typed StartError on the start path and as an opaque
    // Error elsewhere. This renders whichever turned up, so the log line reads the
    // same either way.
    private static func describe(startError error: any Error) -> String {
        (error as? SSDPResponder.StartError)?.displayText ?? error.localizedDescription
    }

    // MARK: - Lifecycle
    func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        await MainActor.run {
            status.state = .starting
            // Clears the generation high-water mark left by resetStreamCount so the
            // new server's notifications are not all discarded as stale.
            status.prepareForRestart()
        }
        Self.log("Starting server…")

        // 1. Build the index before anything is advertised.
        await MainActor.run { status.state = .indexing }
        await rescan()

        // 2. Bind the HTTP listener, walking the fallback ladder if the preferred
        //    port is taken. See bindListener for why this is worth doing.
        let port = UInt16(Preferences.serverPort)
        do {
            try await bindListener(preferred: port)
        } catch let error as HTTPServer.StartError {
            Self.log("ERROR: \(error.displayText)")
            // Leave nothing half-bound behind: a listener that reached .failed can
            // still hold its socket, and the next start attempt would then report a
            // port conflict against this app's own corpse.
            await httpServer.stop()
            await MainActor.run { status.state = .failed(error.displayText) }
            // Keep watching the network: this failure may be transient (no
            // interface yet at login), and the monitor is what notices if it clears.
            startPathMonitor()
            // The monitor alone is not enough. It fires on a CHANGE of path, and the
            // commonest cause of this branch — another process holding the port at
            // login — happens on a network that is already up and never changes
            // again, so nothing would ever retry and the app would sit failed until
            // the user noticed. The ladder covers exactly that gap.
            scheduleRetry(reason: "HTTP listener failed to start: \(error.displayText)")
            return
        } catch {
            let text = "Server error: \(error.localizedDescription)"
            Self.log("ERROR: \(text)")
            await httpServer.stop()
            await MainActor.run { status.state = .failed(text) }
            startPathMonitor()
            scheduleRetry(reason: "HTTP listener failed to start: \(text)")
            return
        }

        let boundPort = await httpServer.port ?? port

        // The server counts as running the moment HTTP is listening, BEFORE the
        // SSDP attempt below. This ordering is load-bearing: if the flag were only
        // set after a successful SSDP start, an SSDP failure would leave a live,
        // bound listener behind a false isRunning == false, and stop() — which
        // guards on that flag — would silently decline to tear it down. Changing the
        // port afterwards would then fail with "port in use" against this very
        // process, with no way out but quitting the app.
        isRunning = true

        // A listener that dies after startup leaves the app advertising an address
        // that no longer answers. Rebuilding the whole server is the honest response:
        // it re-binds the port, and if that now fails the failure is surfaced in the
        // menu bar instead of hiding behind a healthy-looking idle state.
        await httpServer.setListenerFailureHandler { [weak self] in
            Task { await self?.handleListenerLoss() }
        }

        // The UDP side gets the same treatment. Until this existed a multicast group
        // that failed after startup was logged once and never repaired.
        await ssdpResponder.setFailureHandler { [weak self] reason in
            Task { await self?.recover(reason: "discovery reported a fault — \(reason)") }
        }

        // Local Network permission is not something this app can query or repair, so
        // unlike the handler above this one does not trigger recovery — it only
        // surfaces the condition in the menu bar, where the user can act on it.
        await ssdpResponder.setLocalNetworkAccessHandler { [weak self] access in
            Task { await self?.setDiscoveryBlockedByTraffic(access == .denied) }
        }

        await ssdpResponder.setTrafficWitnessLiveHandler { [weak self] isLive in
            Task { @MainActor in self?.status.isTrafficWitnessLive = isLive }
        }

        // Record the address BEFORE the monitor starts. NWPathMonitor delivers the
        // current path immediately on start, so with the baseline still nil that
        // first callback read as "address changed: none → 10.0.2.63" and fired a
        // redundant announcement burst at every launch — one of which raced the
        // multicast group reaching .ready and was sent into a socket that had not
        // joined yet.
        lastAdvertisedAddress = NetworkInterface.primaryIPv4Address()
        startPathMonitor()

        let address = NetworkInterface.primaryIPv4Address().map {
            "http://\($0):\(boundPort)"
        }

        // 3. Only now announce the device.
        do {
            try await ssdpResponder.start(httpPort: boundPort)
        } catch let error as SSDPResponder.StartError {
            // The HTTP side is up, so a client that already knows the address can
            // still browse. The server stays up and the failure is surfaced instead
            // of being treated as fatal.
            Self.log("ERROR: \(error.displayText)")
            await MainActor.run {
                status.address = address
                status.state = .failed(error.displayText)
            }
            scheduleRetry(reason: "discovery failed to start: \(error.displayText)")
            return
        } catch {
            Self.log("ERROR: SSDP failed to start: \(error.localizedDescription)")
            await MainActor.run {
                status.address = address
                status.state = .failed("Discovery unavailable — see log")
            }
            scheduleRetry(reason: "discovery failed to start: \(error.localizedDescription)")
            return
        }

        await MainActor.run {
            status.address = address
            status.state = .running
        }
        Self.log("Server running at \(address ?? "unknown address").")

        // A clean start is the definition of health: the ladder starts from the
        // bottom again for whatever goes wrong next, and this advertisement is
        // entitled to its own automatic repair attempt.
        clearRetrySchedule(reason: "the server reached the running state")
        startHealthWatchdog()

        scheduleSelfCheck(baseAddress: address)
    }

    // MARK: - Port binding
    // Tries the configured port, then a short ladder above it, and reports which one
    // it landed on.
    //
    // The alternative — failing outright on EADDRINUSE — is a poor trade for a
    // background app. The port is an implementation detail to everyone involved:
    // clients never assume one, they read it from the LOCATION in the advertisement,
    // so binding one higher costs nothing and rescues three ordinary situations that
    // otherwise leave the user with a dead menu bar icon and a message about a number
    // they never chose to care about:
    //
    //   • An unrelated DLNA server (MiniDLNA, Gerbera, a NAS agent) holding the port.
    //   • This app's own previous instance not yet fully released by the kernel — a
    //     wedged copy being force-quit, or one still finishing its shutdown.
    //   • Any unrelated software that happens to have claimed the number.
    //
    // A second copy of THIS app is not in that list: AppDelegate refuses to start one.
    //
    // Only .portInUse advances the ladder. Every other failure — no interface, a
    // firewall refusal, an invalid port — would fail identically on the next
    // candidate, so retrying would just produce four copies of the same error and
    // delay the real report.
    //
    // Landing on a fallback is recorded on ServerStatus rather than being silently
    // absorbed: the user asked for a specific port and is entitled to know they did
    // not get it, which the menu bar then says out loud.
    private func bindListener(preferred: UInt16) async throws {
        let candidates = Preferences.portCandidates(preferred: preferred)
        var lastPortInUse: (any Error)?

        for candidate in candidates {
            do {
                try await httpServer.start(port: candidate)
                if candidate != preferred {
                    Self.log("PORT FALLBACK: port \(preferred) is in use, so the server "
                        + "bound to \(candidate) instead. Clients are unaffected — the "
                        + "port they use comes from the advertised LOCATION — but the "
                        + "preferred port will be taken again on the next start unless "
                        + "whatever holds it is stopped or the setting is changed.")
                }
                await MainActor.run {
                    status.activePort = candidate
                    status.preferredPort = preferred
                }
                return
            } catch let error as HTTPServer.StartError {
                guard case .portInUse = error else { throw error }
                // A listener that reached .failed can still hold its socket, and the
                // next candidate would then be tested against this app's own corpse.
                await httpServer.stop()
                lastPortInUse = error
                Self.log("Port \(candidate) is in use; trying the next candidate.")
            }
        }

        await MainActor.run {
            status.activePort = nil
            status.preferredPort = preferred
        }
        Self.log("ERROR: every candidate port (\(candidates.map(String.init).joined(separator: ", "))) "
            + "is already in use.")
        throw lastPortInUse ?? HTTPServer.StartError.portInUse(preferred)
    }

    // Deliberately fire-and-forget and deliberately delayed. The announcement burst
    // and the multicast group both need a moment to settle, and running the probe
    // inline would make a slow or filtered network delay the point at which the
    // server reports itself running. Nothing downstream waits on the result: it is
    // a log line, not a gate.
    private func scheduleSelfCheck(baseAddress: String?,
                                   settleDelay: Duration = .seconds(5)) {
        guard let baseAddress else {
            selfCheckTask?.cancel()
            selfCheckTask = nil
            return
        }

        // An advertisement for a DIFFERENT address makes any check still running
        // obsolete — it is asking a question about a server that has moved — so that
        // one is canceled and replaced.
        //
        // A repeat request for the SAME address is not, and must not restart the
        // clock. This is the bug that kept the first-launch warning up until the app
        // was relaunched. A self-check takes eight to thirteen seconds when the LAN
        // is blocked (a five-second description timeout followed by a six-second
        // discovery probe), while the blocked-recovery ladder opens at five seconds
        // and probes again at ten — and every probe called straight into here and
        // canceled the check in flight. On the rungs that matter most, the ones
        // covering the minute right after the user grants the permission, no
        // self-check ever survived long enough to report that discovery was working
        // again, so the outside-in witness stayed latched at 'blocked' and nothing
        // ever cleared it. Letting the in-flight check finish is the whole fix:
        // its verdict is about the same address and is moments away.
        if baseAddress != lastSelfCheckedAddress {
            selfCheckTask?.cancel()
            selfCheckTask = nil
        } else if let existing = selfCheckTask, !existing.isCancelled {
            Self.log("A self-check for \(baseAddress) is already in flight; letting it "
                + "finish rather than restarting it.")
            return
        }
        // The one-repair budget belongs to the ADVERTISEMENT, not to the process.
        // Tying it to start() instead would hand a fresh budget to every restart,
        // including the restarts this very mechanism requests — which is the shape
        // of an infinite repair loop over a fault the app cannot fix.
        if baseAddress != lastSelfCheckedAddress {
            lastSelfCheckedAddress = baseAddress
            selfCheckRemediations = 0
        }
        let location = "\(baseAddress)\(UPnP.Path.deviceDescription)"
        let udn = Preferences.serverUUID

        selfCheckGeneration &+= 1
        let generation = selfCheckGeneration

        selfCheckTask = Task { [weak self] in
            // Shortened on the recovery path: there the caller is a user waiting on a
            // verdict, the multicast group has just been rebuilt rather than started
            // from cold, and every second of settling is a second of the menu bar
            // showing a state the machine is no longer in.
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled else { return }
            let report = await SelfCheck.run(advertisedLocation: location, udn: udn)
            // Re-checked after the run, not only before it. SelfCheck.verifyDiscovery
            // does its work in a blocking socket loop on a global queue, which no
            // cancellation can reach, so a canceled check still runs to completion
            // and still produces a verdict — and its description half comes back as a
            // spurious failure, because that half IS cancellation-aware and reports
            // the cancellation as an unreachable URL. Publishing that would condemn a
            // healthy advertisement on the strength of a check nobody was waiting for.
            guard !Task.isCancelled else { return }
            await self?.handleSelfCheckResult(report: report, location: location,
                                              generation: generation)
        }
    }

    // The self-check used to be pure diagnosis: it detected, in the most explicit
    // terms available anywhere in this app, that the server was invisible from the
    // outside — and then did nothing about it. One automatic repair per
    // advertisement turns that into a fix; refusing to repeat it keeps the app from
    // restarting itself forever over a condition it cannot influence, such as a
    // network that filters multicast between clients.
    private func handleSelfCheckResult(report: SelfCheck.Report,
                                       location: String,
                                       generation: UInt64) async {
        // Only the check that is actually current may retire the tracking slot.
        if generation == selfCheckGeneration { selfCheckTask = nil }

        // An unanswered M-SEARCH sent over the real network is the strongest
        // evidence this app can obtain that its discovery traffic is not getting
        // through, so it drives the warning directly — including clearing it when a
        // later check passes.
        if report.discoveryPassed != nil {
            await setDiscoveryBlockedBySelfCheck(report.discoveryBlocked)
        }

        guard !report.passed else { return }
        guard isRunning else { return }

        // While the blocked-LAN loop is running it owns recovery: it is already
        // rebuilding the discovery socket on its own schedule, and this check is one
        // of its instruments rather than an independent observer. Falling through
        // here would either fight it for the rebuild or print SELF-HEAL DECLINED on
        // every single probe, which would bury the log in an alarm about a condition
        // the app is actively and correctly working on.
        guard blockedRecoveryTask == nil else { return }

        if selfCheckRemediations >= 1 {
            Self.log("SELF-HEAL DECLINED: the self-check still fails for \(location) after "
                + "an automatic rebuild. The fault is not something restarting this app "
                + "can fix — check Local Network permission, any third-party firewall, "
                + "and whether this network passes multicast between clients. No further "
                + "automatic recovery will be attempted for this advertisement.")
            return
        }
        selfCheckRemediations += 1
        await recover(reason: "the outside-in self-check failed for \(location)",
                      force: true)
    }

    // MARK: - Blocked-LAN verdict
    // Two independent witnesses, deliberately kept apart and OR-ed together rather
    // than collapsed into one flag at the source:
    //
    //   • The responder watches its own traffic from the INSIDE. It reacts within a
    //     second of a revocation (the socket tear-out) and again at the 20 s
    //     reachability report, but it can only observe what reaches this process.
    //   • The self-check probes from the OUTSIDE, sending a real M-SEARCH over the
    //     network and waiting for this app to answer it. That is the definitive test
    //     and the one that catches a fault the inside view cannot see, but it only
    //     runs at startup and after a rebuild.
    //
    // Either one is sufficient evidence for the warning; both must be clear for it to
    // go away. Whichever notices first is what the user sees.
    private var discoveryBlockedByTraffic = false
    private var discoveryBlockedBySelfCheck = false

    private func setDiscoveryBlockedByTraffic(_ blocked: Bool) async {
        guard discoveryBlockedByTraffic != blocked else { return }
        discoveryBlockedByTraffic = blocked
        await publishBlockedVerdict()
    }

    private func setDiscoveryBlockedBySelfCheck(_ blocked: Bool) async {
        guard discoveryBlockedBySelfCheck != blocked else { return }
        discoveryBlockedBySelfCheck = blocked
        await publishBlockedVerdict()
    }

    private func publishBlockedVerdict() async {
        let blocked = discoveryBlockedByTraffic || discoveryBlockedBySelfCheck
        let byTraffic = discoveryBlockedByTraffic
        let bySelfCheck = discoveryBlockedBySelfCheck
        await MainActor.run {
            status.isLocalNetworkBlocked = blocked
            status.isLANBlockedByTrafficWitness = byTraffic
            status.isLANBlockedBySelfCheckWitness = bySelfCheck
        }
        Self.log("LAN traffic verdict: \(blocked ? "BLOCKED" : "clear") "
            + "(inside-out: \(discoveryBlockedByTraffic ? "blocked" : "clear"), "
            + "outside-in: \(discoveryBlockedBySelfCheck ? "blocked" : "clear")).")
        if blocked {
            startBlockedRecoveryLoop()
        } else {
            stopBlockedRecoveryLoop()
        }
    }

    // MARK: - Recovery from a blocked LAN
    // Granting Local Network access does NOT require restarting the app, but it does
    // require restarting the SOCKET. A multicast group created while access was
    // denied stays dead after the grant is restored: it keeps sending without error
    // and keeps receiving nothing, exactly as it did before. Since inbound traffic is
    // the only evidence this app has, a responder in that state can never observe its
    // own recovery — which is why the warning used to persist until the user quit and
    // relaunched.
    //
    // So while the verdict is blocked, the discovery socket is periodically torn down
    // and rebuilt. A rebuild under a restored grant immediately receives its own
    // announcement burst looping back, which flips the verdict to clear and stops
    // this loop. A rebuild under a still-denied grant receives nothing, the 20 s
    // reachability report re-condemns it, and the loop simply tries again later.
    //
    // The interval backs off because the two cases it serves have opposite needs: a
    // user who has just toggled the switch wants an answer in seconds, while a
    // network that genuinely does not pass multicast would otherwise have its
    // discovery socket rebuilt every thirty seconds for as long as the app runs. The
    // backoff serves the second case; checkForRestoredLANAccess serves the first.
    private var blockedRecoveryTask: Task<Void, Never>?
    private var blockedRecoveryDelay: Duration = .seconds(5)
    private var lastBlockedProbeAt: Date?
    // The first few probes are the ones that matter, because the overwhelmingly
    // common case is a user who went to System Settings, flipped the switch, and is
    // now waiting to see the warning go away. Twenty seconds was a long time to sit
    // in front of a menu bar that still says the wrong thing, and the doubling meant
    // a grant restored a couple of minutes later waited out a two-minute backoff. The
    // ladder now opens at five seconds and stops doubling at sixty; rebuilding one
    // UDP socket is cheap, and the cost of an extra probe is far below the cost of
    // showing a stale verdict.
    private static let blockedRecoveryInitialDelay: Duration = .seconds(5)
    private static let blockedRecoveryMaximumDelay: Duration = .seconds(60)
    // Floor between probes, so repeated activations cannot rebuild the socket in a
    // tight loop.
    private static let blockedProbeMinimumSpacing: TimeInterval = 5

    // Set when a probe arrives while some OTHER recovery (wake, a listener loss, a
    // discovery fault) is already in flight and is dropped rather than run. Without
    // this, "the user granted access and switched straight back" loses its fast path
    // whenever it lands on that narrow window, silently falling back to whatever is
    // left of the backoff — up to two minutes, against the whole point of this path
    // being an answer in seconds. recover()'s completion drains this exactly once, so
    // the signal is not lost, only delayed until the machine is free to act on it.
    private var pendingBlockedProbeTrigger: String?

    private func startBlockedRecoveryLoop() {
        guard blockedRecoveryTask == nil else { return }
        blockedRecoveryDelay = Self.blockedRecoveryInitialDelay
        Self.log("Starting the blocked-LAN recovery loop: the discovery socket will be "
            + "rebuilt periodically to detect access being restored.")
        blockedRecoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.blockedRecoveryDelay
                do { try await Task.sleep(for: delay) } catch { return }
                // Only a probe that actually ran earns a longer wait before the
                // next one. A probe dropped by the minimum-spacing floor or deferred
                // because a recovery was in flight has tested nothing, and counting
                // it as an attempt used to race the ladder out to its sixty-second
                // ceiling without a single real test having happened — worst of all
                // for a user who opens the menu repeatedly while waiting, since each
                // open fires its own probe and pushes this one into the floor.
                if await self.probeForRestoredLANAccess(trigger: "the periodic recovery loop") {
                    await self.lengthenBlockedRecoveryDelay()
                }
            }
        }
    }

    private func stopBlockedRecoveryLoop() {
        guard blockedRecoveryTask != nil else { return }
        blockedRecoveryTask?.cancel()
        blockedRecoveryTask = nil
        blockedRecoveryDelay = Self.blockedRecoveryInitialDelay
        Self.log("LAN traffic is no longer blocked — stopping the recovery loop.")
    }

    private func lengthenBlockedRecoveryDelay() {
        let doubled = blockedRecoveryDelay * 2
        blockedRecoveryDelay = min(doubled, Self.blockedRecoveryMaximumDelay)
    }

    // Called when the app is activated or its menu is opened while blocked.
    //
    // This is the path that matters in practice. Someone who has just granted the
    // permission comes straight back to this app, and that return is a far better
    // signal than any timer: it means the user has finished doing whatever they went
    // away to do. Checking then makes the recovery feel immediate rather than making
    // them wait out a backoff they cannot see.
    // Called from the menu the moment it is opened, when the menu has decided from
    // the mirrored witnesses that the only thing still holding the warning up is a
    // self-check verdict the traffic witness now contradicts. See the discussion at
    // that call site for why the menu makes the decision and this only carries it
    // out: the point of the exercise is that nothing may be awaited before the menu
    // draws, so the authoritative half of the work happens here, afterwards.
    //
    // The conditions are re-checked rather than trusted. The menu read a mirror on
    // another actor, and between its read and this call the responder may have
    // learned something that changes the answer — in which case the state it learned
    // is the better one and this does nothing.
    func retireStaleSelfCheckVerdict() async {
        guard discoveryBlockedBySelfCheck, !discoveryBlockedByTraffic else { return }
        discoveryBlockedBySelfCheck = false
        Self.log("Retiring a stale outside-in verdict at the user's request: inbound "
            + "multicast is arriving now, which is the very thing the failed "
            + "self-check concluded was not happening. Re-testing to confirm.")
        await publishBlockedVerdict()

        // Optimism with a deadline. The warning is down on evidence that is good but
        // indirect — traffic reaching this app is not identical to this app being
        // reachable from the network — so a real check is queued immediately behind
        // it, and if discovery is genuinely still broken the warning returns within
        // seconds. Being briefly wrong in the direction of "working" and correcting
        // itself is the right trade here; being reliably wrong in the direction of
        // "broken" for ten seconds after the user has already fixed it is the
        // complaint this exists to answer.
        let boundPort = await currentBoundPort()
        if let address = NetworkInterface.primaryIPv4Address() {
            scheduleSelfCheck(baseAddress: "http://\(address):\(boundPort)",
                              settleDelay: .zero)
        }
    }

    func checkForRestoredLANAccess() async {
        guard discoveryBlockedByTraffic || discoveryBlockedBySelfCheck else { return }
        await probeForRestoredLANAccess(trigger: "returning to the app")
    }

    // Returns true only when a rebuild actually took place, so callers can tell a
    // real test apart from one that was declined.
    @discardableResult
    private func probeForRestoredLANAccess(trigger: String) async -> Bool {
        guard isRunning else { return false }
        guard discoveryBlockedByTraffic || discoveryBlockedBySelfCheck else { return false }
        guard !isRecovering else {
            // Not lost: recover()'s completion checks this and runs the probe itself.
            // Whatever recovery is in flight already supersedes a stale trigger, so
            // only the most recent one needs to be remembered.
            pendingBlockedProbeTrigger = trigger
            Self.log("LAN recovery probe (\(trigger)) deferred: a recovery is already "
                + "in progress. Will probe as soon as it finishes.")
            return false
        }

        // A self-check already in flight IS this test, and rebuilding now would
        // sabotage it: the rebuild below tears down and replaces the very multicast
        // group the check's M-SEARCH is waiting to be answered by, so the check
        // fails, re-condemns the advertisement, and the ladder concludes the LAN is
        // still blocked on evidence it destroyed itself. Waiting costs at most the
        // check's own hard-timeboxed thirteen seconds, and false 'false' is
        // returned so the backoff does not lengthen over a probe that never ran.
        if let existing = selfCheckTask, !existing.isCancelled {
            Self.log("LAN recovery probe (\(trigger)) held: a self-check is already in "
                + "flight and its verdict is the test this probe would be starting.")
            return false
        }

        if let last = lastBlockedProbeAt,
           Date().timeIntervalSince(last) < Self.blockedProbeMinimumSpacing {
            return false
        }
        lastBlockedProbeAt = Date()

        let boundPort = await currentBoundPort()
        Self.log("LAN recovery probe (\(trigger)): rebuilding the discovery socket to "
            + "test whether access has been restored.")

        // No byebye: it would go out over the very path being tested, and the alive
        // burst that follows the rebuild tells clients everything anyway.
        await ssdpResponder.stop(sendingGoodbye: false)
        do {
            try await ssdpResponder.start(httpPort: boundPort)
        } catch {
            let text = Self.describe(startError: error)
            Self.log("LAN recovery probe failed to restart discovery: \(text). Will try "
                + "again.")
            return false
        }

        // The outside-in verdict was made against the socket that has just been
        // thrown away, so it is now a statement about something that no longer
        // exists. Retiring it here is what stops the two witnesses from taking turns
        // holding the warning up: without this, inbound traffic returning would clear
        // the inside-out half and the menu would still say BLOCKED for as long as the
        // replacement self-check takes to run — eleven seconds of watching the wrong
        // state, which is most of what the delay felt like.
        //
        // Only while the inside-out half is ALSO blocked, though. When the self-check
        // is the sole witness there is no second opinion to fall back on, and
        // retiring it would clear the warning on no evidence at all and then put it
        // back seconds later. In that case its replacement, scheduled just below, is
        // the only thing that can honestly speak, and it is worth waiting for.
        if discoveryBlockedByTraffic && discoveryBlockedBySelfCheck {
            discoveryBlockedBySelfCheck = false
            Self.log("Retiring the outside-in verdict: it describes the discovery "
                + "socket that was just replaced. The inside-out witness holds the "
                + "warning until a fresh self-check reports.")
        }

        // The responder clears the inside-out half by itself, on the first datagram
        // that arrives. The outside-in half needs its own probe, since a self-check
        // that failed once is never re-run on its own.
        if let address = NetworkInterface.primaryIPv4Address() {
            scheduleSelfCheck(baseAddress: "http://\(address):\(boundPort)",
                              settleDelay: .seconds(2))
        }
        return true
    }

    // Called from recover()'s defer, after isRecovering has just been cleared. A
    // trigger recorded here means a caller asked to be probed and got nothing —
    // so this always attempts at least one probe rather than re-checking the blocked
    // flags itself and deciding not to bother: probeForRestoredLANAccess is the
    // single source of truth for whether a probe is warranted; this only makes sure
    // it gets called.
    private func drainPendingBlockedProbe() {
        guard let trigger = pendingBlockedProbeTrigger else { return }
        pendingBlockedProbeTrigger = nil
        Task { [weak self] in
            await self?.probeForRestoredLANAccess(trigger: "\(trigger), deferred")
        }
    }

    // 'updatingStatus' must be false when called from the app-termination path.
    //
    // applicationWillTerminate blocks the main thread while it waits for this to
    // finish — it has to, or the process exits before the byebye datagrams are
    // sent. A MainActor hop in here would therefore deadlock against that wait:
    // the main thread is parked on a semaphore that can only be signaled by work
    // which is itself queued behind the main thread. The observable symptom is the
    // one that led to this parameter existing — the entire shutdown sequence
    // silently doing nothing, including the byebye the whole path exists to send.
    // There is no UI left to update at termination anyway.
    func stop(updatingStatus: Bool = true) async {
        guard isRunning else { return }
        Self.log("Stopping server…")

        rescanTask?.cancel()
        rescanTask = nil
        folderWatcher?.stop()
        folderWatcher = nil
        watchedPaths = []
        isUsingFallbackPolling = nil
        isWatcherHealthy = true
        stopPathMonitor()
        lastPathSatisfied = nil
        stopHealthWatchdog()
        selfCheckTask?.cancel()
        selfCheckTask = nil

        // SSDP first: tell clients the device is going away while the HTTP side can
        // still answer any last in-flight request.
        await ssdpResponder.stop()
        await httpServer.stop()

        isRunning = false
        // Both witnesses are silenced along with the server they were watching;
        // clearing only the published flag would leave them latched, and the warning
        // would then never reappear on the next start.
        discoveryBlockedByTraffic = false
        discoveryBlockedBySelfCheck = false
        stopBlockedRecoveryLoop()
        if updatingStatus {
            await MainActor.run {
                status.state = .stopped
                status.address = nil
                // A stopped server sends nothing, so there is no longer any evidence
                // for the warning. Leaving it up would blame System Settings for a
                // silence the user asked for.
                //
                // The three mirrors are cleared alongside it. They are documented as
                // reflecting the witnesses above, and clearing only the published
                // verdict left them latched at whatever they said when the server
                // stopped. Nothing reads them without checking isLocalNetworkBlocked
                // first, so this is not a live bug — but an invariant that holds only
                // because every current reader happens to guard on something else is
                // one bad refactor away from being a real one.
                status.isLocalNetworkBlocked = false
                status.isLANBlockedByTrafficWitness = false
                status.isLANBlockedBySelfCheckWitness = false
                status.isTrafficWitnessLive = false
                status.activePort = nil
                status.preferredPort = nil
                // Nothing can still be streaming through a listener that has been
                // torn down; leaving a stale count would keep the menu bar showing
                // the "serving" glyph over a stopped server.
                status.resetStreamCount()
            }
        }
        Self.log("Server stopped.")
    }

    // Restarts the network layer in place, used when the port changes and by the
    // recovery path when the listener itself is gone.
    func restart() async {
        await stop()
        await start()
    }

    // Invoked by HTTPServer when its listener fails outside of startup.
    private func handleListenerLoss() async {
        guard isRunning else { return }
        Self.log("HTTP listener was lost while running — restarting the server.")
        await recover(reason: "the HTTP listener failed while the server was running",
                      force: true)
    }

    // MARK: - Self-healing
    // The single entry point every automatic repair goes through: wake from sleep,
    // an interface returning, an address change, a discovery fault, a failed
    // self-check, a listener that died. Funnelling them all here is what makes the
    // behavior predictable — one recovery at a time, one cooldown, one retry ladder,
    // and one place in the log to read the whole story from.
    //
    // The repair is graduated. Discovery breaking does not justify tearing down a
    // listener that is streaming a film: only a listener that is genuinely no longer
    // accepting connections gets the full restart. 'force' is for triggers that are
    // authoritative about something having changed underneath us (wake, an address
    // change, an interface returning) and must not be swallowed by the cooldown.
    func recover(reason: String, force: Bool = false) async {
        if isRecovering {
            Self.log("SELF-HEAL SUPPRESSED: a recovery is already in progress; the "
                + "request triggered by \(reason) is almost certainly the same event "
                + "observed a second way and is being dropped.")
            return
        }
        if !force, let last = lastRecoveryAt {
            let since = Date().timeIntervalSince(last)
            if since < Self.recoveryCooldown {
                Self.log("SELF-HEAL SUPPRESSED: \(reason), but the last recovery was "
                    + since.fixed(0)
                    + "s ago and the cooldown is \(Int(Self.recoveryCooldown))s. "
                    + "Not rebuilding again yet; the retry ladder will pick this up if "
                    + "the fault persists.")
                scheduleRetry(reason: reason)
                return
            }
        }

        isRecovering = true
        lastRecoveryAt = Date()
        // Runs on every exit path below, success or failure alike: whichever probe
        // arrived while this recovery was running is owed an answer regardless of how
        // the recovery itself turned out, and drainPendingBlockedProbe re-checks the
        // blocked verdict itself, so a recovery that happened to clear it is handled
        // correctly too.
        defer {
            isRecovering = false
            drainPendingBlockedProbe()
        }

        Self.log("SELF-HEAL: beginning recovery because \(reason).")

        guard isRunning else {
            Self.log("SELF-HEAL: the server is not running, so this is a full start.")
            await start()
            return
        }

        // 1. Is the TCP side still real? This is the question that decides between a
        // cheap discovery rebuild and a disruptive full restart, and it is asked of
        // the listener's observed state rather than inferred from anything else.
        let listenerReady = await httpServer.isListenerReady()
        guard listenerReady else {
            let streams = await httpServer.activeStreams.count
            Self.log("SELF-HEAL: the HTTP listener is not accepting connections — a "
                + "full restart is required. \(streams) transfer(s) in flight will be "
                + "interrupted; there is no way to preserve them across a rebind.")
            await restart()
            return
        }

        // 2. The TCP side is fine, so only discovery is rebuilt. The listener keeps
        // running throughout and any playback in progress is undisturbed.
        let boundPort = await currentBoundPort()
        let currentAddress = NetworkInterface.primaryIPv4Address()
        let previousAddress = lastAdvertisedAddress
        lastAdvertisedAddress = currentAddress
        let address = currentAddress.map { "http://\($0):\(boundPort)" }
        await MainActor.run { status.address = address }

        guard currentAddress != nil else {
            Self.log("SELF-HEAL DEFERRED: this machine has no usable IPv4 address right "
                + "now, so there is nothing to advertise. The HTTP listener is still up "
                + "on port \(boundPort); discovery will be rebuilt as soon as an "
                + "address appears.")
            await MainActor.run {
                status.state = .failed("No network address — waiting")
            }
            scheduleRetry(reason: "no usable IPv4 address during recovery")
            return
        }

        Self.log("SELF-HEAL: rebuilding discovery on port \(boundPort) "
            + "(address \(previousAddress ?? "none") → \(currentAddress ?? "none")). "
            + "The HTTP listener is untouched.")

        // No byebye: it would have to be sent from an address that may no longer
        // exist, and the alive burst that follows tells clients everything anyway.
        await ssdpResponder.stop(sendingGoodbye: false)
        do {
            try await ssdpResponder.start(httpPort: boundPort)
        } catch {
            let text = Self.describe(startError: error)
            Self.log("ERROR: SELF-HEAL FAILED to restart discovery: \(text). The server "
                + "is still serving over HTTP at \(address ?? "an unknown address") but "
                + "cannot be discovered.")
            await MainActor.run { status.state = .failed(text) }
            scheduleRetry(reason: "discovery could not be restarted: \(text)")
            return
        }

        await MainActor.run { status.state = .running }
        Self.log("SELF-HEAL COMPLETE: discovery is running again at "
            + "\(address ?? "an unknown address").")
        clearRetrySchedule(reason: "recovery succeeded")
        // Idempotent, and needed: a start() whose discovery half failed returns
        // before it reaches its own startHealthWatchdog, and this branch is how
        // that server is brought back — so without this line a server recovered
        // from a discovery failure at launch ran with no level-triggered backstop
        // for the rest of the session.
        startHealthWatchdog()
        scheduleSelfCheck(baseAddress: address)
    }

    // MARK: - Retry ladder
    // Why this exists at all: before it, every automatic retry in the app hung off
    // NWPathMonitor, which fires on a CHANGE of network path. The two commonest
    // startup failures — the port briefly held by another process, and discovery
    // refused by Local Network privacy — both happen on a network that is already up
    // and never changes again. Nothing fired, nothing retried, and the app sat in a
    // failed state indefinitely with a perfectly good network in front of it.
    private func scheduleRetry(reason: String) {
        guard retryTask == nil else {
            Self.log("A recovery retry is already scheduled; not scheduling another "
                + "for: \(reason).")
            return
        }
        let index = min(retryAttempt, Self.recoveryRetryDelays.count - 1)
        let delay = Self.recoveryRetryDelays[index]
        retryAttempt += 1
        Self.log("RETRY SCHEDULED (attempt \(retryAttempt), in \(delay)): \(reason).")

        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            await self.runScheduledRetry(reason: reason)
        }
    }

    private func runScheduledRetry(reason: String) async {
        // Cleared first: the recovery below may itself call stop(), which cancels
        // this handle, and a task that cancels itself mid-flight is a needless way
        // to lose the rest of the attempt.
        retryTask = nil
        Self.log("RETRY (attempt \(retryAttempt)) now running for: \(reason).")
        await recover(reason: "scheduled retry \(retryAttempt) after: \(reason)",
                      force: true)
    }

    private func clearRetrySchedule(reason: String) {
        if retryTask != nil || retryAttempt > 0 {
            Self.log("Clearing the recovery retry ladder (was at attempt "
                + "\(retryAttempt)) because \(reason).")
        }
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
    }

    // MARK: - Health watchdog
    // Everything else in this file is edge-triggered: something reports a failure
    // and a repair follows. That leaves the class of faults nobody reports — a
    // monitor that stopped delivering, a listener that went away without its
    // handler firing, a filesystem watcher that is no longer installed. This is the
    // level-triggered backstop, and it is also the only routine "the server is fine"
    // evidence the log ever contains, which is what makes a gap in the log readable
    // later as an outage rather than as an absence of interest.
    private func startHealthWatchdog() {
        guard healthWatchdogTask == nil else { return }
        healthWatchdogTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: DLNAServer.healthWatchdogInterval) }
                catch { return }
                guard let self else { return }
                tick += 1
                await self.runHealthCheck(tick: tick)
            }
        }
        Self.log("Health watchdog started (every \(Self.healthWatchdogInterval)).")
    }

    private func stopHealthWatchdog() {
        healthWatchdogTask?.cancel()
        healthWatchdogTask = nil
    }

    private func runHealthCheck(tick: Int) async {
        guard isRunning, !isRecovering else { return }

        if pathMonitor == nil {
            Self.log("HEALTH: the network path monitor is not installed while the "
                + "server is running — reinstalling it. Without it, address changes "
                + "and interface outages would go unnoticed.")
            startPathMonitor()
        }

        if !watchedPaths.isEmpty && folderWatcher == nil {
            Self.log("HEALTH: \(watchedPaths.count) folder(s) are marked as watched but "
                + "no filesystem watcher exists — change detection is dead. Forcing a "
                + "rescan to reinstall it.")
            watchedPaths = []
            await rescan()
        }

        // Checked on EVERY tick rather than only on the half-hourly routine line: a
        // folder that is being served without a grant behind it serves nothing, and
        // waiting up to thirty minutes to say so would let the log's most useful
        // sandbox signal arrive long after the player had already given up. Silent
        // unless the books actually fail to balance.
        let scopeProblem = await MainActor.run { folderStore.securityScopeProblem }
        if let scopeProblem {
            Self.log("HEALTH: \(scopeProblem)")
        }

        let listenerReady = await httpServer.isListenerReady()
        guard listenerReady else {
            Self.log("HEALTH: the HTTP listener is not ready although the server "
                + "believes it is running, and no failure callback arrived. Recovering.")
            await recover(reason: "the health watchdog found the HTTP listener down",
                          force: true)
            return
        }

        // Routine confirmation, kept sparse: once every thirty ticks is half-hourly.
        if tick % 30 == 0 {
            let port = await httpServer.port
            let connections = await httpServer.connectionCount
            let streams = await httpServer.activeStreams.count
            let portText: String = port.map(String.init) ?? "?"
            let addressText: String = lastAdvertisedAddress ?? "no address"
            let watcherText: String = isWatcherHealthy
                ? "."
                : " (WATCHER FAILED — polling instead)."
            // Read on the main actor, where FolderStore lives. Included in every
            // routine health line because a scope leak or a missed acquisition is
            // invisible until something tries to read a file, and this is the only
            // place the discrepancy shows up before a player notices it.
            let scopeAudit = await MainActor.run { folderStore.securityScopeAudit }
            var line = "HEALTH OK: listening on port \(portText), "
            line += "advertising \(addressText), "
            line += "\(connections) connection(s), \(streams) transfer(s) in flight, "
            line += "watching \(watchedPaths.count) folder(s)"
            line += watcherText
            line += " \(scopeAudit)."
            Self.log(line)
        }
    }

    // MARK: - Sleep and wake
    // The gap this closes: on wake, a Mac routinely brings interfaces back with the
    // same IP address it had before. NWPathMonitor reports a satisfied path, the
    // address comparison finds nothing changed, and every check in the app passes —
    // while the multicast membership and, often, the listener's sockets did not
    // survive. The app looks healthy and is unreachable, which is the exact failure
    // shape the rest of this file was written to eliminate.
    func handleSystemWillSleep() {
        sleptAt = Date()
        Self.log("System is going to sleep. Sockets and multicast membership are not "
            + "expected to survive; the wake handler will rebuild the network layer.")
    }

    func handleSystemDidWake() async {
        let wokeAt = Date()
        let sleepDuration = sleptAt.map { wokeAt.timeIntervalSince($0) }
        sleptAt = nil
        let describedSleep = sleepDuration.map { $0.fixed(0) + "s" } ?? "unknown"
        Self.log("System woke from sleep (asleep for \(describedSleep)). Rebuilding the "
            + "network layer without waiting for anything to report a failure.")

        // Interfaces come back a moment after the wake notification, and rebuilding
        // into a half-configured stack only produces a second recovery. This delay is
        // short enough to be invisible and long enough to catch the common case.
        try? await Task.sleep(for: .seconds(3))

        // The interface returning is itself observed by the path monitor, whose up
        // edge triggers the same rebuild — measured at 1.7 s ahead of this handler on
        // a real sleep/wake cycle. Repeating it would withdraw and re-announce a
        // device that was already correctly announced a moment earlier, so the wake
        // handler stands down when the work is already done. The cooldown cannot do
        // this job: wake is deliberately a forced trigger, because the case where
        // NOTHING else notices the wake is exactly the one this handler exists for.
        if let last = lastRecoveryAt, last > wokeAt {
            Self.log("Wake recovery not needed: the network layer was already rebuilt "
                + Date().timeIntervalSince(last).fixed(1)
                + "s ago, after this wake, by another trigger. Re-indexing only.")
            await rescan()
            return
        }

        await recover(reason: "the machine woke from sleep (asleep \(describedSleep))",
                      force: true)
        // The index is re-walked as well: files may have been added by another host,
        // and network volumes are frequently remounted across a sleep.
        await rescan()
    }

    // MARK: - Content refresh
    // Rebuilds the index from the current folder list and pushes counts to the UI.
    // Called at startup, whenever the folder list changes, and on the rescan timer.
    func rescan() async {
        if isRescanning {
            rescanRequestedWhileRunning = true
            return
        }
        isRescanning = true
        defer { isRescanning = false }

        await performRescan()

        // Drain any request that arrived while the scan above was in flight.
        while rescanRequestedWhileRunning {
            rescanRequestedWhileRunning = false
            await performRescan()
        }
    }

    private func performRescan() async {
        // Three hops, and the split is the point: read the list on the main actor,
        // do the blocking filesystem work off it, apply the results back. Resolving
        // inside the MainActor.run block — the obvious one-liner — parks the UI for
        // the duration of every mount timeout the machine is willing to wait out.
        let folders = await MainActor.run { folderStore.folders }

        let outcome = await Task.detached(priority: .utility) {
            FolderStore.resolveAll(folders)
        }.value

        await MainActor.run { folderStore.applyResolution(outcome) }

        // Re-point the watcher at whatever is currently reachable. Folders come and
        // go as drives mount and unmount, and a watcher left pointing at a path that
        // no longer exists reports nothing.
        refreshChangeDetection(for: outcome.reachable)

        let unreachableNames = outcome.unreachable.map(\.displayName)
        let result = await contentIndex.rebuild(from: outcome.reachable)

        await MainActor.run {
            folderStore.applyFileCounts(result.fileCountsByFolderID)
            status.fileCount = result.fileCount
            // The reachable subset only. This deliberately reports fewer folders than
            // the user configured when a drive is missing, because everything that
            // consumes this count — the menu's summary line and the folders tab's
            // status line — is answering "what can a player get right now", and the
            // unreachable ones are not part of that answer. What is missing is
            // reported separately and explicitly from unreachableFolders, so nothing
            // is hidden by the smaller number; it is simply told in the right place.
            status.folderCount = outcome.reachable.count
            status.unreachableFolders = unreachableNames
        }
    }

    // Media transfers currently in flight. Used by the confirmations that would
    // interrupt them: changing the port and quitting.
    func activeStreams() async -> [HTTPServer.ActiveStream] {
        await httpServer.activeStreams
    }

    // Forwards a changed announcement interval to the discovery responder.
    func announcementIntervalChanged() async {
        await ssdpResponder.announcementIntervalChanged()
    }

    // Republishes the device under a new name.
    //
    // Simply writing the preference is not enough, because nothing re-reads it on its
    // own. The name appears in two places that are produced at different times:
    //
    //   • The description document, built per request — so a client that re-fetches
    //     sees the new name immediately. The catch is that a client has no reason to
    //     re-fetch: it cached the description at discovery time and will keep the old
    //     name indefinitely.
    //   • The root container's title in the content index, which is built once per
    //     scan and would otherwise keep the old name until the next folder change.
    //
    // So the index is rebuilt and the device is retracted and re-announced. The
    // byebye/alive pair is what makes clients drop the cached entry and fetch the
    // description again, which is the only way the new name actually reaches them.
    // The HTTP listener is untouched, so anything currently playing keeps playing.
    func friendlyNameChanged() async {
        guard isRunning else { return }
        Self.log("Server name changed to \"\(Preferences.friendlyName)\" — rebuilding the "
            + "index and re-announcing so clients pick it up.")
        await rescan()

        let boundPort = await currentBoundPort()
        await ssdpResponder.stop(sendingGoodbye: true)
        do {
            try await ssdpResponder.start(httpPort: boundPort)
        } catch {
            let text = Self.describe(startError: error)
            Self.log("ERROR: could not re-announce after the name change: \(text).")
            scheduleRetry(reason: "discovery failed to restart after a name change")
        }
    }

    // MARK: - Network change handling
    // Without this, two entirely ordinary events silently break the server until it
    // is manually restarted:
    //
    //   • The Mac's IP address changes (router reboot, new DHCP lease). Every
    //     already-announced LOCATION now points at an address nobody answers on,
    //     and the next unprompted re-announcement is up to fifteen minutes away.
    //     The HTTP side is unaffected — it derives URLs per connection — but a
    //     player that cannot fetch the description never gets that far.
    //   • The network is not up yet at login. The listener sits in .waiting, the
    //     start times out, and the server stays failed forever on a machine that
    //     acquired a perfectly good address two seconds later.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.handlePathUpdate(satisfied: path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "app.LANStream.path", qos: .utility))
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func handlePathUpdate(satisfied: Bool) async {
        let previouslySatisfied = lastPathSatisfied
        lastPathSatisfied = satisfied

        guard satisfied else {
            // Logged with the address that is now stale, because the pair of lines
            // either side of an outage is what makes its length and its effect
            // readable in the log afterwards.
            Self.log("Network path became unsatisfied — this machine currently has no "
                + "usable interface. The advertisement for "
                + "\(lastAdvertisedAddress ?? "no address") is now stale; discovery "
                + "will be rebuilt when a path returns.")
            return
        }

        if !isRunning {
            // Covers the login-before-network case: a failed start is retried once
            // the machine actually has a usable path.
            Self.log("Network became available while the server was down — starting.")
            await start()
            return
        }

        // The up edge of an outage, handled BEFORE the address comparison and
        // deliberately independent of it. An interface that drops and returns on the
        // same DHCP lease leaves the address identical while multicast membership is
        // gone — the old code compared addresses, found no change, returned, and the
        // server stayed invisible with nothing in the log to say why.
        if previouslySatisfied == false {
            Self.log("Network path became satisfied again after an outage. Rebuilding "
                + "discovery regardless of whether the address changed: multicast group "
                + "membership is a property of the interface and does not survive one "
                + "going away.")
            await recover(reason: "the network path returned after an outage",
                          force: true)
            return
        }

        let currentAddress = NetworkInterface.primaryIPv4Address()
        guard currentAddress != lastAdvertisedAddress else { return }

        // An address change is the other moment the advertisement can silently go
        // wrong — a new interface, a VPN, a DHCP lease on a network that filters
        // multicast — and it is repaired the same way everything else is: discovery
        // is rebuilt (which also rejoins the group on the new interface), the HTTP
        // listener is left alone so playback continues, and the result is verified
        // from the outside.
        await recover(reason: "the local address changed "
                      + "(\(lastAdvertisedAddress ?? "none") → "
                      + "\(currentAddress ?? "none"))",
                      force: true)
    }

    // MARK: - Change detection
    // Installs the filesystem watcher over every reachable shared folder, and
    // starts the slow fallback timer only if at least one of them lives on a
    // remote volume where the watcher cannot work.
    private func refreshChangeDetection(for folders: [FolderStore.ResolvedFolder]) {
        let paths = folders.map { $0.url.path(percentEncoded: false) }.sorted()

        // Reinstall only when the set of folders actually changed. This method runs
        // after every rescan, and since a rescan is usually CAUSED by the watcher,
        // restarting the stream each time would tear down and rebuild it on every
        // file change — churning the event stream and leaving a window during which
        // further changes go unseen.
        // Reinstalled when the folder set changes, and also whenever the previous
        // install FAILED — otherwise a watcher that could not be created stayed
        // broken for the lifetime of the process, because watchedPaths had already
        // been updated to the set it was never actually watching.
        if paths != watchedPaths || !isWatcherHealthy {
            if folderWatcher == nil {
                folderWatcher = FolderWatcher { [weak self] in
                    Task { await self?.rescan() }
                }
            }
            let installed = folderWatcher?.start(watching: paths) ?? false
            if installed && !isWatcherHealthy {
                Self.log("Filesystem watching recovered — events are being delivered "
                    + "again for \(paths.count) folder(s).")
            }
            isWatcherHealthy = installed
            watchedPaths = paths
        }

        let remoteFolders = folders.filter { !VolumeLocality.isLocal($0.url) }
        // The fallback timer also covers a watcher that could not be installed. It
        // used to key on remote volumes alone, so a failed FSEvents install over
        // purely local folders left the index with neither events nor polling: new
        // films silently never appeared, and the log's promise of "falling back to
        // periodic rescans" was not kept by anything.
        let needsFallback = !remoteFolders.isEmpty || !isWatcherHealthy

        // Log the mode only when it changes, so the reason for the current
        // behavior is recorded once rather than repeated on every rescan.
        if isUsingFallbackPolling != needsFallback {
            if needsFallback {
                var causes: [String] = []
                if !remoteFolders.isEmpty {
                    causes.append("folder(s) on remote volumes that cannot emit "
                        + "filesystem events ("
                        + remoteFolders.map(\.displayName).joined(separator: ", ") + ")")
                }
                if !isWatcherHealthy {
                    causes.append("the filesystem watcher could not be installed, so no "
                        + "events will arrive for ANY shared folder")
                }
                Self.log("Enabling the periodic fallback rescan every "
                    + "\(Self.remoteFallbackRescanInterval) because: "
                    + causes.joined(separator: "; ") + ".")
            } else {
                Self.log("All shared folders are on local volumes — no polling; changes are detected from filesystem events.")
            }
            isUsingFallbackPolling = needsFallback
        }

        if needsFallback {
            startFallbackRescanLoop()
        } else {
            rescanTask?.cancel()
            rescanTask = nil
        }
    }

    private func startFallbackRescanLoop() {
        guard rescanTask == nil else { return }
        rescanTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: DLNAServer.remoteFallbackRescanInterval)
                } catch {
                    return
                }
                await self?.rescan()
            }
        }
    }
}

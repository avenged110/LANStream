// MARK: - AppDelegate.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Application lifecycle: owns the shared state, the status item, and the server.

import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, Loggable {
    nonisolated static let logTag = "[AppDelegate]"

    // MARK: - Shared state
    let status = ServerStatus()
    let folderStore = FolderStore()

    private var server: DLNAServer!
    private var statusMenuController: StatusMenuController?
    // One subscription for every preference the server reacts to. The keys are
    // mutually exclusive, so a single sink dispatching on the key does exactly what
    // four separately-filtered subscriptions did, with one place to look for the
    // full list of what a preference change is expected to cause.
    private var preferencesCancellable: AnyCancellable?
    // Workspace observers: volume mount/unmount/rename, plus sleep and wake. All
    // removed together at termination.
    private var volumeObservers: [any NSObjectProtocol] = []

    // MARK: - Single-instance enforcement
    // Returns the instance that owns the single-instance slot, or nil when that is
    // this process and it may proceed.
    //
    // "First one found wins" is not sufficient, because the two launches can be
    // simultaneous — a login item firing at the same moment the user double-clicks
    // the app, or two copies started from a script. Both processes then see each
    // other in the running-applications list, both conclude they are the duplicate,
    // and both quit, leaving no server running at all. That failure is silent and
    // intermittent, which makes it the worst possible kind.
    //
    // Launch order is therefore the tie-break, and it is total: the older process
    // always wins, and if the launch dates are equal or unavailable the lower pid
    // wins. Every participant evaluates the same ordering and exactly one of them
    // finds no older instance.
    private static func olderRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownLaunch = NSRunningApplication.current.launchDate

        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ownPID && !$0.isTerminated }
            .first { other in
                guard let otherLaunch = other.launchDate, let ownLaunch else {
                    return other.processIdentifier < ownPID
                }
                if otherLaunch != ownLaunch { return otherLaunch < ownLaunch }
                return other.processIdentifier < ownPID
            }
    }

    // An .accessory app has no Dock icon and no window, so activating the existing
    // instance produces no visible effect whatsoever. Without this alert, launching
    // LAN Stream a second time does nothing at all from the user's point of view —
    // indistinguishable from the app being broken, and the exact situation where
    // someone starts double-clicking harder.
    //
    // It also gives the one genuinely awkward case a name: an instance that is
    // wedged or still shutting down holds the slot and blocks every new launch, and
    // naming its pid is what turns "the app won't start" into something actionable.
    private static func presentAlreadyRunningAlert(otherPID: pid_t) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "LAN Stream Is Already Running"
        alert.informativeText = "Another copy of LAN Stream (process \(otherPID)) is "
            + "already running on this Mac, so this one will quit. Only one copy can "
            + "run at a time — two would advertise the same device to the network and "
            + "answer players with conflicting content.\n\nLook for the LAN Stream icon "
            + "in the menu bar. If there is no icon there, the existing copy is not "
            + "responding and should be quit with Activity Monitor before trying again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Launch
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install the shared logging backend before the first log line. LAN Stream's
        // log lives in the sandbox container's Application Support, is gated on
        // Preferences.loggingEnabled, and keeps its millisecond timestamps (the
        // shared default is seconds) so a burst of request lines inside one second
        // still reads in order.
        Logger.bootstrap(.init(fileName: "LANStream.log",
                               destination: .applicationSupport,
                               isEnabled: { Preferences.loggingEnabled },
                               timestampFormat: "yyyy-MM-dd'T'HH:mm:ss.SSS"))

        // A second copy of LAN Stream would bind the same TCP port and join the same
        // multicast group as the first. Network.framework permits it — the listener
        // sets allowLocalEndpointReuse so that quitting and relaunching does not have
        // to wait out TIME_WAIT — so the two instances would coexist, splitting
        // incoming requests between two different content indexes and answering the
        // same searches twice with conflicting data. The symptom would be a device
        // that intermittently shows the wrong contents, with nothing in either log to
        // explain it. (Info.plist's LSMultipleInstancesProhibited is not available
        // through Xcode's generated-plist build settings, so the check lives here.)
        if let existing = Self.olderRunningInstance() {
            Self.log("Another instance of LAN Stream is already running "
                + "(pid \(existing.processIdentifier)) — this one is exiting.")
            existing.activate()
            Self.presentAlreadyRunningAlert(otherPID: existing.processIdentifier)
            NSApp.terminate(nil)
            return
        }


        Preferences.registerDefaults()
        // After the preference defaults are registered, since it reads the
        // logging-enabled predicate: forces the log directory and file into
        // existence so the settings window's monitor has something to watch.
        Logger.prepareLogDirectory()

        // Menu-bar-only: no Dock icon, no application menu. LSUIElement in the
        // Info.plist covers this at launch; setting it explicitly also covers the
        // case of the app being launched by the login-items mechanism, which has
        // been observed to start apps with the regular policy in some macOS builds.
        NSApp.setActivationPolicy(.accessory)

        Self.log("LAN Stream starting. Bundle version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"), UDN uuid:\(Preferences.serverUUID).")
        // Logged immediately after the version, and before anything can fail, because
        // every filesystem symptom in this app reads differently depending on the
        // answer. "The folder is unreachable" means a missing drive outside the
        // sandbox and can mean a lapsed grant inside it, and no later line in the
        // file can establish which world it was written in.
        Self.log(SandboxEnvironment.startupSummary(logFileURL: Logger.safeLogFileURL))

        server = DLNAServer(status: status, folderStore: folderStore)
        statusMenuController = StatusMenuController(status: status,
                                                    folderStore: folderStore,
                                                    server: server)

        // Every preference the server has to react to, in one place.
        //
        //   • Shared folders and container formats both change WHICH FILES EXIST as
        //     far as a client is concerned, so both trigger an immediate rescan
        //     rather than waiting for the periodic one — adding a folder or widening
        //     the whitelist shows up on the player within seconds.
        //   • The announcement interval takes effect immediately rather than at the
        //     next scheduled announcement, so the user can see the effect of the
        //     setting while they are still looking at it.
        //   • The name has to be republished; see friendlyNameChanged for why simply
        //     writing the preference is not enough to reach a client that has
        //     already cached the description.
        preferencesCancellable = Preferences.preferencesChanged
            .sink { [weak self] key in
                guard let self else { return }
                switch key {
                case Preferences.Keys.sharedFolders, Preferences.Keys.containerFormats:
                    Task { await self.server.rescan() }
                case Preferences.Keys.announceInterval:
                    Task { await self.server.announcementIntervalChanged() }
                case Preferences.Keys.friendlyName:
                    Task { await self.server.friendlyNameChanged() }
                default:
                    break
                }
            }

        // Volume mount and unmount are the one class of change the filesystem
        // watcher structurally cannot report.
        //
        // FSEvents is installed over the paths that were reachable at the time. When
        // a drive is ejected those paths stop existing, the watcher is reinstalled
        // over an empty set, and nothing is left listening — so when the drive comes
        // back there is no event, no rescan, and the folder stays permanently marked
        // unavailable. Before these observers existed, "Rescan Now" was the only way
        // out of that state, which is precisely why it could not simply be deleted
        // from the menu. NSWorkspace's volume notifications close the gap: a rescan
        // on mount re-resolves the bookmarks and reinstalls the watcher, and one on
        // unmount drops the vanished content promptly instead of advertising files
        // that can no longer be read.
        // Granting Local Network access sends the user out to System Settings and
        // then straight back here. That return is the single best moment to re-test
        // it — better than any timer, because it means they have finished doing
        // whatever they left to do. DLNAServer ignores this unless it is actually in
        // the blocked state, and rate-limits it, so a user who simply clicks around
        // costs nothing.
        volumeObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main) { [weak self] notification in
                    let activated = notification.userInfo?[
                        NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard activated?.processIdentifier
                        == ProcessInfo.processInfo.processIdentifier else { return }
                    Task { @MainActor in
                        guard let self, let server = self.server else { return }
                        await server.checkForRestoredLANAccess()
                    }
                })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    guard let self else { return }
                    let volume = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey]
                                  as? URL)?.lastPathComponent ?? "a volume"
                    Self.log("Volume change (\(name.rawValue)) for \(volume) — rescanning.")
                    Task { await self.server.rescan() }
                })
        }

        // Sleep and wake. These are NOT covered by the network path monitor: a Mac
        // typically wakes with the same IP address it slept with, so the monitor
        // reports a satisfied path, the address comparison finds no change, and
        // nothing anywhere concludes that anything happened — while the multicast
        // membership, and often the listener's sockets, did not survive the sleep.
        // The result is an app that looks entirely healthy in the menu bar and in
        // the log, and is invisible to every player on the network until it is
        // manually restarted. These two notifications are the only reliable signal
        // that the event occurred at all.
        //
        // NSWorkspace's notification center is the correct source; the ordinary
        // NotificationCenter does not carry them.
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.didWakeNotification] {
            volumeObservers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    guard let self else { return }
                    if name == NSWorkspace.willSleepNotification {
                        Task { await self.server.handleSystemWillSleep() }
                    } else {
                        Task { await self.server.handleSystemDidWake() }
                    }
                })
        }

        Task { await server.start() }
    }

    // MARK: - Quit confirmation
    // Set once the user has confirmed, so the second pass through this method
    // (after reply(toApplicationShouldTerminate:)) does not ask again.
    private var hasConfirmedQuit = false
    // True while the confirmation is on screen. Guards against a second quit
    // request — a second menu click, or ⌘Q while the sheet is up — stacking another
    // alert on top of the first and leaving one of them unanswerable.
    private var isQuitPromptShowing = false
    // Set once the asynchronous shutdown below has finished. AppKit can call
    // applicationShouldTerminate more than once, and the second pass must let the
    // process go rather than starting the teardown again.
    private var hasCompletedTeardown = false

    // Quitting tears down the listener and drops every transfer in flight, so if
    // somebody is part-way through a film they lose their place with no warning.
    // The check has to be asynchronous — the stream registry lives inside an actor —
    // which is what .terminateLater is for: AppKit suspends the quit and waits for
    // reply(toApplicationShouldTerminate:).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Shutdown already ran to completion on an earlier pass.
        if hasCompletedTeardown { return .terminateNow }
        // A prompt or the shutdown itself is already in flight.
        if isQuitPromptShowing { return .terminateLater }
        isQuitPromptShowing = true

        Task { @MainActor in
            // Confirm first, when there is something to interrupt.
            if let server, !hasConfirmedQuit {
                // Bounded query. Everything downstream of a hung actor would
                // otherwise leave the app permanently unquittable, which is a far
                // worse outcome than interrupting a transfer — so a check that does
                // not answer promptly is treated as "nothing playing".
                let streams = await Self.activeStreamsOrEmpty(from: server,
                                                              timeout: .seconds(2))
                if !streams.isEmpty {
                    Self.log("Quit requested with \(streams.count) transfer(s) in flight — asking for confirmation.")

                    let proceed = await ClientActivity.confirm(
                        title: streams.count == 1
                            ? "Active Stream In-Progress"
                            : "\(streams.count) Active Streams In-Progress",
                        message: ClientActivity.describe(streams)
                            + "\n\nQuitting LAN Stream will stop playback.",
                        proceedButton: "Quit Anyway",
                        isDestructive: true,
                        attachedTo: settingsWindowIfVisible())

                    Self.log(proceed ? "User confirmed quit." : "User canceled quit.")
                    guard proceed else {
                        isQuitPromptShowing = false
                        NSApp.reply(toApplicationShouldTerminate: false)
                        return
                    }
                }
            }
            hasConfirmedQuit = true

            // Released HERE, on the main actor, rather than in
            // applicationWillTerminate where it used to live. That method runs after
            // this one has replied, by which point the shutdown below has already
            // flushed and stopped the logger — so the release happened but its log
            // line was written into a buffer nothing would ever drain again, and the
            // clean teardown this is supposed to record was invisible in every log
            // ending in a normal quit. The backstop in applicationWillTerminate stays
            // for the paths that never reach this point; relinquishing is idempotent.
            folderStore.relinquishAllScopes(reason: "the application is quitting")

            // The shutdown runs HERE, awaited on the main actor, rather than in
            // applicationWillTerminate behind a DispatchSemaphore.
            //
            // That semaphore blocked the main thread — running at user-interactive
            // QoS — on a detached Task that runs no higher than user-initiated. The
            // runtime flagged it as a priority inversion on every quit. Swift
            // Concurrency has no user-interactive task priority, so no amount of
            // tuning the worker's priority removes the inversion; the fix is to stop
            // blocking a thread on it at all. Returning .terminateLater and replying
            // when the work is done is AppKit's supported way to do exactly that,
            // and it is the same mechanism the confirmation above already uses.
            await Self.runWithTimeout(.seconds(3)) { [server] in
                // logAwaiting rather than log: the ordinary fire-and-forget path
                // spawns a task that races the shutdown flush, and on the
                // termination path that race is reliably lost — the final messages,
                // the ones that explain why the app stopped, are exactly the ones
                // that go missing.
                await Logger.logAwaiting("Terminating — stopping server and flushing log.",
                                         cName: AppDelegate.logTag)
                await server?.stop(updatingStatus: false)

                // Give fire-and-forget log calls made during teardown (inside the
                // server actors, which log through the normal path) a moment to
                // reach LoggerCore before its buffer is flushed and discarded.
                try? await Task.sleep(for: .milliseconds(150))

                await Logger.shutdownLoggingAwaiting()
            }

            hasCompletedTeardown = true
            isQuitPromptShowing = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    // Runs 'work', abandoning the wait after 'timeout'. A hung network teardown
    // must never stop the app from quitting; the old semaphore had the same bound
    // and dropping it here would trade a priority inversion for an unquittable app.
    private static func runWithTimeout(_ timeout: Duration,
                                       _ work: @escaping @Sendable () async -> Void) async {
        let finished = await firstOf(timeout: timeout, fallback: false) {
            await work()
            return true
        }
        if !finished {
            Self.log("WARNING: Shutdown did not finish within \(timeout); quitting anyway.")
        }
    }

    // Races the stream query against a timeout, returning an empty list if the
    // server does not answer in time.
    private static func activeStreamsOrEmpty(
        from server: DLNAServer,
        timeout: Duration
    ) async -> [HTTPServer.ActiveStream] {
        let first: [HTTPServer.ActiveStream]? = await firstOf(timeout: timeout,
                                                              fallback: nil) {
            await server.activeStreams()
        }
        if first == nil {
            Self.log("WARNING: Timed out querying active transfers; allowing quit to proceed.")
        }
        return first ?? []
    }

    // Returns whichever comes first: 'work''s result, or 'fallback' once 'timeout'
    // has elapsed.
    //
    // Deliberately NOT a task group, which is what both callers above used to race
    // with. A task group cannot return until every child has finished, and
    // cancellation is only a request — a child suspended on an actor that never
    // answers ignores it. So in exactly the case these timeouts exist for, the
    // "timeout" child won and then the group sat waiting on the hung one forever,
    // leaving the app as unquittable as having no timeout at all. Two unstructured
    // tasks racing to resume one continuation return on the first answer; the loser
    // is simply left to finish, or not, on its own.
    private static func firstOf<T: Sendable>(
        timeout: Duration,
        fallback: T,
        _ work: @escaping @Sendable () async -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let resumeState = ResumeGuard()
            let workTask = Task {
                let value = await work()
                if resumeState.tryResume() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if resumeState.tryResume() {
                    workTask.cancel()
                    continuation.resume(returning: fallback)
                }
            }
        }
    }

    // The settings window when it is on screen, so the prompt appears as a sheet
    // attached to it rather than as a free-floating modal in front of it.
    private func settingsWindowIfVisible() -> NSWindow? {
        statusMenuController?.visibleSettingsWindow
    }

    // MARK: - Termination
    func applicationWillTerminate(_ notification: Notification) {
        // Pull the status item synchronously so the menu bar does not hold a stale
        // slot while the process unwinds.
        statusMenuController?.prepareForTerminationSynchronously()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in volumeObservers { workspaceCenter.removeObserver(observer) }
        volumeObservers.removeAll()

        // Release the folder grants explicitly rather than letting the process exit
        // out from under them, so the log ends with a clean, auditable teardown and
        // the final scope count can be checked against the opening one.
        folderStore.relinquishAllScopes(reason: "the application is terminating")

        // No semaphore and no blocking wait here any more. The server stop and log
        // flush — including the ssdp:byebye datagrams that keep this device from
        // lingering as a dead entry in a player's list — now complete in
        // applicationShouldTerminate before it replies, which is the only point in
        // the sequence where AppKit will actually wait for asynchronous work without
        // a thread being blocked on it.
        //
        // The fallback covers the paths that reach termination without that reply
        // ever happening. It is fire-and-forget by design: anything that blocks the
        // main thread here reintroduces the inversion this change removed.
        if !hasCompletedTeardown {
            Logger.log("Terminating without a completed shutdown — flushing the log.",
                       cName: AppDelegate.logTag)
            Logger.shutdownLogging()
        }
    }

    // The app has no windows of its own to keep it alive, and closing the settings
    // window must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

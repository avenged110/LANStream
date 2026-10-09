// MARK: - StatusMenuController.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The menu bar item and its menu.
//
// The status item, its glyph, and the menu are described here and handed to the
// shared MenuController (see "11.10 MenuControlKit.swift"), which owns the
// NSStatusItem, rebuilds the menu from this description on every open, routes its
// glyphs through the shared SymbolCache, and keeps the menu-bar icon current via
// the `observing:` closure — the same "assemble it the moment it becomes visible,
// so it can never be stale" model this file implemented by hand before.
//
// The two alert rows (blocked LAN traffic, fallback-port notice) stay here: they
// are `.action` handlers whose handlers, and the NSAlerts they raise, are app
// logic rather than menu chrome.

import AppKit
import SwiftUI

@MainActor
final class StatusMenuController: NSObject, Loggable {
    nonisolated static let logTag = "[StatusMenu]"

    private let status: ServerStatus
    private let folderStore: FolderStore
    private let server: DLNAServer

    private var menuController: MenuController!
    private var settings: SettingsWindowController?

    // The settings window only when it is actually on screen. Used by the quit
    // confirmation to decide between a sheet and a standalone modal.
    var visibleSettingsWindow: NSWindow? { settings?.visibleWindow }

    init(status: ServerStatus, folderStore: FolderStore, server: DLNAServer) {
        self.status = status
        self.folderStore = folderStore
        self.server = server
        super.init()

        menuController = MenuController(.init(
            appName: "LAN Stream",
            icon: { [weak self] in
                self?.currentIcon()
                    ?? .symbol(.menuBar("externaldrive.fill.badge.wifi"),
                               fallbackTitle: "LAN Stream")
            },
            elements: { [weak self] in self?.buildElements() ?? [] },
            // Keeps the menu bar glyph current WITHOUT the menu being opened, which
            // is the whole point of showing serving state there: the user glances
            // at the menu bar and knows a player is streaming, or that a drive
            // dropped out.
            observing: { [weak self] in
                guard let self else { return }
                _ = self.status.activeStreamCount
                _ = self.status.state
                _ = self.status.isLocalNetworkBlocked
                _ = self.status.isUsingFallbackPort
                _ = self.status.unreachableFolders
            },
            prewarmSymbols: [
                .menuBar("externaldrive.fill.badge.wifi"),
                .menuBar("externaldrive.fill.trianglebadge.exclamationmark"),
                .menuBar("externaldrive.fill.badge.xmark"),
                .menuBar("externaldrive.fill.badge.person.crop"),
                .menuBar("externaldrive.fill.badge.questionmark"),
            ]))
        menuController.install()
    }

    // Called from AppDelegate.applicationWillTerminate so the menu bar does not
    // hold a stale slot while the process unwinds.
    func prepareForTerminationSynchronously() {
        menuController.prepareForTerminationSynchronously()
    }

    // MARK: - Menu bar glyph
    // Strictly ordered, most severe first, because only one glyph can be shown and
    // the icon has to answer "what is the most important thing I should know". Each
    // rung supersedes everything below it:
    //
    //   1. trianglebadge.exclamationmark — LAN traffic blocked. Highest because it
    //      is the only condition where the app looks entirely healthy and is
    //      nonetheless invisible to every device on the network.
    //   2. badge.xmark — the server failed outright. Nothing is being served.
    //   3. badge.person.crop — a client is streaming right now. Outranks a missing
    //      folder deliberately: something is actively working, and a person
    //      watching a film needs the icon to mean "in use" before "a drive is
    //      unplugged".
    //   4. badge.questionmark — one or more shared folders cannot be read. A real
    //      problem, but a quiet one.
    //   5. badge.wifi — running and idle.
    private func currentIcon() -> MenuBarIcon {
        let symbolName: String
        let description: String
        switch status.state {
        case _ where status.isLocalNetworkBlocked:
            symbolName = "externaldrive.fill.trianglebadge.exclamationmark"
            description = "LAN Stream — LAN traffic blocked"
        case .failed:
            symbolName = "externaldrive.fill.badge.xmark"
            description = "LAN Stream — error"
        default:
            if status.isServingContent {
                symbolName = "externaldrive.fill.badge.person.crop"
                description = "LAN Stream — serving content"
            } else if status.unavailableFolderCount > 0 {
                symbolName = "externaldrive.fill.badge.questionmark"
                description = "LAN Stream — \(status.unavailableFolderPhrase)"
            } else {
                symbolName = "externaldrive.fill.badge.wifi"
                description = "LAN Stream"
            }
        }

        var tooltip = status.isLocalNetworkBlocked
            ? "LAN Stream — LAN traffic blocked"
            : "LAN Stream — \(status.summary)"
        if status.isServingContent {
            let count = status.activeStreamCount
            tooltip += count == 1 ? " (1 file playing)" : " (\(count) files playing)"
        }
        // Appended rather than substituted: when a drive is missing AND something is
        // playing, both are true and the tooltip is the one place with room to say so.
        if status.unavailableFolderCount > 0 {
            tooltip += " — \(status.unavailableFolderPhrase)"
        }

        return .symbol(.menuBar(symbolName),
                       accessibilityDescription: description,
                       toolTip: tooltip)
    }

    // MARK: - Menu contents
    // Re-evaluated by MenuController on every open, so a conditional row, a live
    // status string, and a checkmark that tracks a preference are all just this
    // closure returning something different.
    private func buildElements() -> [MenuElement] {
        var elements: [MenuElement] = []

        // MARK: Permission / notice warnings
        // Above everything else, including the status lines: when this is showing it
        // is the only thing on the menu that matters — the summary underneath will
        // cheerfully say "Serving 3 folders, 412 files" while not a single device on
        // the network can see any of them.
        var showedWarning = false
        if reconciledLocalNetworkBlocked() {
            elements.append(.action(id: "lanWarning",
                                    title: Self.localNetworkWarningMenuTitle,
                                    leadingSymbolName: "exclamationmark.triangle.fill") {
                [weak self] in self?.showLocalNetworkWarning()
            })
            showedWarning = true
            // Opening the menu while blocked is a deliberate act by someone who
            // probably just granted the permission. Re-test now rather than making
            // them wait out a backoff; the server rate-limits this and the result
            // lands on the next open.
            Task { [server] in await server.checkForRestoredLANAccess() }
        }
        // Second, because it is a notice rather than a fault: the server works, it
        // is simply not on the number the user picked.
        if status.isUsingFallbackPort, let activePort = status.activePort {
            let preferred = status.preferredPort ?? UInt16(Preferences.serverPort)
            elements.append(.action(id: "fallbackPort",
                                    title: "Port \(preferred) In Use — Using \(activePort)",
                                    leadingSymbolName: "exclamationmark.circle.fill") {
                [weak self] in self?.showFallbackPortNotice()
            })
            showedWarning = true
        }
        if showedWarning { elements.append(.separator) }

        // MARK: Status section
        // Ordered from identity outwards: what this server is called, where it can
        // be reached, what it is serving, and — only while it is happening — that
        // something is being played right now.
        elements.append(.info("Server name: \(Preferences.friendlyName)"))
        if let detail = status.detail {
            elements.append(.info(detail))
        }
        elements.append(.info(status.summary))
        // Directly beneath the count, because it is the thing that explains it:
        // the summary reports what can be served RIGHT NOW, so a missing folder
        // makes that number lower than the user expects and this is the line that
        // says why. Actionable — the one thing a user seeing it wants is the
        // folders tab, where the missing entry is named in red.
        if status.unavailableFolderCount > 0 {
            elements.append(.action(id: "unavailableFolders",
                                    title: status.unavailableFolderPhrase,
                                    symbolName: "externaldrive.fill.badge.questionmark",
                                    glyphPlacement: .leading,
                                    glyphColor: nil) {
                [weak self] in self?.openSettings("sharedFolders")
            })
        }
        // Last, and only while it applies. Informational, so it matches the
        // secondary status lines above it and never highlights.
        if status.activeStreamCount > 0 {
            elements.append(.info("Actively streaming",
                                  symbolName: "play.circle.fill",
                                  glyphPlacement: .leading,
                                  color: .secondaryLabelColor))
        }

        elements.append(.separator)

        // MARK: Navigation — each opens the settings window directly on its own tab.
        elements.append(.action(id: "sharedFolders", title: "Shared Folders…",
                                key: "s", modifiers: .command) {
            [weak self] in self?.openSettings("sharedFolders")
        })
        elements.append(.action(id: "settings", title: "Settings…",
                                key: ",", modifiers: .command) {
            [weak self] in self?.openSettings("general")
        })

        elements.append(.separator)

        // About is the standard macOS About panel, which renders the app icon,
        // name, version, and the GPL-3.0 text from Credits.html in the bundle's
        // Resources — there is no longer an About tab in the Settings window.
        elements.append(.action(id: "about", title: "About LAN Stream…",
                                key: "?", modifiers: .command) {
            [weak self] in self?.showAboutPanel()
        })

        elements.append(.separator)

        elements.append(.quit(title: "Quit LAN Stream"))

        return elements
    }

    // Decides, synchronously and before a single row is added, whether the blocked-
    // LAN warning has already been overtaken by events.
    //
    // The warning is held up by two independent witnesses OR-ed together, and they
    // do not learn at the same speed. After the permission is granted back there is
    // a stretch where the traffic witness already knows multicast is flowing again
    // and the self-check witness still says blocked on the authority of a test that
    // finished before the user flipped the switch. Someone who grants the permission
    // and comes straight back to the menu lands in exactly that stretch.
    //
    // Three conditions, all necessary: the self-check witness is the one holding the
    // warning up; the traffic witness says clear (a direct contradiction); and the
    // heartbeat has proven loopback, so that clear verdict is a statement about the
    // last sixteen seconds rather than an unbounded one. Nothing is awaited — the
    // mirrored flags are already on this actor — and the server re-checks the same
    // conditions itself before acting.
    private func reconciledLocalNetworkBlocked() -> Bool {
        guard status.isLocalNetworkBlocked else { return false }
        guard status.isLANBlockedBySelfCheckWitness,
              !status.isLANBlockedByTrafficWitness,
              status.isTrafficWitnessLive else { return true }

        Self.log("Menu opened while the LAN warning was held up only by a self-check "
            + "that inbound traffic has since contradicted — dropping the warning from "
            + "this menu and asking the server to re-test.")
        status.isLocalNetworkBlocked = false
        status.isLANBlockedBySelfCheckWitness = false
        Task { [server] in await server.retireStaleSelfCheckVerdict() }
        return false
    }

    // MARK: - Local Network warning
    // Two spellings of one condition, deliberately not shared. They are the same
    // words in different grammatical positions, and macOS capitalizes those
    // positions differently: an NSAlert's messageText is a title and takes title
    // case, while a menu item is a phrase in a list and takes sentence case.
    private static let localNetworkWarningTitle = "LAN Traffic Blocked"
    private static let localNetworkWarningMenuTitle = "LAN traffic blocked"

    private func showLocalNetworkWarning() {
        // An .accessory app is not frontmost when its menu is dismissed, so without
        // this the alert would open behind whatever the user was actually looking at.
        NSApp.activate()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Self.localNetworkWarningTitle
        alert.informativeText = "Please verify that LAN Stream has been granted "
            + "\"Local Network\" permissions in System Settings → Privacy & Security."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Close")

        Self.log("Showing the blocked-LAN-traffic alert.")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openLocalNetworkSettings()
    }

    // Deep-links to the Local Network pane. The anchor is undocumented, so the
    // general Privacy & Security pane is the fallback rather than letting the button
    // do nothing if a future macOS renames it.
    private func openLocalNetworkSettings() {
        let deepLink = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security")

        if let deepLink, NSWorkspace.shared.open(deepLink) {
            Self.log("Opened System Settings at the Local Network pane.")
            return
        }
        if let fallback, NSWorkspace.shared.open(fallback) {
            Self.log("Opened System Settings at Privacy & Security (the Local Network "
                + "anchor was not accepted).")
            return
        }
        Self.log("WARNING: could not open System Settings.")
    }

    // MARK: - Fallback port notice
    private func showFallbackPortNotice() {
        guard let activePort = status.activePort else { return }
        let preferred = status.preferredPort ?? UInt16(Preferences.serverPort)

        NSApp.activate()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Port \(preferred) Is In Use"
        alert.informativeText = "Another program on this Mac — another media server, "
            + "or an unrelated app that happens to use this number — is already using "
            + "port \(preferred), so LAN Stream is running on port \(activePort) "
            + "instead.\n\n"
            + "Players are unaffected: they use whichever port LAN Stream advertises. "
            + "To go back to port \(preferred), stop whatever is holding it, or choose "
            + "a different port in Settings."
        alert.addButton(withTitle: "Change Port…")
        alert.addButton(withTitle: "Close")

        Self.log("Showing the fallback-port notice (\(preferred) busy, using \(activePort)).")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openSettings("general")
    }

    // MARK: - Settings window
    private func openSettings(_ tabID: String) {
        if settings == nil {
            // Dependencies are injected rather than fetched from NSApp.delegate; a
            // silently-substituted throwaway ServerStatus would show the folders tab
            // a permanently "stopped" server with no indication anything was wrong.
            let viewModel = SettingsViewModel(folderStore: folderStore,
                                              server: server,
                                              status: status)
            settings = SettingsWindowController(.init(
                title: "LAN Stream Settings",
                sizing: .fitToContent(width: SettingsLayout.contentWidth,
                                      minimumHeight: SettingsLayout.minimumContentHeight),
                tabs: [
                    .swiftUI(id: "general", title: "General", symbol: "gearshape") {
                        SettingsTabGeneralView(viewModel: viewModel)
                    },
                    .viewController(id: "sharedFolders", title: "Shared Folders",
                                    symbol: "folder") {
                        SettingsTabFoldersController(folderStore: viewModel.folderStore,
                                                    status: viewModel.status)
                    },
                ],
                // Preserve LAN Stream's existing window chrome exactly: it keeps a
                // minimize button. The focus sink is adopted, so the window opens
                // without a focus ring landing on its first control.
                styleMask: [.titled, .closable, .miniaturizable,
                            .unifiedTitleAndToolbar],
                usesFocusSink: true))
        }
        settings?.open(tab: tabID)
        Self.log("Opened settings window on the \(tabID) tab.")
    }

    // MARK: - About panel
    // The standard macOS About panel, which renders the app icon, name and version
    // and picks up the GPL-3.0 text from Credits.html in the bundle's Resources.
    // An .accessory app is not frontmost when its menu is dismissed, so it has to
    // bring itself forward or the panel opens behind whatever is frontmost.
    private func showAboutPanel() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
        Self.log("Opening the standard About panel.")
    }
}

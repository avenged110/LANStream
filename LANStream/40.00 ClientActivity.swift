// MARK: - ClientActivity.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Shared "is anyone watching right now?" check and its confirmation prompts.
//
// Two separate actions interrupt the network — changing the server port and
// quitting the app — and both need the same three things: the current list of
// in-flight transfers, a sentence describing them in the user's terms, and a
// confirmation the user can decline. Implementing that twice would guarantee the
// two prompts eventually disagreed about what counts as a connected client, so
// both go through this type.

import AppKit

@MainActor
enum ClientActivity {

    // MARK: - Description
    // Renders the transfer list as a sentence. Names the file when there is only
    // one, because "Interrupt Take Me Home Tonight?" is a question the user can
    // answer immediately, whereas "1 client connected" makes them go and look.
    static func describe(_ streams: [HTTPServer.ActiveStream]) -> String {
        switch streams.count {
        case 0:
            return ""
        case 1:
            let stream = streams[0]
            return "“\(stream.title)” is currently being played by \(stream.peerHost)."
        default:
            let titles = streams.map { "“\($0.title)” (\($0.peerHost))" }
                .joined(separator: "\n")
            return "\(streams.count) files are currently being played:\n\(titles)"
        }
    }

    // MARK: - Confirmation
    // Presents 'question' as a sheet on 'window' when one is available and as a
    // standalone modal otherwise. The app is an accessory with no window of its
    // own, so the standalone path is the normal one for the quit prompt.
    //
    // Returns true when the user chose to proceed.
    static func confirm(title: String,
                        message: String,
                        proceedButton: String,
                        isDestructive: Bool,
                        attachedTo window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: proceedButton)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = isDestructive
        // Escape maps to Cancel so dismissing the prompt never proceeds by default.
        alert.buttons[1].keyEquivalent = "\u{1b}"

        guard let window, window.isVisible else {
            // Bring the app forward first: an accessory app's modal can otherwise
            // open behind whatever the user is looking at, which reads as a hang.
            NSApp.activate()
            return alert.runModal() == .alertFirstButtonReturn
        }

        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
}

// MARK: - Peer formatting
extension HTTPServer.ActiveStream {
    // The peer without its ephemeral port. The port number is meaningful in the
    // log and meaningless in a dialog.
    var peerHost: String { NetworkDescription.hostOnly(peer) }
}

// MARK: - SettingsView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Contains: SettingsLayout, SettingsViewModel, the General tab view, and the
// shared field controls (PlainTextField / WholeNumberField).
//
// The window shell, the tab view controller, launch-at-login, the log-file
// monitor, and the Debug Logging block now come from the shared
// SettingsKit ("20.10 SettingsKit.swift"); StatusMenuController
// builds the window from a SettingsWindowController. The Shared Folders tab lives
// in STabFolders.swift. There is no About tab: "About LAN Stream…" opens the
// standard macOS About panel, which picks up Credits.html from the bundle.

import Cocoa
import Combine
import SwiftUI

// MARK: - Window content dimensions
// Single authoritative source for the settings window's content dimensions.
// Adjust here and every tab picks it up. These describe the *content* area; the tab
// toolbar strip sits above it and is accounted for by NSTabViewController.
enum SettingsLayout {
    static let contentWidth: CGFloat = 500
    // The height is measured from the General tab (`.fitToContent`) — the tallest, with
    // the launch, name, port, announcement-interval, and logging controls stacked
    // vertically — and the folders tab fills it. A table needs room for rows whatever
    // General measures, so the window never drops below this.
    static let minimumContentHeight: CGFloat = 384
    // Reserved vertical space for the header row above the folders table, so the
    // table's top edge sits at a predictable Y position.
    static let headerHeight: CGFloat = 22
    // Top padding for tab content whose first element is NOT a checkbox.
    //
    // The General tab pads uniformly by tabPadding, which places its first Toggle's
    // label text at a particular height. The Shared Folders tab has no checkbox to
    // anchor against, so it uses this smaller top inset together with a header
    // container fixed at headerHeight and top-aligned inside it: the combination
    // lands its descriptive line at the same y position as the "Launch at login"
    // label opposite. Both numbers come from the reference implementation, where
    // the pairing is known to line up — change one and the tabs drift apart.
    static let tabTopPadding: CGFloat = 15

    // Vertical spacing between the header, table, and button row on table tabs.
    static let tabStackSpacing: CGFloat = 12

    // Leading, trailing, and bottom padding for tab content.
    static let tabPadding: CGFloat = 18

    // Extra top inset for the Shared Folders tab's description line, applied
    // INSIDE its fixed-height header container.
    //
    // The header container's height stays pinned at headerHeight and the table
    // hangs off the container's bottom edge, so moving the label down within the
    // container lowers the text without moving the table: the gap between the
    // text's baseline and the table's top edge shrinks by exactly this amount.
    static let folderHeaderExtraTopPadding: CGFloat = 3

    // Horizontal inset applied to rows that are NOT checkboxes, so their leading
    // edge lines up with the label text of the checkbox rows above them rather
    // than with the checkbox itself. SwiftUI's macOS Toggle renders a 13 pt
    // control followed by a 6 pt gap before its label.
    static let controlLabelInset: CGFloat = 19

    // Width of the server-name field: wide enough that a name at the 32-character
    // limit fits without the field scrolling under the user as they type.
    //
    // Measured rather than hardcoded. "32 characters wide" has no exact meaning in a
    // proportional font, so the digit advance is used as the yardstick — digits are
    // tabular in the system font and are close to the widest ordinary glyph, so a
    // 32-digit string is a fair upper bound for 32 characters of a name. The
    // constant is derived once at load; recomputing it per view would tie the
    // layout to whatever font happened to be current at that moment.
    static let serverNameFieldWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        // Plus the field's own border and text insets, which the measurement above
        // knows nothing about.
        return (digitWidth * CGFloat(Preferences.friendlyNameMaximumLength)).rounded(.up) + 10
    }()
}

// MARK: - SettingsViewModel
// Observable state hub shared between the AppKit shell and the SwiftUI tabs.
// Launch-at-login control (LoginItemManager) and the log-file monitor
// (LogFileMonitor) now come from SettingsKit.
@MainActor
final class SettingsViewModel: ObservableObject {
    let folderStore: FolderStore
    let server: DLNAServer
    let status: ServerStatus

    init(folderStore: FolderStore, server: DLNAServer, status: ServerStatus) {
        self.folderStore = folderStore
        self.server = server
        self.status = status
    }
}

// MARK: - General Tab
@MainActor
struct SettingsTabGeneralView: View, Loggable {
    nonisolated static let logTag = "[STabGeneral]"

    @ObservedObject var viewModel: SettingsViewModel

    // Launch-at-login and Debug Logging are the shared SettingsKit controls
    // (LaunchAtLoginToggle / SettingsLoggingSection); each owns its own system-state
    // re-query and log-file monitor, so this view holds no state for them.

    // The port is committed on focus loss and requires a server restart, so it is
    // held as text and validated at commit time rather than bound live.
    @State private var portText: String = "\(Preferences.serverPort)"
    @State private var priorPortText: String = "\(Preferences.serverPort)"

    // Empty means "use the default", which is why the field shows LAN Stream as
    // placeholder text rather than as content: a user who clears it should see the
    // name they are falling back to, not an empty device in the player's list.
    @State private var serverNameText: String = Preferences.storedFriendlyName
    @State private var priorServerNameText: String = Preferences.storedFriendlyName

    @State private var announceText: String = "\(Preferences.announceIntervalSeconds)"
    @State private var containerFormats: Preferences.ContainerFormats =
        Preferences.containerFormats
    @State private var priorAnnounceText: String = "\(Preferences.announceIntervalSeconds)"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LaunchAtLoginToggle(title: "Launch at login")

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Server name:")
                    PlainTextField(text: $serverNameText,
                                   placeholder: Preferences.defaultFriendlyName,
                                   sanitize: Preferences.sanitizeFriendlyName,
                                   onCommit: { field in commitServerName(field) },
                                   onBeginEdit: { priorServerNameText = serverNameText })
                        .frame(width: SettingsLayout.serverNameFieldWidth)
                }
                // Says what the field will do before it does it. The field silently
                // substitutes as the user types, and a substitution nobody was
                // warned about reads as the app eating their keystrokes.
                Text("Maximum of \(Preferences.friendlyNameMaximumLength) characters. Input "
                     + "will be normalized and the following control characters are not "
                     + "permitted: \(Preferences.friendlyNameForbiddenCharactersDescription)")
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Pulled up against the divider. The stack's 16 pt rhythm is right
            // between rows that are all one line tall, but this row is a label, a
            // field, and a description, and at full spacing it floated away from the
            // rule that introduces it.
            .padding(.top, -3)
            .padding(.leading, SettingsLayout.controlLabelInset)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Server port:")
                    WholeNumberField(text: $portText,
                                     maximumDigits: 5,
                                     onCommit: { field in commitPort(field) },
                                     onBeginEdit: { priorPortText = portText })
                        .frame(width: 64)
                }
                Text("Changing the port will restart the server and existing clients will need to reconnect to it using the new port.")
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Shown only when the preferred port was taken and the server landed
                // on a fallback. Without this the field would display a number the
                // server is demonstrably not using, which is worse than showing
                // nothing at all.
                if viewModel.status.isUsingFallbackPort,
                   let activePort = viewModel.status.activePort {
                    Label("Port \(String(viewModel.status.preferredPort ?? 0)) was already "
                          + "in use, so the server is running on port \(String(activePort)). "
                          + "Clients are unaffected.",
                          systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: NSFont.smallSystemFontSize))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, SettingsLayout.controlLabelInset)

            HStack(spacing: 6) {
                Text("Network presence broadcast interval:")
                WholeNumberField(text: $announceText,
                                 maximumDigits: 3,
                                 onCommit: { field in commitAnnounceInterval(field) },
                                 onBeginEdit: { priorAnnounceText = announceText })
                    .frame(width: 64)
                Text("seconds")
            }
            .padding(.leading, SettingsLayout.controlLabelInset)

            HStack(spacing: 6) {
                Text("Permitted container formats:")
                Picker("", selection: $containerFormats) {
                    ForEach(Preferences.ContainerFormats.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: containerFormats) { _, newValue in
                    // Written through to preferences, which publishes the key; the
                    // rescan is driven from that subscription rather than from here,
                    // so a change made any other way (a `defaults write`, a future
                    // second control) takes effect the same way this one does.
                    Preferences.containerFormats = newValue
                    Self.log("Permitted container formats set to \(newValue.displayName).")
                }
            }
            .padding(.leading, SettingsLayout.controlLabelInset)

            Divider()

            // Debug logging — the shared block: toggle, the same caption, and
            // Reveal/Clear gated on the log file's existence by its own monitor.
            // "Debug logging" (lower-case) matches LAN Stream's existing wording;
            // the shared default is title-case. On disable it does the forced-log
            // and shutdownLogging handling this view did by hand.
            SettingsLoggingSection(loggingEnabledKey: Preferences.Keys.loggingEnabled,
                                   title: "Debug logging")
        }
        // Uniform on three sides, one point tighter at the top. The General tab is
        // the only one whose first row is a checkbox, and a Toggle carries a little
        // more optical space above its label than a plain text row does, so the
        // even inset read as slightly too deep here and nowhere else.
        .padding(EdgeInsets(top: SettingsLayout.tabPadding - 5,
                            leading: SettingsLayout.tabPadding,
                            bottom: SettingsLayout.tabPadding,
                            trailing: SettingsLayout.tabPadding))
        .frame(width: SettingsLayout.contentWidth, alignment: .topLeading)
        .onAppear {
            serverNameText = Preferences.storedFriendlyName
            priorServerNameText = serverNameText
            portText = "\(Preferences.serverPort)"
            priorPortText = portText
            announceText = "\(Preferences.announceIntervalSeconds)"
            containerFormats = Preferences.containerFormats
            priorAnnounceText = announceText
        }
    }

    // MARK: - Port commit
    private func commitAnnounceInterval(_ field: NSTextField) {
        let entered = Int(field.stringValue) ?? 0
        let range = Preferences.announceIntervalRange
        guard range.contains(entered) else {
            presentRangeAlert(
                on: field,
                title: "Invalid Broadcast Interval",
                message: "Enter a whole number between \(range.lowerBound) and \(range.upperBound) seconds.")
            field.stringValue = priorAnnounceText
            announceText = priorAnnounceText
            return
        }

        guard entered != Preferences.announceIntervalSeconds else { return }
        Preferences.announceIntervalSeconds = entered
        announceText = "\(entered)"
        priorAnnounceText = announceText
        Self.log("Broadcast interval changed to \(entered)s.")
    }

    private func presentRangeAlert(on field: NSTextField, title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = unsafe field.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // Committed on focus loss, like the other fields. There is nothing to validate
    // at this point — the formatter has already removed anything unacceptable while
    // it was being typed — so this only trims and forwards it.
    private func commitServerName(_ field: NSTextField) {
        let entered = Preferences.sanitizeFriendlyName(field.stringValue)
            .trimmingCharacters(in: .whitespaces)
        field.stringValue = entered
        serverNameText = entered

        guard entered != Preferences.storedFriendlyName else { return }
        Preferences.friendlyName = entered
        Self.log("Server name set to \"\(Preferences.friendlyName)\"" +
                 (entered.isEmpty ? " (cleared; using the default)." : "."))
    }

    // Changing the port rebinds the listener, which drops every transfer in
    // flight, so the change is confirmed before it is applied rather than
    // announced afterwards.
    private func commitPort(_ field: NSTextField) {
        let entered = Int(field.stringValue) ?? 0
        guard (1024...65535).contains(entered) else {
            presentRangeAlert(on: field, title: "Invalid Port",
                              message: "Enter a whole number between 1024 and 65535.")
            field.stringValue = priorPortText
            portText = priorPortText
            return
        }

        guard entered != Preferences.serverPort else { return }

        let window = unsafe field.window
        let server = viewModel.server

        Task { @MainActor in
            let streams = await server.activeStreams()

            var message = "This will restart the server and existing clients "
                + "will need to reconnect to it using the new port."
            if !streams.isEmpty {
                message += "\n\n" + ClientActivity.describe(streams)
                    + "\n\nRestarting will stop playback."
            }

            let proceed = await ClientActivity.confirm(
                title: "Change Server Port to \(entered)?",
                message: message,
                proceedButton: "Change Port",
                isDestructive: !streams.isEmpty,
                attachedTo: window)

            guard proceed else {
                // Put the field back the way the user found it.
                portText = priorPortText
                field.stringValue = priorPortText
                Self.log("Port change to \(entered) canceled by the user.")
                return
            }

            Preferences.serverPort = entered
            portText = "\(entered)"
            priorPortText = portText
            Self.log("Server port changed to \(entered) (\(streams.count) transfer(s) interrupted); restarting server.")
            await server.restart()
        }
    }

}

// MARK: - PlainTextField
// A single-line text field that silently enforces an arbitrary character rule as
// the user types, and shows placeholder text when empty.
//
// Same shape and same reasoning as WholeNumberField below — the rule lives in a
// Formatter so that rejected characters never reach the field at all, rather than
// being typed and then removed a moment later. The difference is visible: a field
// corrected after the fact flickers and moves the caret, and pasting a long string
// into one produces a distracting redraw. Here the substitution happens inside the
// edit itself, so from the user's side the character simply never arrives.
private struct PlainTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let sanitize: @Sendable (String) -> String
    let onCommit: (NSTextField) -> Void
    let onBeginEdit: () -> Void

    func makeCoordinator() -> WholeNumberField.Coordinator {
        WholeNumberField.Coordinator(onCommit: onCommit, onBeginEdit: onBeginEdit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = context.coordinator
        field.formatter = SanitizingFormatter(sanitize: sanitize)
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Never overwrite the field mid-edit; doing so discards in-progress input.
        if field.currentEditor() == nil { field.stringValue = text }
        field.placeholderString = placeholder
        context.coordinator.onCommit = onCommit
        context.coordinator.onBeginEdit = onBeginEdit
    }
}

// MARK: - SanitizingFormatter
// Applies a caller-supplied cleaning function to every proposed edit.
//
// The caret handling is the whole point and is easy to get wrong: when characters
// are dropped from the middle of a paste, the caret must move back by however many
// were removed, or it jumps to the end of the field and the user loses their place.
//
// The four-argument isPartialStringValid is the one that matters here. Its
// two-argument sibling can only accept or reject, and rejecting makes AppKit
// discard the entire edit and beep — so pasting "80 80" would blank a port field
// rather than yield "8080", and every stray keypress would sound an alert. This
// variant can rewrite the proposed string and reposition the insertion point,
// which is what allows invalid characters to be dropped in place with the caret
// left exactly where the user expects and no visible flicker.
//
// Both text fields in this window use this one type. The digits-only rule the port
// and interval fields need is just a particular 'sanitize' closure, and keeping it
// as a separate Formatter subclass meant maintaining two copies of the caret
// arithmetic above — the part that is genuinely fiddly and must not drift.
final class SanitizingFormatter: Formatter {
    private let sanitize: @Sendable (String) -> String

    init(sanitize: @escaping @Sendable (String) -> String) {
        self.sanitize = sanitize
        super.init()
    }

    // Keeps a field to whole decimal digits, at most 'maximumDigits' of them.
    // Bounds the value so an absent-minded key repeat cannot produce a number that
    // overflows on parse.
    static func wholeNumber(maximumDigits: Int) -> SanitizingFormatter {
        SanitizingFormatter { proposed in
            String(proposed.filter { $0.isASCII && $0.isNumber }
                .prefix(maximumDigits))
        }
    }

    required init?(coder: NSCoder) { return nil }

    // NSNumber is handled as well as String. No call site currently sets a numeric
    // object value — both fields are driven as text — but the digit formatter this
    // type absorbed did accept one, and silently narrowing that would be a change
    // nobody asked for.
    override func string(for objectValue: Any?) -> String? {
        if let number = objectValue as? NSNumber { return number.stringValue }
        return objectValue as? String
    }

    override func getObjectValue(_ objectValue: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                                 for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        unsafe objectValue?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(
        _ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
        originalString origString: String,
        originalSelectedRange origSelRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        let proposed = unsafe partialStringPtr.pointee as String
        let filtered = sanitize(proposed)

        // Nothing was removed: accept the edit untouched.
        if filtered == proposed { return true }

        let removedCount = proposed.count - filtered.count
        unsafe partialStringPtr.pointee = filtered as NSString
        if let proposedSelRangePtr = unsafe proposedSelRangePtr {
            let location = max(0, min(filtered.count,
                                      unsafe proposedSelRangePtr.pointee.location - removedCount))
            unsafe proposedSelRangePtr.pointee = NSRange(location: location, length: 0)
        }
        // false means "I have replaced the proposed string". Returning false would
        // normally also beep; the shared Coordinator suppresses that.
        return false
    }
}

// MARK: - WholeNumberField
// AppKit text field with a whole-number formatter, committing on focus loss.
// Using NSTextField rather than SwiftUI's TextField gives the formatter's
// isPartialStringValid keystroke intercept, which SwiftUI has no equivalent hook
// for. Shared by the port and announcement-interval fields.
private struct WholeNumberField: NSViewRepresentable {
    @Binding var text: String
    let maximumDigits: Int
    let onCommit: (NSTextField) -> Void
    let onBeginEdit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onBeginEdit: onBeginEdit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.alignment = .center
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = context.coordinator
        field.formatter = SanitizingFormatter.wholeNumber(maximumDigits: maximumDigits)
        field.bezelStyle = .roundedBezel
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Never overwrite the field mid-edit; doing so discards in-progress input.
        if field.currentEditor() == nil { field.stringValue = text }
        context.coordinator.onCommit = onCommit
        context.coordinator.onBeginEdit = onBeginEdit
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (NSTextField) -> Void
        var onBeginEdit: () -> Void

        init(onCommit: @escaping (NSTextField) -> Void,
             onBeginEdit: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onBeginEdit = onBeginEdit
        }

        func controlTextDidBeginEditing(_ obj: Notification) { onBeginEdit() }

        // Swallows the failure notice the formatter raises when it strips a
        // character. Without this AppKit sounds the system alert on every rejected
        // keypress — the input has already been silently corrected, so the beep is
        // noise reporting a problem the user cannot see and does not have.
        func control(_ control: NSControl,
                     didFailToValidatePartialString string: String,
                     errorDescription error: String?) {
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            onCommit(field)
        }
    }
}

// SettingsTabViewController and SettingsWindow removed: the window shell and
// its tab controller now come from SettingsKit's SettingsWindowController,
// built in StatusMenuController.openSettings(_:).

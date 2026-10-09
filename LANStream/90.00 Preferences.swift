// MARK: - Preferences.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Typed facade over UserDefaults for LAN Stream.app.
//
// Every setter routes through 'setIfChanged', which suppresses no-op writes and
// publishes the changed key on 'preferencesChanged' so interested views and the
// server can react without polling.

import Foundation
import Combine

enum Preferences {

    // MARK: - Keys
    // Raw UserDefaults key strings. Exposed so @AppStorage call sites and
    // preferencesChanged subscribers can reference the same constants.
    enum Keys {
        static let loggingEnabled   = "loggingEnabled"
        static let sharedFolders    = "sharedFolders"
        static let serverPort       = "serverPort"
        static let serverUUID       = "serverUUID"
        static let friendlyName     = "friendlyName"
        static let announceInterval = "announceIntervalSeconds"
        static let containerFormats = "permittedContainerFormats"
    }

    // MARK: - Change notification
    // Publishes the key of any preference that actually changed value.
    // A Combine subject (rather than NotificationCenter) keeps subscribers strongly
    // typed and lets them be torn down automatically via AnyCancellable.
    // Main-actor isolated: Combine does not declare PassthroughSubject Sendable, and
    // every writer (the settings window and FolderStore) and every subscriber
    // (AppDelegate) already runs on the main actor. Isolating it states that fact
    // to the compiler instead of opting out with nonisolated(unsafe), and it also
    // guarantees subscribers are called on the main thread.
    @MainActor static let preferencesChanged = PassthroughSubject<String, Never>()

    // The setters themselves stay nonisolated so the getters they share a property
    // with remain readable from the server actor. assumeIsolated is the checked
    // bridge: it verifies at runtime that the write came from the main actor rather
    // than taking it on trust.
    private static func publishChange(_ key: String) {
        MainActor.assumeIsolated { preferencesChanged.send(key) }
    }

    // Computed rather than stored: UserDefaults is documented as thread-safe but not
    // declared Sendable, so a stored static would need nonisolated(unsafe) and an
    // `unsafe` at every read. Reading .standard each time returns the same shared
    // instance and leaves no global state for the compiler to question.
    private static var defaults: UserDefaults { .standard }

    // Writes 'value' for 'key' only when it differs from the stored value, then
    // publishes the key. Equatable is required so the comparison is meaningful;
    // without the guard, every write would emit a change event and cause
    // subscribers to perform redundant work (table reloads, content rescans).
    private static func setIfChanged<T: Equatable>(_ value: T, forKey key: String,
                                                   current: T) {
        guard value != current else { return }
        defaults.set(value, forKey: key)
        publishChange(key)
    }

    // MARK: - Registration of factory defaults
    // Called once from AppDelegate before any other preference is read so that
    // first-launch reads return the intended values rather than zero/nil.
    static func registerDefaults() {
        defaults.register(defaults: [
            Keys.loggingEnabled: false,
            Keys.serverPort: defaultServerPort,
            // Deliberately NOT registered with a value: an empty stored name is what
            // means "no override", and registering the default would make every
            // install look as though the user had explicitly chosen it.
            Keys.announceInterval: defaultAnnounceIntervalSeconds,
            Keys.containerFormats: ContainerFormats.matroskaOnly.rawValue
        ])
    }

    // MARK: - Logging
    static var loggingEnabled: Bool {
        get { defaults.bool(forKey: Keys.loggingEnabled) }
        set { setIfChanged(newValue, forKey: Keys.loggingEnabled, current: loggingEnabled) }
    }

    // MARK: - Server identity
    // One past 8200, the de-facto convention for DLNA servers on the LAN (MiniDLNA's
    // default), specifically so that a machine already running MiniDLNA, Gerbera or a
    // NAS daemon on 8200 does not collide with this app. The number itself carries no
    // compatibility weight: clients never assume a port, they read it out of the
    // LOCATION URL in the announcement.
    static let defaultServerPort = 8201

    // How many ports past the preferred one the server may try when the preferred
    // port is already taken — by another DLNA server, by an unrelated process, or by
    // a second copy of this app on the same Mac.
    //
    // Four is enough to get past a realistic pile-up without wandering far from the
    // number the user configured, which matters because the fallback is meant to be
    // recognizable: someone who set 8201 should still find the server somewhere in
    // the low 820x range rather than at an arbitrary ephemeral port. Clients are
    // unaffected either way — they read the port out of the advertised LOCATION.
    static let portFallbackAttempts = 4

    // The preferred port first, then the fallback ladder, clamped to the valid range.
    static func portCandidates(preferred: UInt16) -> [UInt16] {
        var candidates: [UInt16] = [preferred]
        for step in 1...portFallbackAttempts {
            let next = Int(preferred) + step
            guard next <= 65535 else { break }
            candidates.append(UInt16(next))
        }
        return candidates
    }

    static var serverPort: Int {
        get {
            let stored = defaults.integer(forKey: Keys.serverPort)
            // A stored 0 means "never set"; anything outside the valid unprivileged
            // range is treated as corrupt and replaced by the default so the server
            // can always bind to something sane.
            guard (1024...65535).contains(stored) else { return defaultServerPort }
            return stored
        }
        set { setIfChanged(newValue, forKey: Keys.serverPort, current: serverPort) }
    }

    // The UPnP Unique Device Name. This MUST remain stable across launches: control
    // points cache devices by UDN, and a server that presents a fresh UUID on every
    // start appears as an ever-growing pile of stale duplicate entries in the Oppo's
    // device list. Generated once on first access and persisted from then on.
    //
    // The first-launch mint is serialized. The launch line that reads this is a log
    // autoclosure and is never evaluated while logging is off, so the first real
    // read happens on whichever server actor gets there first — and the SSDP and
    // HTTP actors can get there together. Unguarded, each saw no stored value and
    // minted its own, so the first announcements and the description document could
    // name two different devices.
    private static let serverUUIDLock = NSLock()

    static var serverUUID: String {
        if let existing = defaults.string(forKey: Keys.serverUUID), !existing.isEmpty {
            return existing
        }
        serverUUIDLock.lock()
        defer { serverUUIDLock.unlock() }
        // Re-read under the lock: another thread may have minted it while this one
        // was waiting.
        if let existing = defaults.string(forKey: Keys.serverUUID), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: Keys.serverUUID)
        return generated
    }

    // The name shown in the player's device list.
    static let defaultFriendlyName = "LAN Stream"

    // UPnP puts no formal restriction on friendlyName beyond it being a UTF-8 string
    // that survives XML escaping, and this app escapes it on the way out, so nothing
    // here is required for correctness. It is required for COMPATIBILITY, which is a
    // different and less forgiving standard:
    //
    //   • Hardware players routinely render the device list in a fixed 7-bit font.
    //     A name with accents or emoji comes back as boxes, or truncates the entry,
    //     or on the worst firmware drops the device from the list entirely.
    //   • The angle brackets and ampersand are escaped correctly by this server, but
    //     a client that hands the decoded name to its own XML or URL layer without
    //     re-escaping produces a broken request blamed on the server. Quotes have the
    //     same problem inside attribute values.
    //   • Control characters have no rendering at all and are simply a hazard.
    //
    // So the field is restricted to plain printable ASCII minus the five XML
    // metacharacters. That is a deliberately conservative set: it costs a user
    // nothing they are likely to want, and it removes an entire class of fault that
    // would surface as "my player cannot see the server" with nothing in any log.
    static let friendlyNameForbiddenCharacters: Set<Character> = ["<", ">", "&", "\"", "'"]

    // 32 characters. The earlier 64 was the conventional protocol ceiling rather
    // than a useful one: no television device list shows anything close to that
    // many, so the back half of a long name was only ever going to be truncated by
    // the player instead of by this app — silently, and differently on every piece
    // of firmware. Truncating here means the name the user sees in Settings is the
    // name the player has a real chance of showing whole.
    static let friendlyNameMaximumLength = 32

    // Transliterates rather than discards.
    //
    // The rule this serves has not changed — what leaves this app is plain printable
    // ASCII, because hardware players render the device list in a 7-bit font and do
    // unpredictable things with anything else. What changed is the treatment of the
    // characters that fail it. Dropping them turned "Café" into "Caf" and "Grüße"
    // into "Gre": the user's name silently lost letters, and the result was not a
    // worse spelling of what they meant, it was a different word.
    //
    // ICU's "Any-Latin; Latin-ASCII" chain converts instead. Accented Latin letters
    // lose their marks (é→e, ä→a, ũ→u), letters that are not merely accented are
    // spelled out the way the language itself romanizes them (ø→o, æ→ae, ß→ss), and
    // non-Latin scripts are romanized before that second step rather than vanishing.
    // Anything the transform cannot represent still falls through to the filter
    // below and is dropped, so the guarantee is unchanged and only the outcome for
    // recoverable input is better.
    static func transliterateToASCII(_ proposed: String) -> String {
        proposed.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"),
                                   reverse: false) ?? proposed
    }

    // Applies the rules above. Returns the name unchanged when it is already clean,
    // which is what lets the text field substitute silently without flicker.
    static func sanitizeFriendlyName(_ proposed: String) -> String {
        let filtered = transliterateToASCII(proposed).filter { character in
            guard let ascii = character.asciiValue else { return false }
            // 0x20...0x7E is printable ASCII: space through tilde.
            guard (0x20...0x7E).contains(ascii) else { return false }
            return !friendlyNameForbiddenCharacters.contains(character)
        }
        return String(filtered.prefix(friendlyNameMaximumLength))
    }

    // The forbidden set, written the way it should be shown to a user: spaced out
    // so the characters are individually legible, and in a fixed order so the line
    // does not reshuffle itself between launches (the set itself is unordered).
    //
    // DERIVED from the set rather than restated as a second literal. The two were
    // written out separately, which meant adding a character to the rule left the
    // settings window quietly describing the old one — and only the set is actually
    // enforced, so the label was the half that would have been wrong. Sorting is
    // what supplies the stable order the set cannot.
    static var friendlyNameForbiddenCharactersDescription: String {
        friendlyNameForbiddenCharacters
            .sorted { String($0) < String($1) }
            .map(String.init)
            .joined(separator: "  ")
    }

    // The raw stored override, empty when the user has not set one. The settings
    // field binds to THIS rather than to friendlyName: binding to the resolved value
    // would put "LAN Stream" in the field as literal text, and the user could then
    // not tell an explicit choice apart from the default, nor clear it back.
    static var storedFriendlyName: String {
        sanitizeFriendlyName(defaults.string(forKey: Keys.friendlyName) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    static var friendlyName: String {
        get {
            // Sanitized on the way OUT as well as in. The value can predate this
            // rule, or arrive from a `defaults write`, and the one place that must
            // never see an unexpected character is the description document.
            let stored = sanitizeFriendlyName(defaults.string(forKey: Keys.friendlyName) ?? "")
                .trimmingCharacters(in: .whitespaces)
            return stored.isEmpty ? defaultFriendlyName : stored
        }
        set {
            let cleaned = sanitizeFriendlyName(newValue).trimmingCharacters(in: .whitespaces)
            setIfChanged(cleaned, forKey: Keys.friendlyName, current: friendlyName)
        }
    }

    // MARK: - Discovery
    // How often ssdp:alive is re-broadcast, in seconds.
    //
    // This governs discovery LATENCY, not cache validity: CACHE-CONTROL stays at the
    // conventional 1800 s regardless, and the UPnP spec only requires re-announcing
    // before that expires. The interval is what bounds how long a client that missed
    // the last announcement — and whose M-SEARCH went unanswered for any reason —
    // waits before the server appears.
    //
    // Thirty seconds. This is still an order of magnitude more aggressive than the
    // reference implementations — MiniDLNA re-announces every 895 s — because those
    // rely entirely on M-SEARCH for prompt discovery, and M-SEARCH is genuinely the
    // path that matters: a player that has just been switched on searches, and gets a
    // unicast answer within a second or two no matter what this value says. Periodic
    // announcements only serve a client that was ALREADY listening when the server
    // appeared and that will not search again on its own.
    //
    // Going shorter than this buys almost nothing and is not free. Multicast on Wi-Fi
    // is transmitted at the lowest basic rate, is unacknowledged, and is received and
    // processed by every device on the segment including phones on battery; one burst
    // is five datagrams, and the startup burst is fifteen. Thirty seconds bounds the
    // passive-discovery window at half a minute while costing a trivial amount of
    // airtime, and it keeps a very wide margin under the 1800 s cache lifetime.
    static let defaultAnnounceIntervalSeconds = 30

    // Bounds for the settings field. The floor keeps a mistyped value from turning
    // the app into a multicast flood; the ceiling keeps it below the point where a
    // client's 1800 s cache entry could expire between announcements.
    static let announceIntervalRange = 5...900

    static var announceIntervalSeconds: Int {
        get {
            let stored = defaults.integer(forKey: Keys.announceInterval)
            guard announceIntervalRange.contains(stored) else {
                return defaultAnnounceIntervalSeconds
            }
            return stored
        }
        set {
            setIfChanged(newValue, forKey: Keys.announceInterval,
                         current: announceIntervalSeconds)
        }
    }

    // MARK: - Container formats
    // Which container formats a scan is allowed to publish.
    //
    // This is a whitelist and not a "hide these" filter, which is the right way
    // round for a media server: the cost of publishing a file the player cannot
    // demux is an entry that fails on selection with no explanation, while the cost
    // of omitting one is a file the user can go and enable. MKV alone is the default
    // because it is what this server was built around and what the Oppo is fed.
    enum ContainerFormats: String, CaseIterable, Sendable {
        case matroskaOnly
        case mp4Only
        case matroskaAndMP4

        var displayName: String {
            switch self {
            case .matroskaOnly:    return "Matroska only"
            case .mp4Only:         return "MP4/M4V/MOV only"
            case .matroskaAndMP4:  return "Matroska and MP4/M4V/MOV"
            }
        }

        // The extensions a scan accepts. Lowercase; the scan lowercases before
        // comparing. .m4v and .mov ride along with MP4 — m4v is an MP4 file with a
        // different extension, and .mov is the container MP4 was derived from.
        var fileExtensions: Set<String> {
            switch self {
            case .matroskaOnly:   return ["mkv"]
            case .mp4Only:        return ["mp4", "m4v", "mov"]
            case .matroskaAndMP4: return ["mkv", "mp4", "m4v", "mov"]
            }
        }

        // Used in the shared-folders header, which reads "Share the <this> files in
        // these folders and their subfolders:".
        var contentDescription: String {
            switch self {
            case .matroskaOnly:   return "Matroska"
            case .mp4Only:        return "MP4/M4V/MOV"
            case .matroskaAndMP4: return "Matroska and MP4/M4V/MOV"
            }
        }
    }

    static var containerFormats: ContainerFormats {
        get {
            let stored = defaults.string(forKey: Keys.containerFormats) ?? ""
            return ContainerFormats(rawValue: stored) ?? .matroskaOnly
        }
        set {
            setIfChanged(newValue.rawValue, forKey: Keys.containerFormats,
                         current: containerFormats.rawValue)
        }
    }

    // MARK: - Shared folders
    // Persisted as a property-list-encoded array of SharedFolder values (bookmark
    // data plus a last-known path). Storing Data rather than a plain path array is
    // what lets a folder survive being renamed, or its external volume remounting
    // at a different path — the single most common way a fixed-path media server
    // silently stops working.
    static var sharedFolders: [SharedFolder] {
        get {
            guard let data = defaults.data(forKey: Keys.sharedFolders) else { return [] }
            do {
                return try PropertyListDecoder().decode([SharedFolder].self, from: data)
            } catch {
                Logger.log("ERROR: Failed to decode shared folders: \(error.localizedDescription)",
                           cName: "[Preferences]")
                return []
            }
        }
        set {
            // The write and the change notification are deliberately decoupled.
            //
            // SharedFolder's Equatable conformance ignores bookmark bytes, so that a
            // bookmark quietly regenerated during resolution is not mistaken for a
            // user edit. Guarding the WRITE on that same comparison — which this
            // used to do — meant a refreshed bookmark was computed, judged "equal",
            // and thrown away, so the self-healing never actually reached disk and
            // the stale bookmark was re-resolved on every launch forever.
            //
            // So: always persist, and notify only when the user-visible list has
            // genuinely changed. Subscribers rescan on notification, and rescanning
            // because a bookmark was rewritten would be pure waste.
            let previous = sharedFolders
            do {
                let data = try PropertyListEncoder().encode(newValue)
                defaults.set(data, forKey: Keys.sharedFolders)
            } catch {
                Logger.log("ERROR: Failed to encode shared folders: \(error.localizedDescription)",
                           cName: "[Preferences]")
                return
            }
            if newValue != previous {
                publishChange(Keys.sharedFolders)
            }
        }
    }
}

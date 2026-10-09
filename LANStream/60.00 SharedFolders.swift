// MARK: - SharedFolders.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The persisted model for the folders LAN Stream exposes to DLNA clients.
//
// Each entry stores bookmark data alongside a last-known path. The bookmark is
// the authoritative locator: it survives renames and, critically for this app's
// use case, survives an external volume remounting at a different path (e.g.
// "/Volumes/Media" becoming "/Volumes/Media 1" after an unclean unmount). The
// stored path is retained purely so the UI has something to display when a
// bookmark cannot currently be resolved, e.g. while its drive is disconnected.
//
// Under the App Sandbox the bookmark carries a second job: it is not merely a
// locator but the app's only PERMISSION to read the folder at all. Bookmarks are
// therefore created and resolved with the security-scope option, and every
// resolution hands back a live grant that FolderStore owns and eventually releases.
// See SecurityScope.swift for the ownership rule and why a lapsed grant is the one
// failure in this app that does not look like itself.

import Foundation
import System
import SwiftUI

// MARK: - SharedFolder
struct SharedFolder: Codable, Equatable, Hashable, Identifiable, Sendable {

    // Stable identity for SwiftUI/table diffing. Derived from the path at creation
    // time and persisted, so it does not change when the folder is later relocated.
    let id: UUID

    // Bookmark data produced by URL.bookmarkData(), ALWAYS with the security-scope
    // option — see makeBookmark below, which is this property's only writer.
    //
    // Inside the sandbox this is not merely an address, it is the app's permission
    // to read the folder at all: a bookmark created without the scope option
    // resolves perfectly well and then grants nothing, so the folder reads as
    // permanently empty with no error anywhere. Resolution therefore hands back a
    // live grant that FolderStore owns and releases; see SecurityScope.swift.
    private(set) var bookmarkData: Data?

    // Last known filesystem path. Display fallback and diagnostic aid only —
    // never used for file access when a bookmark is resolvable.
    private(set) var lastKnownPath: String

    // Name shown in the folders table and used as the top-level container title
    // presented to the DLNA client.
    private(set) var displayName: String

    // MARK: - Construction
    init(url: URL) {
        self.id = UUID()
        self.lastKnownPath = url.path(percentEncoded: false)
        self.displayName = FileManager.default.displayName(
            atPath: url.path(percentEncoded: false))
        self.bookmarkData = Self.makeBookmark(for: url)
    }

    // Security-scoped, always. The option is what makes the resulting data usable
    // as a permission and not just an address, and a bookmark created without it
    // resolves fine inside the sandbox and then grants nothing — the folder reads
    // as permanently empty with no error anywhere. Creating one requires that the
    // app currently has access to 'url', which it does at both call sites: straight
    // out of the open panel or a drop, or while a grant obtained from the previous
    // bookmark is still held.
    private static func makeBookmark(for url: URL) -> Data? {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            Logger.log("Created a security-scoped bookmark for "
                + "\(url.path(percentEncoded: false)) (\(data.count) bytes).",
                       cName: "[SharedFolder]")
            return data
        } catch {
            // Non-fatal in an unsandboxed build, and fatal to this folder in a
            // sandboxed one — there is no other way back to it. Both are logged the
            // same way because the difference is already established by the runtime
            // environment line at startup.
            Logger.log("ERROR: Could not create a security-scoped bookmark for "
                + "\(url.path(percentEncoded: false)): "
                + "\(FileAccessDiagnosis.describe(error)). Inside the sandbox this "
                + "folder cannot be re-opened on a later launch without one.",
                       cName: "[SharedFolder]")
            return nil
        }
    }

    // MARK: - Resolution
    // Resolves this entry to a currently valid directory URL, or nil if the folder
    // cannot be reached right now (disconnected drive, deleted directory).
    //
    // 'didBecomeStale' is handled by rebuilding the bookmark and reporting the fresh
    // data back through the returned Resolution so the caller can persist it. The
    // resolved copy is returned rather than mutated in place because this type is a
    // value and the persistence decision belongs to the caller (FolderStore).
    struct Resolution: Sendable {
        let url: URL
        // Non-nil when the bookmark was stale and has been regenerated; the caller
        // should persist the updated entry.
        let refreshedEntry: SharedFolder?
        // The live security-scoped grant that made this resolution usable. Ownership
        // passes to the caller, which must relinquish it exactly once — FolderStore
        // does that in applyResolution. Nil only on the path-only fallback below,
        // where there is no bookmark to derive a grant from.
        let access: SecurityScopedAccess?
    }

    func resolve() -> Resolution? {
        let tag = "'\(displayName)' (\(SecurityScopedAccess.shortID(id)))"
        // Set when a bookmark exists but could not be resolved, which is what
        // distinguishes "this entry never had a bookmark" from "this entry's
        // bookmark is no longer usable" once the fallback below succeeds. The two
        // want the same repair and deserve different log lines.
        var hadUnusableBookmark = false

        if let bookmarkData {
            var isStale = false
            do {
                // .withSecurityScope is what makes the resolved URL grantable; see
                // makeBookmark. .withoutUI because resolution runs unattended on a
                // background rescan timer, and a bookmark pointing at an absent
                // volume must fail quietly rather than throwing up a mount or
                // authentication dialog from a menu bar app nobody is looking at.
                let url = try URL(resolvingBookmarkData: bookmarkData,
                                  options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale)

                // The grant is started BEFORE anything touches the filesystem. Every
                // step below — the staleness rewrite, the reachability stat, and
                // afterwards the whole index walk and every media read — is a real
                // access that the sandbox will refuse without it. Starting it later,
                // after the reachability check "proved" the folder was fine, is the
                // shape of bug that reports a healthy folder and then serves nothing
                // from it.
                let access = SecurityScopedAccess.acquire(url: url, folderID: id,
                                                          displayName: displayName)

                let resolvedPath = url.path(percentEncoded: false)
                if resolvedPath != lastKnownPath {
                    Logger.log("Bookmark for \(tag) resolved to a new location: "
                        + "\(lastKnownPath) -> \(resolvedPath).",
                               cName: "[SharedFolder]")
                }

                if isStale {
                    // The bookmark still resolved, but macOS has told us it should be
                    // rewritten. Regenerate now — while the grant above is held, which
                    // is what makes creating the replacement possible — so the next
                    // launch does not have to.
                    var refreshed = self
                    refreshed.bookmarkData = Self.makeBookmark(for: url)
                    refreshed.lastKnownPath = resolvedPath
                    Logger.log("Bookmark for \(tag) was stale and has been regenerated "
                        + "at \(resolvedPath).", cName: "[SharedFolder]")
                    guard Self.isReachableDirectory(url) else {
                        access.relinquish(reason: "the folder is not readable after a "
                            + "stale-bookmark refresh")
                        Logger.log("WARNING: \(tag) resolved and refreshed but is not a "
                            + "readable directory at \(resolvedPath) — reporting it "
                            + "unreachable.", cName: "[SharedFolder]")
                        return nil
                    }
                    return Resolution(url: url, refreshedEntry: refreshed, access: access)
                }

                // A bookmark can resolve to a path that no longer exists if the volume
                // is absent, and inside the sandbox it can also resolve to one this
                // app is not permitted to read. Both land here.
                guard Self.isReachableDirectory(url) else {
                    access.relinquish(reason: "the resolved folder is not readable")
                    Logger.log("\(tag) resolved to \(resolvedPath) but that is not a "
                        + "readable directory — reporting it unreachable. If the volume "
                        + "is present, the grant "
                        + (access.wasGranted ? "was held" : "was NOT held")
                        + ", which is the first thing to check.",
                               cName: "[SharedFolder]")
                    return nil
                }

                // Keep the display path current when the folder has moved.
                if resolvedPath != lastKnownPath {
                    var refreshed = self
                    refreshed.lastKnownPath = resolvedPath
                    return Resolution(url: url, refreshedEntry: refreshed, access: access)
                }
                return Resolution(url: url, refreshedEntry: nil, access: access)
            } catch {
                // Fall through to the path-based attempt below.
                hadUnusableBookmark = true
                Logger.log("ERROR: Bookmark resolution failed for \(tag) "
                    + "(last known at \(lastKnownPath)): "
                    + "\(FileAccessDiagnosis.describe(error)). Falling back to the "
                    + "stored path, and rebuilding the bookmark if that works.",
                           cName: "[SharedFolder]")
            }
        }

        // Last resort: try the stored path directly. This covers entries whose
        // bookmark could never be created, and the case where a drive has remounted
        // at exactly the path we remembered.
        //
        // Inside the sandbox this path can only succeed for somewhere the app is
        // already allowed to be, which a user-chosen media folder never is. It is
        // kept because it costs nothing and still rescues the unsandboxed case, but
        // its failure is called out by name: "cannot be reached" and "am not
        // permitted to reach" are the same symptom here and very different problems.
        let fallbackURL = URL(filePath: lastKnownPath, directoryHint: .isDirectory)
        guard Self.isReachableDirectory(fallbackURL) else {
            if SandboxEnvironment.isSandboxed {
                Logger.log("\(tag) has no usable bookmark and its stored path "
                    + "(\(lastKnownPath)) cannot be read directly. Inside the sandbox "
                    + "that is expected rather than surprising: a path alone carries no "
                    + "permission. Remove and re-add the folder to grant access again.",
                           cName: "[SharedFolder]")
            } else {
                Logger.log("\(tag) is unreachable at its stored path "
                    + "(\(lastKnownPath)) and has no usable bookmark.",
                           cName: "[SharedFolder]")
            }
            return nil
        }

        Logger.log("\(tag) was resolved from its stored path (\(lastKnownPath)) rather "
            + "than from a bookmark"
            + (hadUnusableBookmark ? ", because the bookmark it had is unusable." : ".") ,
                   cName: "[SharedFolder]")

        // The folder is readable right now, so this is the one moment a usable
        // bookmark can be minted for it. Both routes here need that equally:
        //
        //   • An entry that never had one (a bookmark that failed to be created when
        //     the folder was added).
        //   • An entry carrying a bookmark from a PRE-SANDBOX build. Those were
        //     written without the security-scope option, and inside the sandbox they
        //     fail to resolve at all — so without this the folder would depend on
        //     ambient access forever and would break the moment that access changed.
        //     Rebuilding here is what silently migrates such an entry the first time
        //     the app can still reach it.
        var refreshed = self
        guard let regenerated = Self.makeBookmark(for: fallbackURL) else {
            Logger.log("WARNING: \(tag) is readable at \(lastKnownPath) but a "
                + "security-scoped bookmark could not be created for it, so this "
                + "access cannot be preserved. The folder will keep working only for "
                + "as long as it is reachable without one.", cName: "[SharedFolder]")
            return Resolution(url: fallbackURL, refreshedEntry: nil, access: nil)
        }
        refreshed.bookmarkData = regenerated
        refreshed.lastKnownPath = fallbackURL.path(percentEncoded: false)

        // Adopt the replacement immediately rather than waiting for the next launch,
        // so this session runs on the same footing every later one will. If the new
        // bookmark cannot be resolved and granted right now it is still persisted —
        // it may well work on a fresh launch — but this round continues on the
        // ambient access that got us here, and says so.
        var isStale = false
        guard let scopedURL = try? URL(resolvingBookmarkData: regenerated,
                                       options: [.withSecurityScope, .withoutUI],
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &isStale) else {
            Logger.log("\(tag): a replacement security-scoped bookmark was created and "
                + "stored, but it could not be resolved immediately. It will be tried "
                + "again on the next scan.", cName: "[SharedFolder]")
            return Resolution(url: fallbackURL, refreshedEntry: refreshed, access: nil)
        }

        let access = SecurityScopedAccess.acquire(url: scopedURL, folderID: id,
                                                  displayName: displayName)
        Logger.log("MIGRATED \(tag) to a security-scoped bookmark at "
            + "\(scopedURL.path(percentEncoded: false)) and adopted it for this "
            + "session. Access to this folder no longer depends on anything ambient.",
                   cName: "[SharedFolder]")
        return Resolution(url: scopedURL, refreshedEntry: refreshed, access: access)
    }

    // "Reachable" has to mean READABLE, not merely present.
    //
    // fileExists alone was enough before the sandbox and is actively misleading
    // under it: stat() on a path can be permitted while opendir() on the same path
    // is refused, so a folder this app cannot read at all still answered yes here.
    // The consequences ran the whole length of the app — the folder was reported
    // available in the settings window, counted in "Serving N folders", and
    // published to every client as a container that then turned out to be empty,
    // with nothing anywhere saying why. That is precisely the healthy-looking,
    // serves-nothing failure the rest of this codebase exists to eliminate.
    //
    // Opening the directory for reading is the right test because it is the exact
    // operation the content walk performs (opendir is open with O_DIRECTORY), and it
    // is O(1) — it opens the handle without enumerating it, so this stays cheap even
    // for a folder holding thousands of films. System's FileDescriptor does that
    // through a safe, throwing interface, with no raw DIR pointer to manage.
    private static func isReachableDirectory(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        guard url.isExistingDirectory else { return false }

        do {
            let handle = try FileDescriptor.open(FilePath(path), .readOnly,
                                                 options: [.directory, .closeOnExec])
            try? handle.close()
            return true
        } catch {
            let code = (error as? Errno) ?? Errno(rawValue: errno)
            Logger.log("Directory \(path) exists but cannot be opened for reading "
                + "(errno \(code.rawValue) \(code))). Treating it as "
                + "unreachable, because a folder this app cannot read would otherwise be "
                + "advertised to players as an empty one.",
                       cName: "[SharedFolder]")
            return false
        }
    }

    // MARK: - Equality
    // Compares identity and locator fields only. Two entries describing the same
    // folder are equal even if one carries freshly regenerated bookmark bytes,
    // which prevents a stale-bookmark refresh from being mistaken for a user edit.
    static func == (lhs: SharedFolder, rhs: SharedFolder) -> Bool {
        lhs.id == rhs.id
            && lhs.lastKnownPath == rhs.lastKnownPath
            && lhs.displayName == rhs.displayName
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - FolderStore
// Main-actor owner of the shared-folder list. The folders window mutates this;
// the content index reads a resolved snapshot from it. Keeping the authoritative
// list on the main actor (rather than inside the server actor) means the table UI
// never has to await anything to render, and the server pulls a Sendable snapshot
// when it needs one.
@MainActor
@Observable
final class FolderStore: Loggable {
    nonisolated static let logTag = "[FolderStore]"

    private(set) var folders: [SharedFolder]

    // Reachability caches, refreshed by applyResolution after every rescan.
    //
    // The folders table reads these instead of calling resolve() per row. That
    // matters: a data source runs on the main thread and is re-entered on every
    // reload, so resolving there turned each redraw into one blocking filesystem
    // round-trip per row — fine locally, a multi-second window freeze the moment a
    // network volume stopped answering.
    private(set) var resolvedURLs: [UUID: URL] = [:]
    private(set) var unreachableIDs: Set<UUID> = []
    // Playable files found beneath each folder by the last scan. Populated
    // separately from the resolution caches above because it is not known until the
    // content walk has finished, which happens after resolution.
    private(set) var fileCounts: [UUID: Int] = [:]
    // False until the first resolution completes, so the UI can distinguish
    // "not yet checked" from "checked and missing" rather than briefly libeling
    // every folder as unavailable at launch.
    private(set) var hasResolvedAtLeastOnce = false

    init() {
        self.folders = Preferences.sharedFolders
        Self.log("Loaded \(folders.count) shared folder(s) from preferences.")
    }

    // Reachability of a single entry as last observed. nil means not yet checked.
    func isReachable(_ folder: SharedFolder) -> Bool? {
        guard hasResolvedAtLeastOnce else { return nil }
        if resolvedURLs[folder.id] != nil { return true }
        if unreachableIDs.contains(folder.id) { return false }
        return nil
    }

    // MARK: - Mutation
    // Returns the reason an addition was rejected, or nil on success. The folders
    // window turns a non-nil result into an alert sheet.
    enum AddRejection {
        case duplicate(existing: String)
        case nestedInside(parent: String)
        case containsExisting(child: String)
        case notADirectory

        var message: String {
            switch self {
            case .duplicate(let existing):
                return "“\(existing)” is already in the list of shared folders."
            case .nestedInside(let parent):
                return "This folder is already being shared as part of “\(parent)”."
            case .containsExisting(let child):
                return "This folder contains “\(child)”, which is already shared. Remove the existing entry first if you want to share the parent folder instead."
            case .notADirectory:
                return "Only folders can be shared."
            }
        }
    }

    @discardableResult
    func add(url: URL) -> AddRejection? {
        guard url.isExistingDirectory else {
            return .notADirectory
        }

        // Nesting checks operate on resolved, standardized paths so that symlinks and
        // trailing-slash differences cannot smuggle a duplicate past the comparison.
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL
        let candidatePath = candidate.path(percentEncoded: false)

        for existing in folders {
            // Compares against the last resolved location, falling back to the
            // recorded path. Deliberately does NOT re-resolve: this runs on the main
            // thread in response to a button press, and an offline network mount
            // would otherwise stall the open panel's completion for the whole mount
            // timeout. A stale comparison is an acceptable price; the worst case is
            // that a nested folder slips through while its drive is offline, and the
            // next rescan simply publishes both.
            let existingURL = (resolvedURLs[existing.id]
                ?? URL(filePath: existing.lastKnownPath, directoryHint: .isDirectory))
                .resolvingSymlinksInPath().standardizedFileURL
            let existingPath = existingURL.path(percentEncoded: false)

            if existingPath == candidatePath {
                return .duplicate(existing: existing.displayName)
            }
            // Sharing both a folder and something inside it would publish the same
            // files twice under different container trees, which some players handle
            // badly and which makes the browse tree confusing regardless.
            if candidate.isContained(in: existingURL) {
                return .nestedInside(parent: existing.displayName)
            }
            if existingURL.isContained(in: candidate) {
                return .containsExisting(child: existing.displayName)
            }
        }

        let entry = SharedFolder(url: url)
        folders.append(entry)
        persist()
        Self.log("Added shared folder '\(entry.displayName)' (\(candidatePath)).")
        return nil
    }

    func remove(atOffsets offsets: IndexSet) -> [SharedFolder] {
        let removed = offsets.compactMap { folders.indices.contains($0) ? folders[$0] : nil }
        guard !removed.isEmpty else { return [] }
        folders.remove(atOffsets: offsets)
        relinquishScopes(for: removed)
        persist()
        Self.log("Removed shared folder(s): \(removed.map(\.displayName).joined(separator: ", ")).")
        return removed
    }

    // Re-inserts a previously removed batch at its original indices. Used by the
    // folders window's undo support, mirroring STabPK's deletion stack.
    func reinsert(_ batch: [(index: Int, folder: SharedFolder)]) {
        // Ascending order is what makes the recorded indices correct as-is: each
        // insertion restores one slot, so by the time the next entry is placed the
        // array is already the right length beneath it. Adding the loop's own
        // offset on top — which this used to do — double-counted that restoration
        // and pushed every entry after the first one slot too far right, so undoing
        // a multi-row deletion of non-adjacent rows silently reordered the list.
        for item in batch.sorted(by: { $0.index < $1.index }) {
            folders.insert(item.folder, at: min(item.index, folders.count))
        }
        persist()
        Self.log("Restored \(batch.count) shared folder(s) via undo.")
    }

    private func persist() {
        Preferences.sharedFolders = folders
    }

    // MARK: - Resolution
    // Resolving a folder means touching the filesystem: resolving a bookmark and
    // stat-ing the result. On a healthy local disk that is microseconds. On a
    // network mount whose server has gone away it can block for the full NFS/SMB
    // timeout — tens of seconds — and this app exists to serve exactly that kind of
    // volume. So resolution never runs on the main actor: the list is snapshotted
    // here, resolved in a detached task, and the outcome applied back. The
    // alternative is a menu bar and settings window that freeze whenever a drive
    // drops off, which is precisely when the user needs them responsive.

    struct ResolutionOutcome: Sendable {
        let reachable: [ResolvedFolder]
        let unreachable: [SharedFolder]
        // Entries whose bookmark or path was rewritten during resolution and which
        // therefore need persisting.
        let refreshed: [SharedFolder]
        // Live security-scoped grants, one per reachable folder that came from a
        // bookmark, keyed by folder. These are OWNED by whoever receives this
        // outcome: applyResolution installs them and releases whatever they replace,
        // and nothing else in the app may relinquish them. Kept out of
        // ResolvedFolder so that stays a plain comparable value type.
        let scopes: [UUID: SecurityScopedAccess]
    }

    struct ResolvedFolder: Sendable, Equatable {
        let id: UUID
        let displayName: String
        let url: URL
    }

    // Performs the blocking work. Nonisolated and static so it can run detached.
    nonisolated static func resolveAll(_ folders: [SharedFolder]) -> ResolutionOutcome {
        var reachable: [ResolvedFolder] = []
        var unreachable: [SharedFolder] = []
        var refreshed: [SharedFolder] = []
        var scopes: [UUID: SecurityScopedAccess] = [:]
        let started = ContinuousClock.now

        for entry in folders {
            guard let resolution = entry.resolve() else {
                unreachable.append(entry)
                log("Shared folder '\(entry.displayName)' "
                    + "(\(SecurityScopedAccess.shortID(entry.id))) is currently "
                    + "unreachable (\(entry.lastKnownPath)).")
                continue
            }
            if let refreshedEntry = resolution.refreshedEntry {
                refreshed.append(refreshedEntry)
            }
            if let access = resolution.access { scopes[entry.id] = access }
            reachable.append(ResolvedFolder(id: entry.id,
                                            displayName: entry.displayName,
                                            url: resolution.url))
        }

        // One line per resolution round. The three counts together are what makes a
        // later reading of the log able to say whether a folder that stopped working
        // stopped resolving, stopped being grantable, or stopped existing.
        log("Resolved \(folders.count) shared folder(s) in \(ContinuousClock.now - started): "
            + "\(reachable.count) reachable, \(unreachable.count) unreachable, "
            + "\(scopes.count) security scope(s) acquired, "
            + "\(refreshed.count) entry/entries rewritten.")

        return ResolutionOutcome(reachable: reachable, unreachable: unreachable,
                                 refreshed: refreshed, scopes: scopes)
    }

    // Applies a resolution outcome: persists any regenerated bookmarks and updates
    // the reachability caches the UI renders from.
    func applyResolution(_ outcome: ResolutionOutcome) {
        installScopes(from: outcome)

        var didChangeEntries = false
        for entry in outcome.refreshed {
            guard let index = folders.firstIndex(where: { $0.id == entry.id }) else { continue }
            folders[index] = entry
            didChangeEntries = true
        }
        // Written unconditionally when anything was refreshed. Preferences.sharedFolders
        // persists on every set and notifies only on a user-visible change, so this
        // stores the new bookmark bytes without triggering a redundant rescan.
        if didChangeEntries { Preferences.sharedFolders = folders }

        var urls: [UUID: URL] = [:]
        for folder in outcome.reachable { urls[folder.id] = folder.url }
        resolvedURLs = urls
        unreachableIDs = Set(outcome.unreachable.map(\.id))
        hasResolvedAtLeastOnce = true
    }

    func applyFileCounts(_ counts: [UUID: Int]) {
        fileCounts = counts
    }

    // MARK: - Security-scoped access ownership
    // Exactly one live grant per reachable shared folder, held for as long as that
    // folder is being served. This dictionary is the app's only owner of them.
    private var activeScopes: [UUID: SecurityScopedAccess] = [:]

    // Swaps in the grants a resolution round produced and releases everything they
    // supersede. Every acquisition is matched here exactly once, which is what lets
    // the watchdog treat a count mismatch as a real signal.
    private func installScopes(from outcome: ResolutionOutcome) {
        for (id, incoming) in outcome.scopes {
            if let previous = activeScopes[id], previous !== incoming {
                previous.relinquish(reason: "superseded by a fresh grant from this "
                    + "resolution round")
            }
            activeScopes[id] = incoming
        }

        // Anything still held that this round did not renew is either a folder that
        // has gone unreachable or one the user removed. Both must release now: a
        // grant kept for a folder nothing is serving is a leak, and it would make the
        // inventory below lie about how many are genuinely in use.
        let listedIDs = Set(folders.map(\.id))
        for (id, held) in activeScopes where outcome.scopes[id] == nil {
            held.relinquish(reason: listedIDs.contains(id)
                ? "the folder is no longer reachable"
                : "the folder was removed from the shared list")
            activeScopes.removeValue(forKey: id)
        }
    }

    // Immediate release when the user removes folders, rather than waiting for the
    // rescan that follows to notice. The rescan is still the backstop and
    // relinquish is idempotent, so doing both is safe and the prompt one is what
    // keeps the log's ordering readable: the release lands next to the removal that
    // caused it instead of a second later next to unrelated rescan traffic.
    private func relinquishScopes(for removed: [SharedFolder]) {
        for entry in removed {
            guard let held = activeScopes.removeValue(forKey: entry.id) else { continue }
            held.relinquish(reason: "the user removed the folder from the shared list")
        }
    }

    // Released together at termination so the log records a clean teardown, and so a
    // grant is never left outstanding against a process that is going away.
    func relinquishAllScopes(reason: String) {
        guard !activeScopes.isEmpty else { return }
        Self.log("Releasing \(activeScopes.count) security scope(s): \(reason).")
        for (_, held) in activeScopes { held.relinquish(reason: reason) }
        activeScopes.removeAll()
    }

    // The health watchdog's view. Reachable folders and held grants must agree —
    // every reachable folder needs one to be readable at all, and a grant with no
    // reachable folder behind it is a leak. A mismatch is reported rather than
    // corrected, because the useful thing is knowing it happened and when.
    var securityScopeAudit: String {
        let held = activeScopes.values.filter(\.isHeld).count
        let stale = activeScopes.count - held
        let reachable = resolvedURLs.count
        var line = "\(held) security scope(s) held for \(reachable) reachable folder(s) "
        line += "of \(folders.count) shared"
        if stale > 0 { line += ", \(stale) tracked but already released" }
        return line
    }

    // Non-nil only when the books genuinely do not balance, so the watchdog can
    // check this every minute and stay silent unless there is something to say.
    //
    // Only meaningful inside the sandbox. Outside it a reachable folder with no
    // grant is perfectly normal — nothing needs granting — so raising it there
    // would be an alarm that fires on correct behavior, which is the fastest way to
    // teach someone to ignore a log line.
    var securityScopeProblem: String? {
        guard SandboxEnvironment.isSandboxed else { return nil }
        let held = activeScopes.values.filter(\.isHeld).count
        let reachable = resolvedURLs.count
        guard held != reachable else { return nil }

        if held < reachable {
            let missing = folders
                .filter { resolvedURLs[$0.id] != nil && activeScopes[$0.id]?.isHeld != true }
                .map { "'\($0.displayName)' (\(SecurityScopedAccess.shortID($0.id)))" }
            return "SCOPE MISMATCH: \(reachable) folder(s) are being served but only "
                + "\(held) security grant(s) are held. Without a grant nothing beneath "
                + "a folder can be read, so anything a player asks for there will fail "
                + "as though the files were missing. Ungranted: "
                + (missing.isEmpty ? "could not be identified" :
                    missing.joined(separator: ", ")) + "."
        }
        return "SCOPE MISMATCH: \(held) security grant(s) are held but only "
            + "\(reachable) folder(s) are reachable, so \(held - reachable) grant(s) "
            + "are being retained for folders nothing is serving. That is a leak in "
            + "this app's own bookkeeping rather than anything the user did."
    }
}

// MARK: - URL containment helper
private extension URL {
    // True when this URL sits inside 'other'. Compares resolved path components so
    // that "/Volumes/Media2" is correctly NOT considered a child of "/Volumes/Media",
    // which a naive string-prefix check would get wrong.
    func isContained(in other: URL) -> Bool {
        let selfComponents = self.pathComponents
        let otherComponents = other.pathComponents
        guard selfComponents.count > otherComponents.count else { return false }
        return Array(selfComponents.prefix(otherComponents.count)) == otherComponents
    }
}

extension URL {
    // True when the item exists and is a directory, following symbolic links the way
    // FileManager.fileExists(atPath:isDirectory:) does. Reading the resource value
    // replaces that call's ObjCBool out-pointer, which strict memory safety flags;
    // the symlink resolution matters because a resource value read on the link
    // itself would report "not a directory" for a link to a folder.
    var isExistingDirectory: Bool {
        (try? resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?
            .isDirectory == true
    }
}

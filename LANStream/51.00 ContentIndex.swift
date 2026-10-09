// MARK: - ContentIndex.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The in-memory content tree LAN Stream publishes over ContentDirectory.
//
// The index is a flat dictionary of nodes keyed by UPnP object ID, built by
// walking the shared folders.
//
// The walk itself runs OUTSIDE the actor, in a detached task, and only the
// finished node dictionary is handed back for a swap. This is the difference
// between a rescan that is invisible to clients and one that stalls playback:
// an actor-isolated scan would hold the executor for its whole duration, and
// every concurrent Browse or media request would queue behind it — for a large
// external drive, that is seconds of a frozen player. Actor isolation makes the
// swap atomic; it does not by itself make the scan non-blocking.
//
// Object ID stability
// -------------------
// IDs are derived from a hash of each node's path relative to the shared-folder
// root, NOT from a scan-order counter. This matters: control points cache object
// IDs, and the Oppo will re-request a container by ID after the index has been
// rebuilt in the background. Sequence-number IDs would silently point at a
// different folder after any rescan that added or removed a file; path-derived
// IDs address the same node for as long as that node exists.

import Foundation

// MARK: - MediaNode
// One entry in the published tree. Value type so snapshots can cross actor
// boundaries freely.
struct MediaNode: Sendable, Equatable {

    enum Kind: Sendable, Equatable {
        // A browsable folder. 'childIDs' is pre-sorted for presentation:
        // containers first, then items, each alphabetically case-insensitive.
        case container(childIDs: [String])
        // A playable file. 'durationSeconds' is nil when the running time could not
        // be read out of the container header, which is a normal outcome and simply
        // means the res element goes out without a duration attribute.
        case item(url: URL, byteSize: Int64, durationSeconds: Double?)
    }

    let id: String
    let parentID: String
    let title: String
    let kind: Kind

    var childCount: Int {
        if case .container(let childIDs) = kind { return childIDs.count }
        return 0
    }

    // Lowercase, without the dot, and empty for a container. Read from the URL
    // rather than stored alongside it so there is exactly one source of truth for
    // what a node's file actually is.
    var fileExtension: String {
        guard case .item(let url, _, _) = kind else { return "" }
        return url.pathExtension.lowercased()
    }
}

// MARK: - ContentSnapshot
// An immutable view of the whole tree. Handed to the ContentDirectory service so
// a single Browse is always answered from one internally consistent version of
// the index, even if a rescan completes midway through serving a response.
struct ContentSnapshot: Sendable {
    let nodes: [String: MediaNode]
    let updateID: UInt32
    let fileCount: Int
    // Per shared folder, how many playable files were found anywhere beneath it.
    // Keyed by the folder's stable identity rather than its object ID so the
    // settings table can look a row up without knowing anything about UPnP.
    let fileCountsByFolderID: [UUID: Int]

    static let empty = ContentSnapshot(nodes: [ContentIndex.rootObjectID:
                                                MediaNode(id: ContentIndex.rootObjectID,
                                                          parentID: "-1",
                                                          title: Preferences.defaultFriendlyName,
                                                          kind: .container(childIDs: []))],
                                       updateID: 1,
                                       fileCount: 0,
                                       fileCountsByFolderID: [:])

    func node(withID id: String) -> MediaNode? { nodes[id] }
}

// MARK: - ContentIndex
actor ContentIndex: Loggable {
    nonisolated static let logTag = "[ContentIndex]"

    // UPnP reserves "0" for the root container. This is not a convention we are
    // free to change: control points hard-code it as the starting point of a browse.
    static let rootObjectID = "0"

    // The extensions published, resolved from the user's container-format setting
    // once per scan rather than per file. Reading the preference inside the walk
    // would mean a setting changed mid-scan produced a tree that was half one
    // whitelist and half the other.
    static var allowedExtensions: Set<String> {
        Preferences.containerFormats.fileExtensions
    }

    private var snapshot: ContentSnapshot = .empty

    // Monotonic UPnP SystemUpdateID. Incremented on every rebuild that changes the
    // tree; clients use it to decide whether their cached view is still valid.
    private var updateID: UInt32 = 1

    // MARK: - Read
    func currentSnapshot() -> ContentSnapshot { snapshot }

    // MARK: - Rebuild
    // Walks every reachable shared folder and replaces the published tree.
    // Returns the new snapshot so the caller can update UI status in one hop.
    //
    // Unreachable folders are deliberately NOT passed in. They are status
    // information rather than content, the caller already holds the list for
    // ServerStatus, and carrying a copy through here only invited it to be
    // mistaken for something the published tree depends on.
    @discardableResult
    func rebuild(from folders: [FolderStore.ResolvedFolder]) async -> ContentSnapshot {

        let started = ContinuousClock.now
        let rootTitle = Preferences.friendlyName
        let extensions = Self.allowedExtensions

        // The filesystem walk runs detached. Only Sendable values cross in and out,
        // and this actor stays free to answer Browse and media requests for the
        // entire duration of the scan.
        // Durations already known from the published tree, so a rescan re-reads only
        // the files that are actually new or changed.
        //
        // This is what keeps the feature affordable. Reading a container header costs
        // an open, a seek and a few kilobytes, which is nothing for one file and adds
        // up across a library of a few hundred on an external drive that may have to
        // spin up — and rescans are triggered by every folder change and every volume
        // mount, not just by startup. Reusing by object ID is reusing by path, since
        // the ID is a hash of it; the byte size is carried alongside as the validator,
        // because a video file that is edited or replaced essentially never lands on
        // its previous length to the byte.
        let knownDurations = Self.durationCache(from: snapshot.nodes)

        let built = await Task.detached(priority: .utility) {
            Self.buildTree(from: folders, rootTitle: rootTitle,
                           allowedExtensions: extensions,
                           knownDurations: knownDurations)
        }.value

        let nodes = built.nodes
        let fileCount = built.fileCount
        let containerCount = built.containerCount

        let newSnapshot = ContentSnapshot(nodes: nodes,
                                          updateID: updateID &+ 1,
                                          fileCount: fileCount,
                                          fileCountsByFolderID: built.fileCountsByFolderID)

        // Only bump the update ID when the tree actually differs. A no-op rescan
        // that bumped it would tell every client to discard a still-valid cache.
        if Self.treeDiffers(snapshot.nodes, newSnapshot.nodes) {
            updateID &+= 1
            snapshot = newSnapshot
            let elapsed = ContinuousClock.now - started
            Self.log("Rebuilt index: \(fileCount) file(s) in \(containerCount) container(s) across \(folders.count) shared folder(s) in \(elapsed). SystemUpdateID now \(updateID).\(built.durationSummary)")
        } else {
            // The tree is unchanged, so the nodes and updateID are carried over
            // verbatim — a client's cached view is still valid and must not be
            // invalidated.
            //
            // This branch is NOT redundant, and it is worth saying why: the counts
            // are rebuilt even when the tree is not. Both are read straight off the
            // returned snapshot by DLNAServer.performRescan — fileCount for the menu
            // bar's summary and fileCountsByFolderID for the folders table — so
            // returning the old snapshot here would freeze those numbers at whatever
            // the last content-changing scan produced.
            snapshot = ContentSnapshot(nodes: snapshot.nodes,
                                       updateID: updateID,
                                       fileCount: fileCount,
                                       fileCountsByFolderID: built.fileCountsByFolderID)
            Self.log("Rescan complete: no content changes (\(fileCount) file(s)).\(built.durationSummary)")
        }
        return snapshot
    }

    // MARK: - Directory walk
    private struct ScanResult {
        var fileCount = 0
        var containerCount = 0
        // How the running times in this subtree were obtained. Reported on the
        // rebuild line, because the cost of this feature is entirely in 'read' and
        // there is otherwise no way to tell a scan that reused everything from one
        // that opened several hundred files on a sleeping external drive.
        var durationsRead = 0
        var durationsReused = 0
        var durationsUnknown = 0

        mutating func add(_ other: ScanResult) {
            fileCount += other.fileCount
            containerCount += other.containerCount
            durationsRead += other.durationsRead
            durationsReused += other.durationsReused
            durationsUnknown += other.durationsUnknown
        }
    }

    struct BuiltTree: Sendable {
        let nodes: [String: MediaNode]
        let fileCount: Int
        let containerCount: Int
        let fileCountsByFolderID: [UUID: Int]
        let durationsRead: Int
        let durationsReused: Int
        let durationsUnknown: Int

        // Only worth a clause on the rebuild line when there is something to say.
        var durationSummary: String {
            guard durationsRead + durationsReused + durationsUnknown > 0 else { return "" }
            var text = " Running times: \(durationsRead) read from file headers, "
                + "\(durationsReused) reused from the previous scan"
            if durationsUnknown > 0 { text += ", \(durationsUnknown) unavailable" }
            return text + "."
        }
    }

    // Walks every shared folder and assembles the complete node table, including
    // the root container. Nonisolated and static: it touches no actor state, which
    // is what allows it to run in a detached task.
    // Object ID to the byte size it had and the duration read from it.
    typealias DurationCache = [String: (byteSize: Int64, durationSeconds: Double?)]

    private nonisolated static func durationCache(from nodes: [String: MediaNode]) -> DurationCache {
        var cache: DurationCache = [:]
        for (id, node) in nodes {
            guard case .item(_, let byteSize, let duration) = node.kind else { continue }
            // Files whose duration could not be read are cached as a nil duration
            // rather than left out, so an unreadable header is attempted once per
            // change rather than on every rescan for the life of the process.
            cache[id] = (byteSize, duration)
        }
        return cache
    }

    private nonisolated static func buildTree(from folders: [FolderStore.ResolvedFolder],
                                              rootTitle: String,
                                              allowedExtensions: Set<String>,
                                              knownDurations: DurationCache) -> BuiltTree {
        var nodes: [String: MediaNode] = [:]
        var rootChildIDs: [String] = []
        var fileCount = 0
        var containerCount = 0
        var fileCountsByFolderID: [UUID: Int] = [:]
        var totals = ScanResult()

        // Each shared folder becomes a top-level container beneath the root.
        for folder in nonOverlapping(folders) {
            let folderID = objectID(forPath: folder.url.path(percentEncoded: false))
            let result = scanDirectory(at: folder.url,
                                       objectID: folderID,
                                       parentID: rootObjectID,
                                       title: folder.displayName,
                                       depth: 0,
                                       allowedExtensions: allowedExtensions,
                                       knownDurations: knownDurations,
                                       into: &nodes)
            totals.add(result)
            fileCountsByFolderID[folder.id] = result.fileCount
            // A shared folder with no playable content anywhere beneath it is still
            // published. Hiding it would make an empty drive indistinguishable from
            // a server malfunction from the player's side, which is precisely the
            // ambiguity this app exists to eliminate.
            rootChildIDs.append(folderID)
            fileCount += result.fileCount
            containerCount += result.containerCount
        }

        // Top-level containers are sorted by display name so the player's list
        // ordering is stable regardless of preference-list order.
        rootChildIDs.sort { lhs, rhs in
            let lhsTitle = nodes[lhs]?.title ?? ""
            let rhsTitle = nodes[rhs]?.title ?? ""
            return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedAscending
        }

        nodes[rootObjectID] = MediaNode(id: rootObjectID,
                                        parentID: "-1",
                                        title: rootTitle,
                                        kind: .container(childIDs: rootChildIDs))

        return BuiltTree(nodes: nodes, fileCount: fileCount,
                         containerCount: containerCount,
                         fileCountsByFolderID: fileCountsByFolderID,
                         durationsRead: totals.durationsRead,
                         durationsReused: totals.durationsReused,
                         durationsUnknown: totals.durationsUnknown)
    }

    // The folders that can be published without colliding.
    //
    // Object IDs are hashes of absolute paths, so two shared folders that overlap
    // publish the SAME IDs: a folder listed twice puts one ID in the root's child
    // list twice, and a folder shared alongside its own parent has every node
    // beneath it walked twice, with whichever walk ran last deciding its parentID —
    // a tree whose parent links contradict its child lists. FolderStore.add refuses
    // both, but not every route into the list goes through it: undoing a removal
    // re-inserts without checking (remove A, add A again, undo), and a bookmark can
    // resolve to a new location that happens to sit inside another share.
    //
    // The shallowest path wins, so a parent is kept over anything inside it and
    // nothing the user shared becomes unreachable. Ties keep list order.
    private nonisolated static func nonOverlapping(
        _ folders: [FolderStore.ResolvedFolder]
    ) -> [FolderStore.ResolvedFolder] {
        let candidates = folders
            .map { (folder: $0, components: $0.url.standardizedFileURL.pathComponents) }
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.components.count != rhs.element.components.count
                    ? lhs.element.components.count < rhs.element.components.count
                    : lhs.offset < rhs.offset
            }
            .map(\.element)

        var kept: [(folder: FolderStore.ResolvedFolder, components: [String])] = []
        for candidate in candidates {
            if let covering = kept.first(where: {
                candidate.components.starts(with: $0.components)
            }) {
                log("WARNING: Not publishing '\(candidate.folder.displayName)' "
                    + "(\(candidate.folder.url.path(percentEncoded: false))) as a "
                    + "separate share: it is the same folder as, or lies inside, "
                    + "'\(covering.folder.displayName)', which already publishes its "
                    + "contents. Remove one of the two entries in Shared Folders.")
                continue
            }
            kept.append(candidate)
        }
        return kept.map(\.folder)
    }

    // Hard ceiling on recursion depth. scanDirectory refuses to follow symlinks, so
    // an unbounded tree should be impossible — but "should be" is doing a lot of
    // work on a machine mounting arbitrary network shares, where a server-side
    // loop can present an endlessly nested path that looks like real directories.
    // Recursion here runs on a task stack, and overflowing it crashes the process
    // rather than raising an error, so the depth is bounded explicitly.
    private static let maximumScanDepth = 64

    // Recursively scans 'url', registering a container node for it and nodes for
    // every qualifying descendant. Recursion depth is bounded by the filesystem;
    // symlinked directories are not followed, which prevents a self-referential
    // link from producing an infinite tree.
    private nonisolated static func scanDirectory(at url: URL,
                                                  objectID: String,
                                                  parentID: String,
                                                  title: String,
                                                  depth: Int,
                                                  allowedExtensions: Set<String>,
                                                  knownDurations: DurationCache,
                                                  into nodes: inout [String: MediaNode])
        -> ScanResult {

        var result = ScanResult()
        result.containerCount = 1

        guard depth < maximumScanDepth else {
            log("WARNING: Depth limit (\(maximumScanDepth)) reached at \(url.path(percentEncoded: false)); not descending further.")
            nodes[objectID] = MediaNode(id: objectID, parentID: parentID,
                                        title: title, kind: .container(childIDs: []))
            return result
        }

        var childContainers: [(id: String, title: String)] = []
        var childItems: [(id: String, title: String)] = []

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey,
                                      .fileSizeKey, .isRegularFileKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        } catch {
            // FileAccessDiagnosis rather than localizedDescription: inside the
            // sandbox "could not read" covers both a folder that is gone and one
            // this app is not permitted to enter, and those are a hardware problem
            // and a scope bug respectively.
            log("WARNING: Could not read directory \(url.path(percentEncoded: false)): "
                + "\(FileAccessDiagnosis.describe(error))")
            nodes[objectID] = MediaNode(id: objectID, parentID: parentID,
                                        title: title, kind: .container(childIDs: []))
            return result
        }

        for child in contents {
            let values = try? child.resourceValues(forKeys: Set(keys))

            // Never traverse a symlink. Following one risks both duplicate content
            // and, for a link pointing at an ancestor, unbounded recursion.
            if values?.isSymbolicLink == true { continue }

            let childPath = child.path(percentEncoded: false)
            let childID = Self.objectID(forPath: childPath)

            if values?.isDirectory == true {
                let childTitle = child.lastPathComponent
                let sub = scanDirectory(at: child,
                                        objectID: childID,
                                        parentID: objectID,
                                        title: childTitle,
                                        depth: depth + 1,
                                        allowedExtensions: allowedExtensions,
                                        knownDurations: knownDurations,
                                        into: &nodes)
                result.add(sub)
                childContainers.append((childID, childTitle))
                continue
            }

            guard values?.isRegularFile == true,
                  allowedExtensions.contains(child.pathExtension.lowercased())
            else { continue }

            // res@size is mandatory in our DIDL output; a file whose size cannot be
            // read is skipped rather than published with a wrong or absent length,
            // which would break the player's seek bar and progress display.
            guard let size = values?.fileSize else {
                // Worth naming the folder as well as the file: a sandbox denial hits
                // every entry beneath one root at once, so "which root" is the
                // question a reader of this line is about to ask.
                log("WARNING: Skipping \(childPath) — file size unavailable, so its "
                    + "res@size could not be published. A run of these under one shared "
                    + "folder usually means access to that folder was lost rather than "
                    + "anything being wrong with the individual files.")
                continue
            }

            let byteSize = Int64(size)
            let duration: Double?
            if let cached = knownDurations[childID], cached.byteSize == byteSize {
                duration = cached.durationSeconds
                result.durationsReused += 1
            } else {
                duration = MediaDuration.seconds(forFileAt: child)
                result.durationsRead += 1
            }
            if duration == nil { result.durationsUnknown += 1 }

            let itemTitle = child.deletingPathExtension().lastPathComponent
            nodes[childID] = MediaNode(id: childID,
                                       parentID: objectID,
                                       title: itemTitle,
                                       kind: .item(url: child,
                                                   byteSize: byteSize,
                                                   durationSeconds: duration))
            childItems.append((childID, itemTitle))
            result.fileCount += 1
        }

        // Containers before items, each alphabetically. localizedStandardCompare
        // gives the Finder-style natural ordering users expect, so "Episode 2" sorts
        // before "Episode 10" rather than after it.
        let sortByTitle: ((id: String, title: String), (id: String, title: String)) -> Bool = {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        childContainers.sort(by: sortByTitle)
        childItems.sort(by: sortByTitle)

        let orderedChildIDs = childContainers.map(\.id) + childItems.map(\.id)
        nodes[objectID] = MediaNode(id: objectID, parentID: parentID,
                                    title: title,
                                    kind: .container(childIDs: orderedChildIDs))
        return result
    }

    // MARK: - Object ID derivation
    // 64-bit FNV-1a over the absolute path, rendered as 16 hex digits. Deterministic
    // across launches and rescans, opaque to the client, and free of any character
    // that would need escaping in a URL or in XML — which is the other half of why
    // paths are never used directly as object IDs.
    nonisolated static func objectID(forPath path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        // "0" is reserved for the root container; on the vanishingly unlikely chance
        // a real path hashes to it, shift off the collision.
        let value = hash == 0 ? 1 : hash
        return value.zeroPadded(16, radix: 16)
    }

    // Structural comparison used to decide whether SystemUpdateID must advance.
    // Compares the set of IDs and each node's presentation-relevant fields; a change
    // in a file's byte size counts, since that invalidates a client's cached res@size.
    private nonisolated static func treeDiffers(_ lhs: [String: MediaNode],
                                                _ rhs: [String: MediaNode]) -> Bool {
        guard lhs.count == rhs.count else { return true }
        for (id, lhsNode) in lhs {
            guard let rhsNode = rhs[id], rhsNode == lhsNode else { return true }
        }
        return false
    }
}

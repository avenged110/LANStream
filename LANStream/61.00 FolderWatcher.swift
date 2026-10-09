// MARK: - FolderWatcher.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Filesystem monitoring for the shared folders.
//
// The content index is a snapshot: browse requests are answered from an
// in-memory table rather than by walking the disk, because a player expects a
// listing in milliseconds and a drive full of films takes far longer than that
// to enumerate. The snapshot therefore has to be told when it has gone stale.
//
// This class is how it finds out. FSEvents reports changes beneath the watched
// roots and the app rebuilds; nothing is polled and nothing is read while the
// folders sit idle. An earlier version re-walked every five minutes on a timer,
// which meant a newly added film could take that long to appear and the disk was
// touched constantly for no reason.
//
// The one real limitation is that FSEvents does not deliver events for files on
// network mounts. That is a property of the volume, not of this code, so the
// caller checks volume locality and arranges its own fallback for remote ones —
// see DLNAServer.

import Foundation
import CoreServices

// FSEvents hands its callback a raw context pointer, so this type must be
// reachable from a C function. It is @unchecked Sendable because its mutable
// state is confined to the serial queue the stream is scheduled on, plus the
// start/stop calls made from the owning actor, which never overlap.
//
// @safe because the raw FSEventStreamRef never leaves this class: it is created,
// scheduled and released here, and teardown is serialized on the stream's own
// queue (see stopStream), so callers see only a safe start/stop interface.
@safe final class FolderWatcher: @unchecked Sendable, Loggable {
    nonisolated static let logTag = "[FolderWatcher]"

    // Coalescing window handed to FSEvents. Copying a film into a shared folder
    // produces a burst of events; a second of latency collapses that burst into
    // one callback so the index is rebuilt once at the end rather than repeatedly
    // while the copy is still running.
    private static let latencySeconds: CFTimeInterval = 1.0

    private let queue = DispatchQueue(label: "app.LANStream.fsevents", qos: .utility)
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit { stopStream() }

    // MARK: - Control
    // Returns whether change detection is actually in place. The caller MUST act on
    // a false: this used to return Void and merely log "falling back to periodic
    // rescans", which was a promise nothing kept — the caller enabled the fallback
    // timer only for folders on remote volumes, so a watcher that failed to install
    // over local folders left the index frozen with no timer and no events, and the
    // only visible symptom was newly added films never appearing.
    //
    // An empty path list returns true: there is nothing to watch, which is a
    // correct and healthy state rather than a failure needing a fallback.
    @discardableResult
    func start(watching paths: [String]) -> Bool {
        stopStream()
        guard !paths.isEmpty else {
            Self.log("No folders to watch — filesystem event stream not installed.")
            return true
        }

        var context = unsafe FSEventStreamContext(
            version: 0,
            info: unsafe Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)

        // kFSEventStreamCreateFlagWatchRoot also reports the watched directory
        // itself being renamed, moved, or deleted — which for this app is the
        // difference between noticing that a whole shared folder vanished and
        // silently continuing to advertise its contents.
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagWatchRoot)

        guard let newStream = unsafe FSEventStreamCreate(
            kCFAllocatorDefault,
            folderWatcherCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latencySeconds,
            flags) else {
            Self.log("ERROR: FSEventStreamCreate returned nil for \(paths.count) path(s) "
                + "(\(paths.joined(separator: ", "))). No filesystem events will be "
                + "delivered for these folders; the caller must fall back to periodic "
                + "rescans or new files will never be noticed.")
            return false
        }

        unsafe FSEventStreamSetDispatchQueue(newStream, queue)
        guard unsafe FSEventStreamStart(newStream) else {
            Self.log("ERROR: FSEventStreamStart failed for \(paths.count) path(s) "
                + "(\(paths.joined(separator: ", "))). The stream was created but could "
                + "not be scheduled, so no filesystem events will arrive; the caller "
                + "must fall back to periodic rescans.")
            unsafe FSEventStreamInvalidate(newStream)
            unsafe FSEventStreamRelease(newStream)
            return false
        }

        unsafe stream = newStream
        Self.log("Watching \(paths.count) folder(s) for changes: \(paths.joined(separator: ", ")).")
        return true
    }

    func stop() { stopStream() }

    // Non-isolated teardown, safe to call from deinit and repeatedly.
    //
    // The invalidation runs synchronously ON the stream's own queue. Callbacks are
    // delivered on that queue, so a barrier there is what guarantees none is
    // mid-flight when the stream is released — and since the FSEvents context holds
    // this object UNRETAINED, a callback that outlived the release would be reading
    // freed memory. Tearing down from an arbitrary thread leaves exactly that window
    // open. There is no deadlock risk: nothing running on the queue ever calls back
    // into this method, so the barrier can never wait on itself.
    private func stopStream() {
        guard let stream = unsafe stream else { return }
        unsafe self.stream = nil
        queue.sync {
            unsafe FSEventStreamStop(stream)
            unsafe FSEventStreamInvalidate(stream)
            unsafe FSEventStreamRelease(stream)
        }
    }

    // Called from the C callback on the stream's queue.
    fileprivate func handleEvents(count: Int) {
        Self.log("Filesystem change detected (\(count) event(s)) — rescanning.")
        onChange()
    }
}

// MARK: - C callback
// Kept at file scope because FSEventStreamCallback is a C function pointer and
// cannot capture context; the watcher arrives through the info pointer instead.
private let folderWatcherCallback: FSEventStreamCallback = {
    _, info, numEvents, _, _, _ in
    guard let info = unsafe info else { return }
    let watcher = unsafe Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    watcher.handleEvents(count: numEvents)
}

// MARK: - Volume locality
enum VolumeLocality {
    // True when the URL resides on a locally attached volume, where FSEvents is
    // reliable. Remote mounts (SMB, NFS, AFP) return false: the kernel on this
    // machine never sees the writes another host makes, so no notification can be
    // generated for them and only a periodic re-walk can notice the change.
    //
    // An indeterminate answer is treated as remote. Being wrong in that direction
    // costs an occasional unnecessary rescan; being wrong the other way means
    // silently never noticing new files, which is the failure this whole
    // mechanism exists to prevent.
    static func isLocal(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.volumeIsLocalKey])
            return values.volumeIsLocal ?? false
        } catch {
            Logger.log("WARNING: Could not determine volume locality for \(url.path(percentEncoded: false)): \(error.localizedDescription). Assuming remote.",
                       cName: "[VolumeLocality]")
            return false
        }
    }
}

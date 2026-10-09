// MARK: - SecurityScope.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The App Sandbox side of shared-folder access: live security-scoped grants, and
// the diagnostics needed to tell a sandbox refusal apart from everything else.
//
// Why this file exists at all
// ---------------------------
// Inside the sandbox, holding a URL is not the same as being allowed to read it.
// A folder the user chose is reachable only while a security-scoped grant derived
// from its bookmark is ACTIVE, and the moment that grant lapses every read beneath
// it fails — not with a distinctive error, but with an ordinary "no such file".
// That is the whole hazard of this conversion: a scope bug does not look like a
// scope bug. It looks like an empty folder on the player, or a film that 404s, and
// the log is the only place the difference can be made visible.
//
// So the rule this file exists to enforce is simple and absolute: exactly one
// grant is acquired per reachable shared folder, it is held for as long as that
// folder is being served, and every acquisition and release says so in the log
// with the folder named. A count that drifts from the number of reachable folders
// is a bug, and the health watchdog is told how to notice it.

import Foundation
import Synchronization
import System

// MARK: - SecurityScopedAccess
// One live grant. Created by acquiring, ended by relinquishing, and safe to
// relinquish twice.
//
// Sendable, checked by the compiler: instances are created inside the detached
// resolution task and then handed to FolderStore on the main actor, so they
// genuinely cross isolation domains. The only mutable state is one Bool, held in a
// Mutex — the same pattern this codebase uses for ResumeGuard and HTTPDate.
final class SecurityScopedAccess: Sendable, Loggable {
    nonisolated static let logTag = "[SecurityScope]"

    let folderID: UUID
    let displayName: String
    let url: URL
    // Whether startAccessingSecurityScopedResource() actually returned true. False
    // is NOT necessarily a failure — see the discussion in acquire — so it is
    // recorded rather than acted on.
    let wasGranted: Bool

    private let isRelinquished = Mutex(false)

    private init(folderID: UUID, displayName: String, url: URL, wasGranted: Bool) {
        self.folderID = folderID
        self.displayName = displayName
        self.url = url
        self.wasGranted = wasGranted
    }

    // Starts a grant on a URL that came out of resolving a security-scoped bookmark.
    //
    // The URL matters: a grant can only be started on the exact URL the bookmark
    // resolution produced. Rebuilding an equal-looking URL from its path and calling
    // this on that instead is the classic way to get a silent false back, and it is
    // why SharedFolder.resolve hands this the resolved URL directly rather than a
    // path it reconstructed.
    //
    // A false return is deliberately not treated as fatal. An UNSANDBOXED build
    // routinely returns false here — there is no sandbox to lift, so there is
    // nothing to grant — while every read then succeeds anyway. Treating false as
    // failure would therefore break the app in exactly the configuration that has
    // no problem. The reachability check that follows is the real arbiter; this is
    // recorded so the log can say which of the two worlds produced the result.
    static func acquire(url: URL, folderID: UUID, displayName: String)
        -> SecurityScopedAccess {
        let granted = url.startAccessingSecurityScopedResource()
        let path = url.path(percentEncoded: false)

        if granted {
            log("Security scope ACQUIRED for '\(displayName)' (\(shortID(folderID))) at "
                + "\(path).")
        } else if SandboxEnvironment.isSandboxed {
            // Inside the sandbox this is the serious one: the bookmark resolved but
            // the system declined to lift the restriction, so nothing beneath this
            // folder can be read. Spelled out because the symptom downstream is a
            // folder that simply looks empty.
            log("ERROR: Security scope REFUSED for '\(displayName)' "
                + "(\(shortID(folderID))) at \(path). The bookmark resolved but the "
                + "system would not grant access, so no file beneath this folder can "
                + "be read and it will be reported unreachable. The usual cause is a "
                + "bookmark that was created WITHOUT the security scope option — for "
                + "example one stored by a pre-sandbox build. Removing and re-adding "
                + "the folder rebuilds it correctly.")
        } else {
            log("Security scope not granted for '\(displayName)' (\(shortID(folderID))) "
                + "at \(path), but this build is NOT sandboxed, so no grant is needed "
                + "and access is expected to work regardless.")
        }

        return SecurityScopedAccess(folderID: folderID, displayName: displayName,
                                    url: url, wasGranted: granted)
    }

    var isHeld: Bool {
        !isRelinquished.withLock { $0 }
    }

    // Ends the grant. Idempotent: the store relinquishes explicitly on removal and
    // again when reconciling, and deinit is a backstop behind both.
    //
    // Balance is the property that matters. startAccessingSecurityScopedResource is
    // reference-counted by the system, so an acquisition that is never matched here
    // leaks a grant for the life of the process, and a double release would revoke
    // access that another caller still depends on. Every acquisition in this app is
    // owned by exactly one FolderStore entry, and that entry releases it exactly
    // once — which is what makes the watchdog's count meaningful.
    func relinquish(reason: String) {
        // Swapping in true and testing the old value is one atomic step, so two
        // concurrent callers cannot both get past this point.
        let wasRelinquished = isRelinquished.withLock { value in
            defer { value = true }
            return value
        }
        if wasRelinquished { return }

        url.stopAccessingSecurityScopedResource()
        Self.log("Security scope RELEASED for '\(displayName)' (\(Self.shortID(folderID))) at "
            + "\(url.path(percentEncoded: false)) — \(reason).")
    }

    deinit {
        // Reached only if something dropped the last reference without relinquishing,
        // which would be a bug in the store's bookkeeping. It is repaired here rather
        // than leaked, and said out loud so the bug is findable.
        let leaked = isRelinquished.withLock { value in
            defer { value = true }
            return !value
        }
        if leaked {
            url.stopAccessingSecurityScopedResource()
            Self.log("WARNING: Security scope for '\(displayName)' "
                + "(\(Self.shortID(folderID))) was released by deallocation rather than "
                + "explicitly. Access has been ended correctly, but something dropped "
                + "the grant without going through relinquish(reason:) — that is a "
                + "bookkeeping bug worth finding.")
        }
    }

    // First eight characters of the UUID. Enough to correlate two log lines about
    // the same folder without putting a full UUID on every one of them.
    nonisolated static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}

// MARK: - SandboxEnvironment
// What the process can say about its own confinement. Logged once at launch,
// because every other sandbox symptom in this app is ambiguous without it: an
// unreachable folder means one thing in a sandboxed build and something completely
// different outside one.
enum SandboxEnvironment {

    // APP_SANDBOX_CONTAINER_ID is set by the system for a sandboxed process and is
    // the cheapest reliable signal available. The home-directory shape is checked as
    // corroboration rather than as the primary test, since a redirected home is the
    // observable CONSEQUENCE of being containerized.
    static var isSandboxed: Bool {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return true
        }
        return NSHomeDirectory().contains("/Library/Containers/")
    }

    static var containerPath: String? {
        let home = NSHomeDirectory()
        return home.contains("/Library/Containers/") ? home : nil
    }

    // The single line the log opens with. Everything here is something a later
    // diagnosis needs and cannot recover from anywhere else in the file.
    static func startupSummary(logFileURL: URL) -> String {
        var line = "Runtime environment: sandbox "
        line += isSandboxed ? "ENABLED" : "disabled"
        line += ", container \(containerPath ?? "none (running outside a container)")"
        line += ", home \(NSHomeDirectory())"
        line += ", log \(logFileURL.path(percentEncoded: false))"
        return line
    }
}

// MARK: - FileAccessDiagnosis
// Turns a filesystem error into something that names the CAUSE.
//
// This exists because of one specific ambiguity the sandbox introduces.
// localizedDescription renders both "the sandbox refused this" and "the drive is
// unplugged" as prose about a file that could not be opened, and those two have
// nothing to do with each other: the first is a bug in this app's scope handling,
// the second is a user unplugging a disk. Before the conversion the distinction did
// not exist and the prose was adequate; afterwards, being unable to tell them apart
// would make every scope bug look like a hardware complaint.
enum FileAccessDiagnosis {

    static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        var parts = ["\(nsError.domain) \(nsError.code)"]

        if let code = posixCode(in: nsError) {
            parts.append("POSIX \(code) \(name(for: code))")
            if code == EPERM || code == EACCES {
                parts.append("PERMISSION DENIED — inside the sandbox this normally "
                    + "means no security-scoped grant is currently held for the shared "
                    + "folder this path belongs to, not that the file is missing")
            }
        }

        parts.append(nsError.localizedDescription)
        return parts.joined(separator: " — ")
    }

    // Walks the underlying-error chain: Foundation wraps the real errno in an
    // NSCocoaErrorDomain error, and the POSIX code is the part worth reading.
    private static func posixCode(in error: NSError) -> Int32? {
        var current: NSError? = error
        while let candidate = current {
            if candidate.domain == NSPOSIXErrorDomain {
                return Int32(candidate.code)
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    private static func name(for code: Int32) -> String {
        switch code {
        case EPERM:   return "EPERM"
        case ENOENT:  return "ENOENT"
        case EACCES:  return "EACCES"
        case EIO:     return "EIO"
        case ENOTDIR: return "ENOTDIR"
        case EISDIR:  return "EISDIR"
        case EMFILE:  return "EMFILE"
        case ENFILE:  return "ENFILE"
        case ESTALE:  return "ESTALE"
        case ETIMEDOUT: return "ETIMEDOUT"
        default:      return Errno(rawValue: code).description
        }
    }
}

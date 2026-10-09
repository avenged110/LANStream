// MARK: - ContentDirectory.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Implements the ContentDirectory and ConnectionManager SOAP actions.
//
// This type is pure: it takes a parsed SOAP request plus an immutable content
// snapshot and returns a response body. It performs no I/O and holds no state,
// which makes every action independently testable and means concurrent Browse
// requests from a player that pipelines them cannot interfere with each other.

import Foundation

enum ContentDirectoryService: Loggable {
    nonisolated static let logTag = "[ContentDirectory]"

    // MARK: - Result
    enum Outcome: Sendable {
        case success(body: String)
        case fault(SOAPResponse.UPnPError)
    }

    // MARK: - Dispatch
    static func handle(_ request: SOAPRequest,
                       snapshot: ContentSnapshot,
                       baseURL: String) -> Outcome {
        switch request.action {
        case "Browse":
            return browse(request, snapshot: snapshot, baseURL: baseURL)

        case "GetSearchCapabilities":
            // Search is not implemented. An empty capability string is the correct,
            // spec-sanctioned way to say so — it tells the control point not to
            // offer search rather than leaving it to discover the gap via a fault.
            return .success(body: SOAPResponse.envelope(
                action: "GetSearchCapabilities",
                serviceType: UPnP.contentDirectoryType,
                arguments: [(name: "SearchCaps", value: "")]))

        case "GetSortCapabilities":
            return .success(body: SOAPResponse.envelope(
                action: "GetSortCapabilities",
                serviceType: UPnP.contentDirectoryType,
                arguments: [(name: "SortCaps", value: "")]))

        case "GetSystemUpdateID":
            return .success(body: SOAPResponse.envelope(
                action: "GetSystemUpdateID",
                serviceType: UPnP.contentDirectoryType,
                arguments: [(name: "Id", value: String(snapshot.updateID))]))

        default:
            log("Unsupported ContentDirectory action requested: '\(request.action)'")
            return .fault(.invalidAction)
        }
    }

    // MARK: - Browse
    private static func browse(_ request: SOAPRequest,
                               snapshot: ContentSnapshot,
                               baseURL: String) -> Outcome {

        let objectID = request.argument("ObjectID") ?? ContentIndex.rootObjectID
        let browseFlag = request.argument("BrowseFlag") ?? "BrowseDirectChildren"
        let startingIndex = max(0, request.intArgument("StartingIndex", default: 0))
        let requestedCount = request.intArgument("RequestedCount", default: 0)

        guard let node = snapshot.node(withID: objectID) else {
            // Happens legitimately when a client browses an ID it cached before the
            // index was rebuilt and the folder has since been deleted. 701 is the
            // correct answer and prompts a well-behaved client to re-browse upward.
            log("Browse for unknown ObjectID '\(objectID)' — returning 701.")
            return .fault(.noSuchObject)
        }

        let matchedNodes: [MediaNode]
        let totalMatches: Int

        switch browseFlag {
        case "BrowseMetadata":
            // Metadata about the object itself, not its children. TotalMatches is
            // defined as 1 for this flag.
            matchedNodes = [node]
            totalMatches = 1

        case "BrowseDirectChildren":
            guard case .container(let childIDs) = node.kind else {
                // Browsing the children of an item yields an empty, valid result
                // rather than a fault: the object exists, it simply has no children.
                return .success(body: browseEnvelope(didl: DIDLLite.document(for: [],
                                                                             baseURL: baseURL),
                                                     numberReturned: 0,
                                                     totalMatches: 0,
                                                     updateID: snapshot.updateID))
            }

            totalMatches = childIDs.count

            // RequestedCount == 0 means "all remaining", per the ContentDirectory
            // specification. Treating it as a literal zero is a well-known way to
            // return an empty list to clients that never paginate.
            //
            // Anything else is clamped into [0, remaining]. Both ends matter and
            // neither is hypothetical: a negative count produced a reversed slice
            // bound and trapped, and a count near Int.max overflowed the addition
            // below and trapped as well. Either one is a single malformed request
            // away from taking the whole server down mid-playback, so the arithmetic
            // is made total here rather than trusting the client's numbers.
            let remaining = max(0, totalMatches - startingIndex)
            let effectiveCount = requestedCount <= 0
                ? remaining
                : min(requestedCount, remaining)

            guard startingIndex < totalMatches else {
                // A start index past the end is not an error; it is how a paginating
                // client discovers it has reached the end.
                return .success(body: browseEnvelope(didl: DIDLLite.document(for: [],
                                                                             baseURL: baseURL),
                                                     numberReturned: 0,
                                                     totalMatches: totalMatches,
                                                     updateID: snapshot.updateID))
            }

            // effectiveCount is already clamped to the number of children after
            // startingIndex, so this addition cannot overflow or exceed the array.
            let endIndex = startingIndex + effectiveCount
            let pageIDs = childIDs[startingIndex..<endIndex]
            matchedNodes = pageIDs.compactMap { snapshot.node(withID: $0) }

        default:
            log("Browse with unsupported BrowseFlag '\(browseFlag)' — returning 710.")
            return .fault(.unsupportedBrowseFlag)
        }

        let didl = DIDLLite.document(for: matchedNodes, baseURL: baseURL)
        log("Browse '\(objectID)' (\(node.title)) flag=\(browseFlag) start=\(startingIndex) requested=\(requestedCount) → returned \(matchedNodes.count) of \(totalMatches).")

        return .success(body: browseEnvelope(didl: didl,
                                             numberReturned: matchedNodes.count,
                                             totalMatches: totalMatches,
                                             updateID: snapshot.updateID))
    }

    // Wraps a DIDL-Lite document in the Browse SOAP response. The DIDL is escaped
    // here — see the note at the top of DIDLLite.swift for why this second level of
    // escaping is mandatory and easy to get wrong.
    private static func browseEnvelope(didl: String,
                                       numberReturned: Int,
                                       totalMatches: Int,
                                       updateID: UInt32) -> String {
        SOAPResponse.envelope(
            action: "Browse",
            serviceType: UPnP.contentDirectoryType,
            arguments: [
                (name: "Result", value: XML.escape(didl)),
                (name: "NumberReturned", value: String(numberReturned)),
                (name: "TotalMatches", value: String(totalMatches)),
                (name: "UpdateID", value: String(updateID))
            ])
    }
}

// MARK: - ConnectionManagerService
enum ConnectionManagerService: Loggable {
    nonisolated static let logTag = "[ConnectionManager]"

    static func handle(_ request: SOAPRequest) -> ContentDirectoryService.Outcome {
        switch request.action {
        case "GetProtocolInfo":
            // Source lists what this server can send; Sink is empty because LAN
            // Stream never receives content. Some firmware filters browse results
            // against this list, so it must stay consistent with the res elements
            // emitted by DIDLLite.
            return .success(body: SOAPResponse.envelope(
                action: "GetProtocolInfo",
                serviceType: UPnP.connectionManagerType,
                arguments: [
                    (name: "Source", value: XML.escape(UPnP.sourceProtocolInfo)),
                    (name: "Sink", value: "")
                ]))

        case "GetCurrentConnectionIDs":
            // LAN Stream does not track connections as UPnP connection instances;
            // every transfer is a plain HTTP GET. Reporting only the default
            // connection ID 0 is the conventional answer for an HTTP-only server.
            return .success(body: SOAPResponse.envelope(
                action: "GetCurrentConnectionIDs",
                serviceType: UPnP.connectionManagerType,
                arguments: [(name: "ConnectionIDs", value: "0")]))

        case "GetCurrentConnectionInfo":
            return .success(body: SOAPResponse.envelope(
                action: "GetCurrentConnectionInfo",
                serviceType: UPnP.connectionManagerType,
                arguments: [
                    (name: "RcsID", value: "-1"),
                    (name: "AVTransportID", value: "-1"),
                    (name: "ProtocolInfo", value: XML.escape(UPnP.sourceProtocolInfo)),
                    (name: "PeerConnectionManager", value: ""),
                    (name: "PeerConnectionID", value: "-1"),
                    (name: "Direction", value: "Output"),
                    (name: "Status", value: "OK")
                ]))

        default:
            log("Unsupported ConnectionManager action requested: '\(request.action)'")
            return .fault(.invalidAction)
        }
    }
}

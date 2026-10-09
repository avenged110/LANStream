// MARK: - GENA.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The initial event message a subscriber is promised, and the pieces needed to
// send it.
//
// What this is and is not
// -----------------------
// LAN Stream does not implement general eventing: nothing it publishes changes on
// a timescale a browsing client needs pushed to it, and a full GENA publisher
// means a subscription table, renewals, expiry, per-subscriber sequence numbers,
// and a delivery queue that must not be allowed to wedge the server when a control
// point goes away mid-transfer. That is a large amount of machinery in the request
// path for a media server whose index changes when somebody copies a film in.
//
// The INITIAL event message is a different matter, and is the one part that is not
// optional. UDA requires a publisher to send it as soon as it has accepted a
// subscription, and it is what a control point waits for to consider the service
// live. Answering SUBSCRIBE with a SID and then never speaking again is the shape
// that makes some control points mark the whole device as broken and drop it —
// which is exactly the failure this app exists to avoid, and it is strictly worse
// than the 501 the accept-and-ignore behavior was written to avoid in the first
// place.
//
// So: subscriptions are accepted, the initial event is delivered properly, and no
// further events are sent. A client that wants to know whether the tree changed
// polls GetSystemUpdateID, which is cheap and always available. The gap that
// remains is documented rather than hidden.

import Foundation

enum GENA: Loggable {
    nonisolated static let logTag = "[GENA]"

    // MARK: - Services
    // Which service was subscribed to. This decides the property set, and it has to
    // be complete: UDA requires the initial event to carry EVERY evented state
    // variable the service declares, so this must stay in agreement with the
    // sendEvents="yes" entries in the two SCPDs in UPnPDescriptions.swift.
    enum Service: Sendable {
        // ContentDirectory declares exactly one evented variable, SystemUpdateID.
        case contentDirectory
        // ConnectionManager declares three: SourceProtocolInfo, SinkProtocolInfo,
        // and CurrentConnectionIDs.
        case connectionManager
    }

    // Advertised subscription lifetime. The value is honest in the only sense that
    // matters to a subscriber — nothing here expires it early — and matches the
    // conventional 30 minutes control points expect to renew against.
    static let subscriptionTimeoutSeconds = 1800

    // Hard ceiling on the delivery attempt. The callback URL points at a socket on
    // somebody else's device, and a control point that accepts the connection and
    // then stops reading would otherwise hold this task open indefinitely. The
    // initial event is a courtesy the spec requires, not something this server may
    // be delayed or wedged by.
    private static let deliveryTimeout: TimeInterval = 5.0

    // MARK: - CALLBACK parsing
    // The header is one or more URLs, each wrapped in angle brackets and run
    // together with no separator:
    //
    //   CALLBACK: <http://192.168.1.5:49152/evt><http://192.168.1.5:49153/evt>
    //
    // Splitting on some delimiter is the obvious implementation and there is no
    // delimiter to split on, so the brackets are walked directly. Anything outside
    // a bracket pair is ignored rather than treated as an error: a sloppy sender
    // that adds whitespace or a comma between entries still gets its subscription.
    static func callbackURLs(from header: String) -> [URL] {
        var results: [URL] = []
        var current = ""
        var isInsideBrackets = false

        for character in header {
            switch character {
            case "<":
                isInsideBrackets = true
                current = ""
            case ">":
                guard isInsideBrackets else { continue }
                isInsideBrackets = false
                let text = current.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty, let url = URL(string: text) { results.append(url) }
                current = ""
            default:
                if isInsideBrackets { current.append(character) }
            }
        }
        return results
    }

    // Picks the callback this server is willing to deliver to.
    //
    // Two filters, and the second one is a deliberate restriction rather than a
    // reading of the spec:
    //
    //   • http only. This server has no TLS and no business opening any other kind
    //     of connection on a subscriber's say-so.
    //   • The URL's host must be the address the SUBSCRIBE itself arrived from.
    //     Nothing in UDA requires this, but without it any device on the LAN can
    //     hand this server an arbitrary address and have it deliver an HTTP request
    //     there — a small but real request-bouncing primitive, offered to anything
    //     that can reach port 8201. Real control points always listen on the
    //     interface they contacted the device from, so the restriction costs
    //     nothing in practice; and on the vanishing chance that it ever does bite,
    //     it says so in the log by name rather than failing silently.
    static func deliverableCallback(from header: String,
                                    requestedBy peerHost: String) -> URL? {
        let candidates = callbackURLs(from: header)
        guard !candidates.isEmpty else { return nil }

        for candidate in candidates {
            guard candidate.scheme?.lowercased() == "http" else { continue }
            guard let host = candidate.host() else { continue }
            if host == peerHost { return candidate }
        }

        let described = candidates.map(\.absoluteString).joined(separator: ", ")
        log("Refusing to deliver the initial event for a subscription from \(peerHost): "
            + "its CALLBACK (\(described)) names no plain-http address belonging to the "
            + "subscriber itself. The subscription is still accepted, so browsing is "
            + "unaffected; only the initial event is withheld.")
        return nil
    }

    // MARK: - Property set
    // The event body. Every evented variable of the service, each in its own
    // <e:property>, exactly as UDA specifies the initial message.
    static func propertySetXML(for service: Service, systemUpdateID: UInt32) -> String {
        let properties: [(name: String, value: String)]
        switch service {
        case .contentDirectory:
            properties = [("SystemUpdateID", String(systemUpdateID))]
        case .connectionManager:
            properties = [
                ("SourceProtocolInfo", UPnP.sourceProtocolInfo),
                // Empty because LAN Stream never receives content; the variable is
                // evented all the same, so it must be present with its real value.
                ("SinkProtocolInfo", ""),
                ("CurrentConnectionIDs", "0")
            ]
        }

        let body = properties.map { property in
            "<e:property><\(property.name)>\(XML.escape(property.value))"
                + "</\(property.name)></e:property>"
        }.joined()

        return """
        <?xml version="1.0" encoding="utf-8"?>\
        <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">\
        \(body)\
        </e:propertyset>
        """
    }

    // MARK: - Delivery
    // Sends the initial NOTIFY. Never throws and never reports failure upward: by
    // the time this runs the subscription has already been accepted and the
    // response is on the wire, so there is nothing left to fail. A control point
    // that does not answer its own callback has a problem this server cannot fix
    // and must not be delayed by.
    //
    // SEQ is 0, which UDA reserves for the initial message; every later event would
    // count up from 1. Since there are no later events, 0 is the only sequence
    // number this server ever sends.
    static func sendInitialEvent(to callback: URL,
                                 subscriptionID: String,
                                 propertySet: String) async {
        var request = URLRequest(url: callback)
        request.httpMethod = "NOTIFY"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue("upnp:propchange", forHTTPHeaderField: "NTS")
        request.setValue(subscriptionID, forHTTPHeaderField: "SID")
        request.setValue("0", forHTTPHeaderField: "SEQ")
        request.httpBody = Data(propertySet.utf8)
        request.timeoutInterval = deliveryTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = deliveryTimeout
        configuration.timeoutIntervalForResource = deliveryTimeout
        // One callback, one connection, and no reuse: the subscriber is a device
        // that may vanish between subscriptions, and a pooled connection to it
        // would only be discovered dead on the next attempt.
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                log("Delivered the initial event for \(subscriptionID) to "
                    + "\(callback.absoluteString) (HTTP \(status)).")
            } else {
                log("The subscriber at \(callback.absoluteString) answered the initial "
                    + "event for \(subscriptionID) with HTTP \(status). The subscription "
                    + "stands; nothing further will be sent to it.")
            }
        } catch {
            // Worth a line rather than silence: a control point whose device list
            // keeps losing this server, with this message in the log, has told you
            // exactly where to look.
            log("Could not deliver the initial event for \(subscriptionID) to "
                + "\(callback.absoluteString): \(error.localizedDescription). Some "
                + "control points treat a missing initial event as a dead service.")
        }
    }
}

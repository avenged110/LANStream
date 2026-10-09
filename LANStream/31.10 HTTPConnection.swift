// MARK: - HTTPConnection.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// One accepted TCP connection: request loop, routing, and media streaming.
//
// Each instance owns exactly one socket and all of its parse state. Because no
// two connections share anything, a 40 GB transfer to the Oppo and a burst of
// Browse requests from a phone's control app proceed entirely independently.

import Foundation
import Network

actor HTTPConnection: Loggable {
    nonisolated static let logTag = "[HTTPConnection]"

    // Ceiling on the chunk size for media transfers. 256 KB is large enough that
    // per-send overhead is negligible on a gigabit LAN, and small enough that a
    // canceled transfer (the user stopping playback) is noticed within a few
    // milliseconds instead of after a multi-megabyte write drains.
    private static let streamChunkSize = 256 * 1024

    // Size of the FIRST chunk of a transfer, doubling on each subsequent send until
    // it reaches streamChunkSize.
    //
    // Playback is not what this is for — a transfer that runs for hours reaches the
    // ceiling inside its first hundred milliseconds and the ramp is invisible. It is
    // for the requests that are never going to become playback at all.
    //
    // A DLNA player browsing a folder reads each file's header to learn its
    // container, codec, and duration, and an Oppo does it by issuing a bare GET with
    // no Range, taking whatever arrives first, and resetting the connection. It wants
    // roughly a kilobyte. A field trace over three days recorded 445 media requests
    // of which only two were playback; of the remaining 443, thirty-four were these
    // bare probes, and all thirty-four ended the same way — the client resetting with
    // a full 256 KB chunk already committed to the wire. Six of them landed inside
    // 7.6 seconds while a 201-item folder was being scrolled.
    //
    // Ranged probes were already cheap: a Range of 512 bytes makes byteCount 512, so
    // the chunk is clamped to 512 and nothing is wasted. Only the un-ranged GET,
    // whose byteCount is the whole file, could ever ask for the ceiling on its first
    // write. Starting at 16 KB cuts what those probes cost by roughly sixteen times
    // and costs a real transfer four extra send calls.
    private static let streamInitialChunkSize = 16 * 1024

    // How long a connection may sit with no traffic at all before it is closed.
    //
    // Only ever applied to connections that are NOT streaming. A player that pauses
    // a film leaves a transfer that legitimately makes no progress for as long as
    // the pause lasts — the send simply does not complete — so timing those out
    // would end playback on resume, which is precisely the harm this app must not
    // cause. Idle control connections are a different matter: a client that opens a
    // socket, issues no request and never closes it would otherwise occupy a slot
    // in the connection table for the lifetime of the process.
    //
    // Five minutes is far longer than any real gap between a Browse and the
    // playback request that follows it, so nothing legitimate is ever cut off.
    private static let idleTimeoutSeconds: TimeInterval = 300

    // How often the watchdog looks. Coarse on purpose: this is a leak backstop, not
    // a latency-sensitive mechanism, and a sleeping task per connection that wakes
    // four times a minute costs nothing.
    private static let idleCheckInterval: Duration = .seconds(15)

    private let id: UUID
    private let connection: NWConnection
    private let contentIndex: ContentIndex
    private let queue: DispatchQueue
    // The port the listener actually bound. Used only when Network.framework has
    // not yet populated this connection's local endpoint; reading the PREFERRED
    // port out of Preferences there — which this used to do — hands the client a
    // URL on a port nothing is listening on whenever the server landed on the
    // fallback ladder.
    private let boundPort: UInt16
    private let onFinish: @Sendable (UUID) -> Void
    // Reports the start and end of a media transfer so HTTPServer can answer
    // "is anyone watching something right now".
    private let onStreamChange: @Sendable (UUID, UInt64, HTTPServer.ActiveStream?) -> Void
    // Stamped on every stream report so HTTPServer can apply them in the order they
    // were made; see HTTPServer.lastStreamReport.
    private var streamReportSequence: UInt64 = 0

    private var parser = HTTPRequestParser()
    // Transport torn down. Guards against canceling twice and stops the read loop.
    private var isClosed = false
    // Removal from HTTPServer's connection table already reported.
    //
    // These are two distinct facts and were previously conflated into one flag,
    // which leaked every connection the server closed itself: close() set the flag,
    // finish() then saw it already set and returned without ever calling onFinish,
    // so the entry stayed in HTTPServer.connections for the lifetime of the process.
    // A player that reconnects on every seek would accumulate them indefinitely.
    private var hasFinished = false
    // Consecutive zero-byte reads, used to break a pathological receive spin.
    private var emptyReadCount = 0
    // Description of the peer, resolved once for log messages.
    private var peerDescription = "unknown"
    // Last moment this connection either received or successfully sent anything.
    private var lastActivityAt = Date()
    // True for the duration of a media transfer, which exempts the connection from
    // the idle timeout; see the discussion on idleTimeoutSeconds.
    private var isStreaming = false
    // Total requests served, and when the connection was accepted. Both exist so a
    // timeout or a rejection can say what the connection had been DOING, rather
    // than only that it was closed.
    private var requestCount = 0
    private let acceptedAt = Date()
    private var idleWatchdog: Task<Void, Never>?

    init(id: UUID,
         connection: NWConnection,
         contentIndex: ContentIndex,
         queue: DispatchQueue,
         boundPort: UInt16,
         onFinish: @escaping @Sendable (UUID) -> Void,
         onStreamChange: @escaping @Sendable (UUID, UInt64, HTTPServer.ActiveStream?) -> Void) {
        self.id = id
        self.connection = connection
        self.contentIndex = contentIndex
        self.queue = queue
        self.boundPort = boundPort
        self.onFinish = onFinish
        self.onStreamChange = onStreamChange
    }

    // MARK: - Lifecycle
    func start() {
        peerDescription = NetworkDescription.describe(endpoint: connection.endpoint)
        lastActivityAt = Date()
        startIdleWatchdog()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.beginReceiveLoop() }
            case .failed(let error):
                Task { await self?.handleTransportFailure(error) }
            case .cancelled:
                Task { await self?.finish() }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - Idle watchdog
    private func startIdleWatchdog() {
        idleWatchdog?.cancel()
        idleWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: HTTPConnection.idleCheckInterval) }
                catch { return }
                guard let self else { return }
                if await self.closeIfIdle() { return }
            }
        }
    }

    // Longest a connection may stay open without ever completing a single request.
    //
    // The idle timeout above cannot cover this case, because it measures time since
    // the last BYTE and a client can keep that reset forever by trickling one byte
    // at a time while never finishing a request — the classic slow-loris shape. With
    // the connection table capped at 48, a few dozen such sockets would make the
    // server unreachable to everything else on the LAN while every counter in the
    // app still looked healthy.
    //
    // Any real client sends a complete request immediately on connecting, so a
    // minute is enormously generous and nothing legitimate can reach it. Connections
    // that have completed at least one request are exempt and fall back to the
    // ordinary idle rule, so keep-alive and paused playback are unaffected.
    private static let firstRequestTimeoutSeconds: TimeInterval = 60

    // Returns true when the connection was closed (or is already gone) and the
    // watchdog should stop.
    private func closeIfIdle() -> Bool {
        if isClosed { return true }

        if requestCount == 0 {
            let age = Date().timeIntervalSince(acceptedAt)
            if age >= Self.firstRequestTimeoutSeconds {
                Self.log("Closing connection from \(peerDescription): open for "
                    + age.fixed(0)
                    + "s without ever completing a request (limit "
                    + "\(Int(Self.firstRequestTimeoutSeconds))s). A client that has "
                    + "connected but never finished sending one is either broken or "
                    + "holding the slot deliberately.")
                close()
                return true
            }
        }

        if isStreaming { return false }
        let idleFor = Date().timeIntervalSince(lastActivityAt)
        guard idleFor >= Self.idleTimeoutSeconds else { return false }
        Self.log("Closing idle connection from \(peerDescription): no traffic for "
            + idleFor.fixed(0)
            + "s (limit \(Int(Self.idleTimeoutSeconds))s), \(requestCount) request(s) "
            + "served over "
            + Date().timeIntervalSince(acceptedAt).fixed(0)
            + "s, not streaming. This is a housekeeping close, not a fault.")
        close()
        return true
    }

    // Tears the socket down and reports the connection as finished. Both halves run
    // on every path: clearing the state handler means no .cancelled callback will
    // arrive to report the finish later, so it has to be reported here.
    func close() {
        idleWatchdog?.cancel()
        idleWatchdog = nil
        if !isClosed {
            isClosed = true
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        finish()
    }

    private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        // Clear any transfer this connection was mid-way through before reporting
        // it gone, so the registry can never outlive the connection that fed it.
        reportStream(nil)
        onFinish(id)
    }

    private func reportStream(_ stream: HTTPServer.ActiveStream?) {
        streamReportSequence &+= 1
        onStreamChange(id, streamReportSequence, stream)
    }

    private func handleTransportFailure(_ error: NWError) {
        // A player that stops playback mid-file closes the socket abruptly. That is
        // routine, not an error condition, so it is logged at the same level as any
        // other disconnect rather than being surfaced to the UI.
        Self.log("Connection from \(peerDescription) failed: \(error.localizedDescription)")
        close()
    }

    // MARK: - Receive loop
    private func beginReceiveLoop() async {
        while !isClosed {
            guard let data = await receiveChunk() else { break }

            if data.isEmpty {
                // minimumIncompleteLength is 1, so a zero-byte, not-yet-complete
                // read should be impossible. Counting them anyway means a transport
                // that ever violated that could not spin this loop at full CPU.
                emptyReadCount += 1
                if emptyReadCount > 64 {
                    Self.log("Aborting \(peerDescription): 64 consecutive empty reads.")
                    break
                }
                continue
            }
            emptyReadCount = 0
            lastActivityAt = Date()
            parser.append(data)

            // Drain every complete request in the buffer before reading again; a
            // client is entitled to pipeline, and the Oppo does send back-to-back
            // requests when a folder is opened.
            while !isClosed {
                let request: HTTPRequest?
                do {
                    request = try parser.nextRequest()
                } catch {
                    Self.log("Malformed request from \(peerDescription): \(error). Closing.")
                    await send(.text(.badRequest, body: "Bad Request"), keepAlive: false)
                    close()
                    return
                }
                guard let request else { break }
                await handle(request)
            }
        }
        // close() rather than finish(): the loop also ends when the peer hangs up,
        // and reporting the connection finished without canceling it would leave
        // the NWConnection alive inside Network.framework with nothing driving it.
        close()
    }

    // Bridges NWConnection's callback receive into async/await. Returns nil when
    // the peer has closed the connection or an error ended it.
    private func receiveChunk() async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1,
                               maximumLength: 64 * 1024) { data, _, isComplete, error in
                // An error is logged by the state handler; just end the loop here.
                if error != nil {
                    continuation.resume(returning: nil)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                continuation.resume(returning: isComplete ? nil : Data())
            }
        }
    }

    // MARK: - Routing
    private func handle(_ request: HTTPRequest) async {
        let path = request.path
        requestCount += 1
        lastActivityAt = Date()
        Self.log("\(request.method) \(request.target) from \(peerDescription)"
                 + (request.header("range").map { " Range: \($0)" } ?? ""))

        // The base URL is derived from the local address this connection was
        // accepted on, so every URL handed back is guaranteed reachable by the peer
        // that asked — the multi-homed-machine failure described in
        // NetworkInterface.swift cannot occur through this path.
        let baseURL = localBaseURL()

        switch (request.method, path) {

        case ("GET", UPnP.Path.deviceDescription),
             ("HEAD", UPnP.Path.deviceDescription):
            let body = UPnP.deviceDescription(udn: Preferences.serverUUID,
                                              friendlyName: Preferences.friendlyName,
                                              baseURL: baseURL,
                                              serialNumber: Preferences.serverUUID,
                                              iconList: await DeviceIcon.listXML)
            await send(.xml(body), omitBody: request.method == "HEAD",
                       keepAlive: request.wantsKeepAlive)

        case ("GET", UPnP.Path.contentDirectorySCPD),
             ("HEAD", UPnP.Path.contentDirectorySCPD):
            await send(.xml(UPnP.contentDirectorySCPD),
                       omitBody: request.method == "HEAD",
                       keepAlive: request.wantsKeepAlive)

        case ("GET", UPnP.Path.connectionManagerSCPD),
             ("HEAD", UPnP.Path.connectionManagerSCPD):
            await send(.xml(UPnP.connectionManagerSCPD),
                       omitBody: request.method == "HEAD",
                       keepAlive: request.wantsKeepAlive)

        case ("POST", UPnP.Path.contentDirectoryControl):
            await handleControl(request, baseURL: baseURL, service: .contentDirectory)

        case ("POST", UPnP.Path.connectionManagerControl):
            await handleControl(request, baseURL: baseURL, service: .connectionManager)

        case ("SUBSCRIBE", UPnP.Path.contentDirectoryEvent):
            await handleSubscribe(request, service: .contentDirectory)

        case ("SUBSCRIBE", UPnP.Path.connectionManagerEvent):
            await handleSubscribe(request, service: .connectionManager)

        case ("UNSUBSCRIBE", UPnP.Path.contentDirectoryEvent),
             ("UNSUBSCRIBE", UPnP.Path.connectionManagerEvent):
            await send(.text(.ok, body: ""), keepAlive: request.wantsKeepAlive)

        default:
            if path.hasPrefix(UPnP.Path.iconPrefix),
               request.method == "GET" || request.method == "HEAD",
               let icon = await DeviceIcon.payload(forPath: path) {
                // Cacheable for a day. Icons change only when the app is replaced,
                // and a player that refetches its whole server list on every wake is
                // better served from its own cache than from this socket.
                await send(HTTPResponse(status: .ok,
                                        headers: [("Content-Type", icon.contentType),
                                                  ("Cache-Control", "public, max-age=86400")],
                                        body: icon.data,
                                        closeConnection: false),
                           omitBody: request.method == "HEAD",
                           keepAlive: request.wantsKeepAlive)
                return
            }
            if path.hasPrefix(UPnP.Path.mediaPrefix),
               request.method == "GET" || request.method == "HEAD" {
                await handleMedia(request, path: path)
                return
            }
            if request.method != "GET" && request.method != "HEAD"
                && request.method != "POST" {
                await send(.text(.methodNotAllowed, body: "Method Not Allowed"),
                           keepAlive: request.wantsKeepAlive)
                return
            }
            Self.log("404 for \(request.method) \(path)")
            await send(.text(.notFound, body: "Not Found"),
                       omitBody: request.method == "HEAD",
                       keepAlive: request.wantsKeepAlive)
        }
    }

    // MARK: - SOAP control
    private enum ControlService { case contentDirectory, connectionManager }

    private func handleControl(_ request: HTTPRequest,
                               baseURL: String,
                               service: ControlService) async {
        guard let soapRequest = SOAPParser.parse(request.body) else {
            Self.log("Could not parse SOAP body (\(request.body.count) bytes) from \(peerDescription).")
            await sendFault(.invalidArgs, keepAlive: request.wantsKeepAlive)
            return
        }

        let outcome: ContentDirectoryService.Outcome
        switch service {
        case .contentDirectory:
            let snapshot = await contentIndex.currentSnapshot()
            outcome = ContentDirectoryService.handle(soapRequest,
                                                     snapshot: snapshot,
                                                     baseURL: baseURL)
        case .connectionManager:
            outcome = ConnectionManagerService.handle(soapRequest)
        }

        switch outcome {
        case .success(let body):
            var response = HTTPResponse.xml(body)
            // EXT is a required (if vestigial) header on UPnP control responses.
            response.headers.append((name: "EXT", value: ""))
            await send(response, keepAlive: request.wantsKeepAlive)
        case .fault(let error):
            await sendFault(error, keepAlive: request.wantsKeepAlive)
        }
    }

    private func sendFault(_ error: SOAPResponse.UPnPError, keepAlive: Bool) async {
        let response = HTTPResponse.xml(SOAPResponse.fault(error),
                                        status: .internalServerError)
        await send(response, keepAlive: keepAlive)
    }

    // MARK: - GENA subscription
    // Subscriptions are accepted, the initial event message UDA requires is
    // delivered, and nothing further is ever sent. See GENA.swift for why that is
    // the line drawn here and what it costs.
    //
    // The two forms of SUBSCRIBE are distinguished the way UDA defines them: a NEW
    // subscription carries NT and CALLBACK and no SID; a RENEWAL carries SID and
    // neither of the others. A request carrying both is malformed and is refused,
    // because guessing which one a confused client meant is how a renewal silently
    // becomes a second subscription that nothing will ever clean up.
    private func handleSubscribe(_ request: HTTPRequest,
                                 service: GENA.Service) async {
        let callbackHeader = request.header("callback")
        let notificationType = request.header("nt")
        let existingID = request.header("sid")

        if let existingID {
            guard callbackHeader == nil, notificationType == nil else {
                Self.log("Malformed SUBSCRIBE from \(peerDescription) for \(request.path): "
                    + "it carries SID as well as NT/CALLBACK, which are the two mutually "
                    + "exclusive forms of the request. Answering 400.")
                await send(.text(.badRequest, body: "Bad Request"),
                           keepAlive: request.wantsKeepAlive)
                return
            }
            // Renewals echo the SID they were given. Minting a fresh one — which
            // this used to do for every SUBSCRIBE, renewal or not — hands the
            // subscriber an identifier it never asked for and quietly orphans the
            // one it is still using.
            Self.log("Renewed GENA subscription \(existingID) for \(request.path) "
                + "from \(peerDescription).")
            await sendSubscriptionAccepted(subscriptionID: existingID,
                                           keepAlive: request.wantsKeepAlive)
            return
        }

        // 412 rather than 400 for these two: UDA specifies Precondition Failed for a
        // new subscription whose NT is not upnp:event or whose CALLBACK is missing.
        guard notificationType?.lowercased() == "upnp:event" else {
            Self.log("Rejecting SUBSCRIBE from \(peerDescription) for \(request.path): "
                + "NT is \(notificationType.map { "'\($0)'" } ?? "absent") rather than "
                + "'upnp:event'. Answering 412.")
            await send(.text(.preconditionFailed, body: "Precondition Failed"),
                       keepAlive: request.wantsKeepAlive)
            return
        }
        guard let callbackHeader else {
            Self.log("Rejecting SUBSCRIBE from \(peerDescription) for \(request.path): "
                + "no CALLBACK header, so there is nowhere to send events. Answering 412.")
            await send(.text(.preconditionFailed, body: "Precondition Failed"),
                       keepAlive: request.wantsKeepAlive)
            return
        }

        let subscriptionID = "uuid:\(UUID().uuidString.lowercased())"
        let callback = GENA.deliverableCallback(from: callbackHeader,
                                                requestedBy: peerHost)

        // Read the index BEFORE answering. The value the initial event carries
        // should be the one that was current when the subscription was accepted,
        // and reading it afterwards would race a rescan finishing in between.
        let updateID = await contentIndex.currentSnapshot().updateID

        Self.log("Accepted GENA subscription \(subscriptionID) for \(request.path) "
            + "from \(peerDescription)"
            + (callback == nil
               ? " (no deliverable callback — no initial event will be sent)."
               : ". Sending the initial event, and nothing after it."))

        await sendSubscriptionAccepted(subscriptionID: subscriptionID,
                                       keepAlive: request.wantsKeepAlive)

        // Strictly after the response has reached the wire: the subscriber cannot
        // match an event to a subscription whose SID it has not been told yet, and
        // send() above does not return until the write has completed.
        //
        // Detached because delivery talks to a socket on the SUBSCRIBER's device.
        // Awaiting it here would let a control point that accepts the connection and
        // then stalls hold this connection's request loop for the delivery timeout,
        // during which this socket answers nothing else — a client could pause its
        // own browsing simply by being slow to read.
        guard let callback else { return }
        let propertySet = GENA.propertySetXML(for: service, systemUpdateID: updateID)
        Task.detached(priority: .utility) {
            await GENA.sendInitialEvent(to: callback,
                                        subscriptionID: subscriptionID,
                                        propertySet: propertySet)
        }
    }

    // The 200 that accepts either form of SUBSCRIBE. Built directly rather than
    // through HTTPResponse.text so it carries no Content-Type: the body is empty,
    // and describing the type of nothing invites a strict client to go looking for
    // it. Content-Length, Date, and Server are added by serializedHead.
    private func sendSubscriptionAccepted(subscriptionID: String,
                                          keepAlive: Bool) async {
        var response = HTTPResponse(status: .ok, headers: [], body: Data(),
                                    closeConnection: !keepAlive)
        response.headers.append((name: "SID", value: subscriptionID))
        response.headers.append((name: "TIMEOUT",
                                 value: "Second-\(GENA.subscriptionTimeoutSeconds)"))
        response.headers.append((name: "EXT", value: ""))
        await send(response, keepAlive: keepAlive)
    }

    // The peer's address without its ephemeral port, which is what a CALLBACK URL
    // is checked against.
    private var peerHost: String { NetworkDescription.hostOnly(peerDescription) }

    // MARK: - Media delivery
    private func handleMedia(_ request: HTTPRequest, path: String) async {
        // "/media/<objectID>.<ext>" → "<objectID>"
        let identifierPart = path.dropFirst(UPnP.Path.mediaPrefix.count)
        let objectID = String(identifierPart.split(separator: ".").first ?? "")

        let snapshot = await contentIndex.currentSnapshot()
        guard let node = snapshot.node(withID: objectID),
              case .item(let url, let indexedSize, _) = node.kind else {
            Self.log("Media request for unknown object '\(objectID)' — 404.")
            await send(.text(.notFound, body: "Not Found"),
                       omitBody: request.method == "HEAD",
                       keepAlive: request.wantsKeepAlive)
            return
        }

        // Re-stat the file rather than trusting the indexed size. A drive can be
        // unplugged, or a file replaced, between the last scan and this request;
        // serving a Content-Length that does not match reality is the kind of fault
        // that manifests as an unexplained stall partway through playback.
        let currentSize: Int64
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            // Type is re-checked, not only size. The index recorded a regular file,
            // but anything can have happened to that path since — most plausibly a
            // file replaced by a directory of the same name during a library
            // reorganization. open(2) on a directory SUCCEEDS on macOS and read(2)
            // then fails with EISDIR, so without this the server would commit to a
            // 200 and a Content-Length and only discover the problem after the head
            // was already on the wire, leaving the client to time out.
            guard values.isRegularFile == true else {
                Self.log("Media request for '\(node.title)' from \(peerDescription): "
                    + "\(url.path(percentEncoded: false)) is no longer a regular file "
                    + "(it may have been replaced by a directory or a device node since "
                    + "the last scan) — answering 404.")
                await send(.text(.notFound, body: "File Unavailable"),
                           omitBody: request.method == "HEAD",
                           keepAlive: request.wantsKeepAlive)
                return
            }
            guard let size = values.fileSize else { throw CocoaError(.fileReadUnknown) }
            currentSize = Int64(size)
        } catch {
            // The single most likely place a security-scope bug surfaces: the index
            // was built while access was held, the grant later lapsed, and the file
            // the player is asking for now reads as absent. FileAccessDiagnosis is
            // what separates that from a drive that was genuinely unplugged.
            Self.log("ERROR: Cannot stat \(url.path(percentEncoded: false)) for "
                + "'\(node.title)' requested by \(peerDescription): "
                + "\(FileAccessDiagnosis.describe(error)) — answering 404.")
            await send(.text(.notFound, body: "File Unavailable"),
                       omitBody: request.method == "HEAD",
                       keepAlive: request.wantsKeepAlive)
            return
        }

        if currentSize != indexedSize {
            Self.log("NOTE: '\(node.title)' changed size since indexing (\(indexedSize) → \(currentSize)); serving current size.")
        }

        // A zero-length file has no satisfiable range and no body to send. It is
        // answered as an empty 200 rather than being allowed into the arithmetic
        // below, where "end = size - 1" underflows to -1 and the resulting
        // Content-Length of 1 promises a byte that does not exist — the player then
        // waits for it until it times out. Empty files are rare but entirely real
        // (an interrupted copy leaves one), and one of them should not hang the
        // client.
        if currentSize == 0 {
            // A Range against a zero-length representation is by definition
            // unsatisfiable, and RFC 9110 wants 416 for that rather than a 200 the
            // client did not ask for.
            if request.byteRange != nil {
                var unsatisfiable = HTTPResponse.text(.rangeNotSatisfiable, body: "")
                unsatisfiable.headers.append((name: "Content-Range", value: "bytes */0"))
                Self.log("'\(node.title)' is zero bytes; range request answered 416.")
                await send(unsatisfiable, omitBody: request.method == "HEAD",
                           keepAlive: request.wantsKeepAlive)
                return
            }
            Self.log("'\(node.title)' is zero bytes; returning an empty 200.")
            var empty = HTTPResponse.text(.ok, body: "",
                                          contentType: UPnP.mimeType(forExtension:
                                                                        node.fileExtension))
            empty.headers.append((name: "Accept-Ranges", value: "bytes"))
            empty.headers.append((name: "transferMode.dlna.org", value: "Streaming"))
            empty.headers.append((name: "contentFeatures.dlna.org",
                                  value: UPnP.contentFeatures))
            await send(empty, omitBody: true, keepAlive: request.wantsKeepAlive)
            return
        }

        // Resolve the requested range against the real file length.
        var start: Int64 = 0
        var end: Int64 = currentSize - 1
        var isPartial = false

        if let range = request.byteRange {
            switch range {
            case .bounded(let rangeStart, let rangeEnd):
                start = rangeStart
                end = min(rangeEnd, currentSize - 1)
            case .openEnded(let rangeStart):
                start = rangeStart
            case .suffix(let length):
                start = max(0, currentSize - length)
            }

            guard start < currentSize, start <= end else {
                // 416 must carry Content-Range with the real length so the client can
                // correct itself instead of retrying the same bad range.
                var response = HTTPResponse.text(.rangeNotSatisfiable, body: "")
                response.headers.append((name: "Content-Range",
                                         value: "bytes */\(currentSize)"))
                Self.log("416 for range \(String(describing: range)) against size \(currentSize).")
                await send(response, omitBody: request.method == "HEAD",
                           keepAlive: request.wantsKeepAlive)
                return
            }
            isPartial = true
        }

        let contentLength = end - start + 1

        var response = HTTPResponse(status: isPartial ? .partialContent : .ok,
                                    headers: [], body: Data(),
                                    closeConnection: !request.wantsKeepAlive)
        response.headers.append((name: "Content-Type",
                                 value: UPnP.mimeType(forExtension: node.fileExtension)))
        // Accept-Ranges advertises seek support even on the initial full request,
        // which is how a client decides whether to offer scrubbing at all.
        response.headers.append((name: "Accept-Ranges", value: "bytes"))
        response.headers.append((name: "transferMode.dlna.org", value: "Streaming"))
        response.headers.append((name: "contentFeatures.dlna.org",
                                 value: UPnP.contentFeatures))
        if isPartial {
            response.headers.append((name: "Content-Range",
                                     value: "bytes \(start)-\(end)/\(currentSize)"))
        }

        // The declared length is the requested byte span rather than response.body,
        // which is empty here because the bytes are streamed from disk.
        let head = response.serializedHead(serverName: HTTPServer.serverToken,
                                           contentLength: contentLength)

        // A HEAD carries the full header set and no body: this is how the Oppo
        // probes for size and seek capability before starting playback. There is no
        // body to coalesce with, so the head goes out on its own.
        if request.method == "HEAD" {
            guard await sendRaw(head) else { return }
            Self.log("HEAD '\(node.title)' → \(response.status.rawValue), length \(contentLength).")
            if response.closeConnection { close() }
            return
        }

        // The file is opened and positioned BEFORE the head reaches the wire so that
        // a failure here can still be answered with an honest 500. Once the head has
        // been sent the status is committed and dropping the connection is the only
        // signal left, so everything that can be checked up front is checked here.
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(start))
        } catch {
            Self.log("ERROR: Cannot open \(url.path(percentEncoded: false)) at offset "
                + "\(start) for streaming '\(node.title)' to \(peerDescription): "
                + "\(FileAccessDiagnosis.describe(error)). Returning 500.")
            await send(HTTPResponse.text(.internalServerError, body: ""),
                       keepAlive: false)
            return
        }
        defer { try? handle.close() }

        Self.log("Streaming '\(node.title)' bytes \(start)-\(end) of \(currentSize) to \(peerDescription).")
        isStreaming = true
        lastActivityAt = Date()
        reportStream(HTTPServer.ActiveStream(peer: peerDescription,
                                             title: node.title,
                                             startedAt: Date()))
        await streamFile(handle: handle, byteCount: contentLength,
                         head: head, title: node.title)
        isStreaming = false
        lastActivityAt = Date()
        reportStream(nil)

        if response.closeConnection { close() }
    }

    // Pumps the requested byte span from disk to the socket, one chunk at a time,
    // waiting for each send to complete before reading the next. Awaiting the send
    // is what provides backpressure: without it, a fast disk would queue the entire
    // file into Network.framework's send buffer and the app's memory use would
    // track file size rather than staying flat.
    //
    // 'handle' arrives already positioned at the first byte to send, and 'head' is
    // the response head, which rides out attached to the first chunk rather than as
    // a write of its own — see the coalescing note in the loop below.
    private func streamFile(handle: FileHandle,
                            byteCount: Int64,
                            head: Data,
                            title: String) async {
        // Emptied once the head has been folded into a chunk and handed to sendRaw.
        var pendingHead = head
        var remaining = byteCount
        let startedAt = ContinuousClock.now

        // Every exit from this function reports how much of the promised span
        // actually reached the client, and how fast.
        //
        // Without it the log could not answer the single most important question
        // about a transfer that ended early: did the client watch a while and stop,
        // or did it stall immediately? Both used to produce the same pair of lines —
        // a "Streaming…" at the start and a send failure at the end — with nothing
        // in between to tell fourteen seconds of healthy playback apart from a
        // transfer that died after one chunk.
        func report(_ outcome: String) {
            let elapsed = ContinuousClock.now - startedAt
            let delivered = byteCount - remaining
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            let rate = seconds > 0.001
                ? (Double(delivered) / seconds / 1_048_576).fixed(1) + " MB/s"
                : "instant"
            let percent = byteCount > 0
                ? (Double(delivered) / Double(byteCount) * 100).fixed(1) + "%"
                : "100%"
            Self.log("\(outcome) '\(title)' for \(peerDescription): delivered "
                + "\(delivered) of \(byteCount) byte(s) (\(percent)) in "
                + seconds.fixed(2) + "s at \(rate).")
        }

        // Grows toward streamChunkSize as the transfer proves it is a transfer; see
        // the discussion on streamInitialChunkSize.
        var chunkCeiling = Self.streamInitialChunkSize

        while remaining > 0 {
            if isClosed {
                report("Transfer ABANDONED — connection already closed —")
                return
            }

            let chunkLength = Int(min(Int64(chunkCeiling), remaining))
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkLength) ?? Data()
            } catch {
                Self.log("ERROR: Read failed while streaming '\(title)' to "
                    + "\(peerDescription) with \(remaining) byte(s) still to send: "
                    + "\(FileAccessDiagnosis.describe(error)). Closing connection.")
                report("Transfer FAILED on a read error —")
                close()
                return
            }

            guard !chunk.isEmpty else {
                // The file shrank underneath us. Closing is the only way to signal
                // that the promised Content-Length will not be delivered.
                Self.log("ERROR: Unexpected EOF streaming '\(title)' with \(remaining) "
                    + "byte(s) outstanding — the file shrank underneath this transfer, "
                    + "so the Content-Length already promised to \(peerDescription) can "
                    + "no longer be honored. Closing connection.")
                report("Transfer TRUNCATED by the file shrinking —")
                close()
                return
            }

            // Send the head together with the first chunk. As two separate writes
            // they are two small back-to-back segments, and a client that has
            // nothing to say in between will not acknowledge the first until its
            // delayed-ACK timer expires — 40 ms of dead air per request on top of
            // whatever Nagle would add. One write per response avoids the pattern
            // at the source rather than relying on the transport's noDelay setting
            // to paper over it.
            let payload: Data
            if pendingHead.isEmpty {
                payload = chunk
            } else {
                pendingHead.append(chunk)
                payload = pendingHead
                pendingHead = Data()
            }

            guard await sendRaw(payload) else {
                // sendRaw has already logged the transport error and closed the
                // connection; this adds the one thing it cannot know, which is how
                // far the transfer had got.
                report("Transfer INTERRUPTED by the client —")
                return
            }
            remaining -= Int64(chunk.count)
            // Doubled only after a send the client actually accepted, so a peer that
            // resets immediately never causes a larger write than the one it already
            // refused.
            chunkCeiling = min(chunkCeiling * 2, Self.streamChunkSize)
        }

        report("Finished streaming")
    }

    // MARK: - Sending
    private func send(_ response: HTTPResponse,
                      omitBody: Bool = false,
                      keepAlive: Bool = true) async {
        var response = response
        response.closeConnection = !keepAlive

        var data = response.serializedHead(serverName: HTTPServer.serverToken)
        if !omitBody { data.append(response.body) }

        guard await sendRaw(data) else { return }
        if response.closeConnection { close() }
    }

    // Writes bytes and waits for the transport to accept them. Returns false when
    // the send failed, in which case the connection has been torn down.
    @discardableResult
    private func sendRaw(_ data: Data) async -> Bool {
        if isClosed { return false }

        let error: NWError? = await withCheckedContinuation { continuation in
            connection.send(content: data,
                            completion: .contentProcessed { continuation.resume(returning: $0) })
        }

        if let error {
            Self.log("Send to \(peerDescription) failed after "
                + "\(requestCount) request(s), \(data.count) byte(s) pending"
                + (isStreaming ? " during a media transfer" : "")
                + ": \(error.localizedDescription).")
            close()
            return false
        }
        lastActivityAt = Date()
        return true
    }

    // MARK: - Endpoint helpers
    // Builds "http://<local address>:<port>" from the address this connection was
    // accepted on.
    private func localBaseURL() -> String {
        let port = connection.currentPath?.localEndpoint.flatMap(Self.port(of:))
            ?? boundPort

        if let localEndpoint = connection.currentPath?.localEndpoint,
           let host = Self.host(of: localEndpoint) {
            return "http://\(host):\(port)"
        }

        // Fallback for the rare case where the path is not yet populated.
        let fallbackHost = NetworkInterface.primaryIPv4Address() ?? "127.0.0.1"
        return "http://\(fallbackHost):\(port)"
    }

    private nonisolated static func host(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            // Strip any "%en0" interface scope; it is meaningless to a remote peer.
            return "\(address)".split(separator: "%").first.map(String.init)
        case .ipv6(let address):
            return "[\("\(address)".split(separator: "%").first.map(String.init) ?? "")]"
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }

    private nonisolated static func port(of endpoint: NWEndpoint) -> UInt16? {
        guard case .hostPort(_, let port) = endpoint else { return nil }
        return port.rawValue
    }
}

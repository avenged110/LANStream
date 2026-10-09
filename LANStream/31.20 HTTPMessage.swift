// MARK: - HTTPMessage.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Minimal HTTP/1.1 request parsing and response construction.
//
// Only the subset UPnP and DLNA actually exercise is implemented: GET, HEAD,
// POST, SUBSCRIBE, UNSUBSCRIBE, and single-range byte requests. There is no
// chunked request decoding (no UPnP control point sends one), no keep-alive
// pipelining of more than one in-flight request, and no compression.
//
// Writing this by hand rather than pulling in a server framework is a deliberate
// scope decision: the whole surface is a few hundred lines, it has no third-party
// dependency to age out from under the app, and every byte on the wire stays
// inspectable — which is what makes an undocumented client like the Oppo tractable.

import Foundation
import Synchronization

// MARK: - HTTPRequest
struct HTTPRequest: Sendable {

    let method: String
    // Raw request target, e.g. "/media/1a2b3c4d.mkv" or "/control/ContentDirectory".
    let target: String
    let version: String
    // Header names are lowercased at parse time; HTTP field names are
    // case-insensitive and clients are inconsistent about capitalization.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    // Path portion of the target with any query string removed and percent-encoding
    // resolved.
    var path: String {
        let withoutQuery = target.split(separator: "?", maxSplits: 1,
                                        omittingEmptySubsequences: false).first
            .map(String.init) ?? target
        return withoutQuery.removingPercentEncoding ?? withoutQuery
    }

    // HTTP/1.1 defaults to persistent connections; only an explicit close token
    // ends one. Honoring this matters for browse performance, since the Oppo issues
    // a rapid burst of Browse calls when opening a folder.
    var wantsKeepAlive: Bool {
        if let connection = header("connection")?.lowercased() {
            if connection.contains("close") { return false }
            if connection.contains("keep-alive") { return true }
        }
        return version.uppercased() == "HTTP/1.1"
    }

    // MARK: - Range parsing
    // Only a single byte range is supported, which is all any DLNA client sends.
    // Multi-range requests are answered with the full entity (a legal response),
    // rather than with a multipart body that would add real complexity for no
    // practical benefit here.
    enum ByteRange: Sendable, Equatable {
        // "bytes=N-M"
        case bounded(start: Int64, end: Int64)
        // "bytes=N-"
        case openEnded(start: Int64)
        // "bytes=-N" — the final N bytes.
        case suffix(length: Int64)
    }

    var byteRange: ByteRange? {
        guard let raw = header("range")?.trimmingCharacters(in: .whitespaces),
              raw.lowercased().hasPrefix("bytes=") else { return nil }

        let spec = raw.dropFirst("bytes=".count)
        // Reject multi-range specs by falling back to a full response.
        guard !spec.contains(",") else { return nil }

        let parts = spec.split(separator: "-", maxSplits: 1,
                               omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            guard let length = Int64(endText), length > 0 else { return nil }
            return .suffix(length: length)
        }
        guard let start = Int64(startText), start >= 0 else { return nil }
        if endText.isEmpty { return .openEnded(start: start) }
        guard let end = Int64(endText), end >= start else { return nil }
        return .bounded(start: start, end: end)
    }
}

// MARK: - HTTPRequestParser
// Incremental parser fed by the connection's receive loop. Accumulates bytes until
// a complete request (headers plus any declared body) is available.
struct HTTPRequestParser {

    enum ParseError: Error {
        case malformedRequestLine
        case headersTooLarge
        case bodyTooLarge
        case invalidContentLength(Int)
    }

    // Guard rails against a malformed or hostile peer consuming unbounded memory.
    // UPnP requests are small; anything approaching these limits is a defect.
    private static let maxHeaderBytes = 64 * 1024
    private static let maxBodyBytes = 1024 * 1024

    private var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    // Removes control characters from a header value.
    //
    // This closes a real injection hole rather than tidying input. Header lines are
    // split on CRLF, so a value cannot contain one — but it CAN contain a bare LF,
    // and everything after that LF stays part of the value. Two things then went
    // wrong with a value the server later re-emits or records:
    //
    //   • RESPONSE HEADER INJECTION. The SUBSCRIBE renewal path echoes the client's
    //     SID straight back in the response, so "SID: uuid:x\nX-Evil: yes" put an
    //     attacker-chosen header into the response. Confirmed against a live build
    //     before this existed.
    //   • LOG INJECTION. The same value reaches the log, where the embedded LF ends
    //     the line and everything after it becomes a forged entry — complete with a
    //     fabricated timestamp if the attacker supplies one. For an app whose log is
    //     the primary diagnostic instrument, entries that cannot be trusted are
    //     worse than entries that are missing.
    //
    // Stripping rather than rejecting: no legitimate client sends a bare control
    // character in a header value, so there is nothing to preserve, and refusing the
    // whole request would turn a sloppy client into an unreachable server.
    private static func sanitizedHeaderValue(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return value }
        return String(String.UnicodeScalarView(
            value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
    }

    // Returns the next complete request, or nil if more bytes are needed.
    // Consumed bytes are removed from the buffer so the same parser can serve
    // successive requests on a keep-alive connection.
    mutating func nextRequest() throws -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            if buffer.count > Self.maxHeaderBytes { throw ParseError.headersTooLarge }
            return nil
        }

        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw ParseError.malformedRequestLine
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw ParseError.malformedRequestLine }

        let requestLine = lines.removeFirst()
        let requestParts = requestLine.split(separator: " ", maxSplits: 2,
                                             omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { throw ParseError.malformedRequestLine }

        let method = String(requestParts[0]).uppercased()
        let target = String(requestParts[1])
        let version = requestParts.count > 2 ? String(requestParts[2]) : "HTTP/1.0"

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = Self.sanitizedHeaderValue(
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            headers[name] = value
        }

        // A Content-Length that is present but not a number is refused rather than
        // being quietly read as zero. Treating it as zero left the declared body
        // sitting in the buffer to be parsed as though it were the next request on
        // the connection, which is the raw material for request smuggling — harmless
        // here, since nothing sits downstream of this server, but there is no reason
        // to keep the ambiguity.
        let declaredLength = headers["content-length"]
        let contentLength: Int
        if let declaredLength {
            guard let parsed = Int(declaredLength) else {
                throw ParseError.malformedRequestLine
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        // A negative Content-Length must be rejected before it reaches the index
        // arithmetic below. "Content-Length: -1" produced a body range whose upper
        // bound sat below its lower bound, and slicing that is a Swift runtime trap,
        // not a catchable error: the process died inside the fatal-error reporter
        // while still holding the listening socket, so the port stayed bound, SSDP
        // stopped announcing, and the server looked alive while answering nothing.
        // One malformed request from any device on the LAN was enough.
        guard contentLength >= 0 else {
            throw ParseError.invalidContentLength(contentLength)
        }
        guard contentLength <= Self.maxBodyBytes else { throw ParseError.bodyTooLarge }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }  // Await more bytes.

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])

        // Drop the consumed request, leaving any pipelined bytes in place.
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        return HTTPRequest(method: method, target: target, version: version,
                           headers: headers, body: body)
    }
}

// MARK: - HTTPResponse
struct HTTPResponse: Sendable {

    enum Status: Int, Sendable {
        case ok                  = 200
        case partialContent      = 206
        case badRequest          = 400
        case notFound            = 404
        case methodNotAllowed    = 405
        // UDA's answer for a SUBSCRIBE whose NT or CALLBACK is unusable.
        case preconditionFailed  = 412
        case rangeNotSatisfiable = 416
        case internalServerError = 500

        var reasonPhrase: String {
            switch self {
            case .ok:                  return "OK"
            case .partialContent:      return "Partial Content"
            case .badRequest:          return "Bad Request"
            case .notFound:            return "Not Found"
            case .methodNotAllowed:    return "Method Not Allowed"
            case .preconditionFailed:  return "Precondition Failed"
            case .rangeNotSatisfiable: return "Requested Range Not Satisfiable"
            case .internalServerError: return "Internal Server Error"
            }
        }
    }

    var status: Status
    var headers: [(name: String, value: String)]
    var body: Data
    // When true the connection is closed after this response is written.
    var closeConnection: Bool

    // MARK: - Construction helpers
    static func text(_ status: Status,
                     body: String = "",
                     contentType: String = "text/plain; charset=\"utf-8\"",
                     closeConnection: Bool = false) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: [(name: "Content-Type", value: contentType)],
                     body: Data(body.utf8),
                     closeConnection: closeConnection)
    }

    static func xml(_ body: String,
                    status: Status = .ok,
                    closeConnection: Bool = false) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: [(name: "Content-Type",
                                value: "text/xml; charset=\"utf-8\"")],
                     body: Data(body.utf8),
                     closeConnection: closeConnection)
    }

    // MARK: - Serialization
    // Renders the status line and headers. The body is appended by the caller for
    // buffered responses, or streamed separately for media transfers — which is why
    // this returns only the head.
    //
    // 'contentLength' overrides the declared length for a body that is not carried
    // in 'body'. The media path streams its bytes straight off disk, so its response
    // value is empty while the length it must promise the client is the size of the
    // requested byte span. That path used to assemble its own head from scratch for
    // want of this one parameter — an exact copy of the lines below, which is the
    // sort of duplicate that stays correct right up until someone adds a header
    // here and every media response silently stops carrying it.
    func serializedHead(serverName: String, contentLength: Int64? = nil) -> Data {
        var text = "HTTP/1.1 \(status.rawValue) \(status.reasonPhrase)\r\n"

        for header in headers {
            text += "\(header.name): \(header.value)\r\n"
        }

        // Always present. HEAD responses keep it — it describes the body the client
        // would have received.
        text += "Content-Length: \(contentLength ?? Int64(body.count))\r\n"

        // A Date header is required of origin servers by RFC 9110 and, more
        // practically, some DLNA clients use it to sanity-check the peer.
        text += "Date: \(HTTPDate.now())\r\n"
        text += "Server: \(serverName)\r\n"
        text += "Connection: \(closeConnection ? "close" : "keep-alive")\r\n"
        text += "\r\n"
        return Data(text.utf8)
    }
}

// MARK: - HTTPDate
// RFC 9110 IMF-fixdate formatting. The formatter is expensive to construct and the
// value changes only once per second, so both are cached behind a lock — this is
// called on every response, including during a sustained media transfer.
enum HTTPDate {

    // A Mutex rather than an @unchecked Sendable class around an NSLock: the
    // compiler then checks that the formatter, which is not itself Sendable, is
    // only ever touched while the lock is held.
    private struct State {
        let formatter: DateFormatter
        var cachedSecond: Int = -1
        var cachedValue: String = ""
    }

    private static let cache = Mutex(State(formatter: {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()))

    static func now() -> String {
        let date = Date()
        let second = Int(date.timeIntervalSince1970)
        return cache.withLock { state in
            if second != state.cachedSecond {
                state.cachedSecond = second
                state.cachedValue = state.formatter.string(from: date)
            }
            return state.cachedValue
        }
    }
}

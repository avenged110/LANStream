// MARK: - SelfCheck.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Verifies that what this server ADVERTISES actually works, from the outside.
//
// Every other guard in this app catches something that reports an error. This one
// exists for the failure that reports success at every layer. The motivating bug:
// M-SEARCH replies were answered with
// "LOCATION: http://239.255.255.250:8201/description.xml" — the multicast group
// address rather than this machine's. SSDP logged "Answered", the HTTP listener was
// up, the index was built, no call failed anywhere, and the server was completely
// invisible to the player. Nothing in the process could tell, because nothing in the
// process ever looked at its own output.
//
// So this does what a client does: it resolves the advertised URL, fetches it, and
// searches for the device over real multicast, then checks that what came back
// describes THIS server. A wrong address, a wrong port, a listener bound to the
// wrong interface, a description that does not identify us, or a reply that never
// arrives all surface here as a single loud line in the log.
//
// It is strictly advisory. Every entry point is best-effort, hard-timeboxed, and
// incapable of failing the server: a self-check that can hang or abort startup would
// be a worse defect than the one it detects.

import Foundation
import Network

enum SelfCheck: Loggable {
    static let logTag = "[SelfCheck]"

    // Identifies a search this app sent to itself. Carried on the probe and
    // recognized by SSDPResponder so self-tests stay out of the player statistics.
    static let probeHeaderName = "X-LANStream-SelfCheck"

    // Hard ceilings. These bound the whole check; nothing here retries forever.
    private static let httpTimeout: TimeInterval = 5.0
    private static let discoveryTimeout: TimeInterval = 6.0

    // MARK: - Address validation
    // The check that would have caught the original bug on its own.
    //
    // An address is advertisable only if a client on another machine could open a
    // TCP connection to it. That excludes far more than the wildcard: multicast
    // (224.0.0.0/4) is the group address this server listens to rather than one it
    // can be reached at, loopback is reachable only from this machine, link-local
    // means DHCP never completed, and the broadcast address is not a host at all.
    static func isAdvertisableIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else { return false }
            octets.append(value)
        }

        if octets == [0, 0, 0, 0] { return false }              // wildcard
        if octets == [255, 255, 255, 255] { return false }      // broadcast
        if octets[0] == 127 { return false }                    // loopback
        if octets[0] == 0 { return false }                      // "this network"
        if (224...239).contains(octets[0]) { return false }     // multicast
        if octets[0] >= 240 { return false }                    // reserved
        if octets[0] == 169 && octets[1] == 254 { return false } // link-local
        return true
    }

    // MARK: - Outcome
    enum Outcome {
        case passed(String)
        case failed(String)

        var isPass: Bool { if case .passed = self { return true }; return false }
        var detail: String {
            switch self {
            case .passed(let text), .failed(let text): return text
            }
        }
    }

    // MARK: - Report
    // The overall verdict, plus the discovery half called out separately.
    //
    // The two halves point at completely different faults, and only one of them
    // means "the LAN is refusing our traffic": a description document that cannot be
    // fetched is an HTTP problem, while an unanswered M-SEARCH is the outside-in
    // confirmation that discovery is blocked. A bare Bool forced the caller to guess
    // between them, which is why discovery is reported on its own.
    //
    // The description half deliberately has no member of its own. Nothing has ever
    // needed to branch on it — the full detail is already in the log line 'run'
    // writes — and a field that is only ever assigned is worse than absent, because
    // it reads as a supported way to ask a question no caller is actually asking.
    struct Report: Sendable {
        let passed: Bool
        // nil when the discovery probe was not run.
        let discoveryPassed: Bool?

        // True only when discovery was tested and failed. This is what drives the
        // menu bar warning.
        var discoveryBlocked: Bool { discoveryPassed == false }
    }

    // MARK: - Entry point
    // Runs the full battery and logs a single verdict. Never throws, never blocks
    // the caller for longer than the timeouts above, and reports which half failed
    // so a caller can surface it in the UI.
    @discardableResult
    static func run(advertisedLocation location: String, udn: String) async -> Report {
        let description = await verifyDescription(at: location, udn: udn)
        let discovery = await verifyDiscovery(expectedLocation: location, udn: udn)

        let failures = [description, discovery].filter { !$0.isPass }

        if failures.isEmpty {
            Self.log("SELF-CHECK PASSED: \(description.detail); \(discovery.detail)")
            return Report(passed: true, discoveryPassed: true)
        }

        // Spelled out at length because this is the message that has to explain, to
        // someone reading the log later, why players cannot see a server that looks
        // perfectly healthy from the inside.
        var line = "SELF-CHECK FAILED: this server is advertising \(location), "
            + "which does not work when tested the way a player would use it. "
        line += failures.map(\.detail).joined(separator: " ")
        if description.isPass {
            line += " The description document is reachable, so the HTTP side is fine "
                + "and the fault is in discovery."
        }
        Self.log(line)
        return Report(passed: false, discoveryPassed: discovery.isPass)
    }

    // MARK: - 1. The advertised URL serves OUR description
    // Fetching is what makes this meaningful. Validating the address string alone
    // would have caught the multicast bug but not a listener bound to the wrong
    // interface, a port the firewall blocks, or another DLNA server that grabbed the
    // port first — all of which produce a plausible URL that serves the wrong thing
    // or nothing.
    static func verifyDescription(at location: String, udn: String) async -> Outcome {
        guard let url = URL(string: location), let host = url.host() else {
            return .failed("The advertised LOCATION '\(location)' is not a usable URL.")
        }
        guard isAdvertisableIPv4(host) else {
            return .failed("The advertised LOCATION points at \(host), which is not an "
                + "address a client can connect to (it is a wildcard, loopback, "
                + "link-local, broadcast, or multicast address).")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = httpTimeout
        configuration.timeoutIntervalForResource = httpTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Fetching \(location) returned a non-HTTP response.")
            }
            guard http.statusCode == 200 else {
                return .failed("Fetching \(location) returned HTTP \(http.statusCode).")
            }
            let body = String(decoding: data, as: UTF8.self)
            guard body.contains(udn) else {
                return .failed("\(location) is reachable but the description it returns "
                    + "does not carry this server's UDN (\(udn)) — something else may be "
                    + "answering on that address and port.")
            }
            return .passed("\(location) serves this server's description")
        } catch {
            return .failed("Fetching \(location) failed: \(error.localizedDescription).")
        }
    }

    // MARK: - 2. A real M-SEARCH finds us, with the right LOCATION
    // The end-to-end check: an actual multicast search on the actual network,
    // answered by the actual responder, parsed the way a player parses it.
    //
    // This deliberately uses a plain BSD socket rather than Network.framework. It
    // needs an UNCONNECTED UDP socket — the reply arrives from port 1900 while the
    // search went to the group address, and a connected socket discards datagrams
    // whose source is not the peer it was connected to. That distinction is not
    // incidental: it silently invalidated three separate external test harnesses
    // before it was understood, and getting it wrong here would produce a
    // self-check that fails while the server is perfectly healthy.
    static func verifyDiscovery(expectedLocation: String, udn: String) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            // Blocking socket work, kept off the cooperative pool.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: performDiscoveryProbe(expectedLocation: expectedLocation,
                                                                     udn: udn))
            }
        }
    }

    private static func performDiscoveryProbe(expectedLocation: String, udn: String) -> Outcome {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            return .failed("Could not open a socket to search with (errno \(errno)).")
        }
        defer { Darwin.close(fd) }

        // Bind an ephemeral port on all interfaces. Unconnected: see the note above.
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = in_addr_t(0)
        let bound = unsafe withUnsafePointer(to: &local) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            return .failed("Could not bind a socket to search with (errno \(errno)).")
        }

        var ttl: Int32 = 2
        unsafe setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))

        // Search for the MediaServer device type specifically rather than
        // upnp:rootdevice. Every renderer on the network answers rootdevice — the
        // Oppo's own DMR does — and this probe only cares about one answer.
        let searchTarget = "urn:schemas-upnp-org:device:MediaServer:1"
        // The marker header makes this probe self-identifying. The responder answers
        // it exactly like any other search — that is the whole point, the reply has
        // to come from the real code path — but leaves it out of the statistics that
        // describe player behavior. Without it, every self-check would register as
        // "a player searched for us and we answered", which would make the health
        // report describe its own traffic and permanently suppress the note that
        // says no player has looked yet.
        let search = "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: 239.255.255.250:1900\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 1\r\n"
            + "ST: \(searchTarget)\r\n"
            + "\(Self.probeHeaderName): \(udn)\r\n\r\n"

        var group = sockaddr_in()
        group.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        group.sin_family = sa_family_t(AF_INET)
        group.sin_port = UInt16(1900).bigEndian
        // 239.255.255.250, the SSDP group, in network byte order. Written as a
        // constant rather than parsed with inet_pton, which needs a raw pointer
        // into the struct for a value that never changes.
        group.sin_addr.s_addr = in_addr_t(0xEFFF_FFFA).bigEndian

        let searchBytes = Array(search.utf8)
        let sendResult = unsafe withUnsafePointer(to: &group) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                unsafe searchBytes.withUnsafeBytes { raw in
                    unsafe sendto(fd, raw.baseAddress, raw.count, 0, addr,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sendResult >= 0 else {
            return .failed("Sending a test M-SEARCH failed (errno \(errno)) — outbound "
                + "multicast is blocked, so players cannot discover this server.")
        }

        // Read until our own answer turns up or the socket read times out. Other
        // devices answer too and are simply skipped.
        let deadline = Date().addingTimeInterval(discoveryTimeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var sawForeignReply = false

        while true {
            // The receive timeout is re-armed from the time actually LEFT rather
            // than being set once to the whole budget. With a fixed timeout, a
            // reply from some other device arriving just before the deadline sent
            // this loop back into a recv that could block for another full budget,
            // so a chatty network could stretch a six-second probe to twelve.
            let timeLeft = deadline.timeIntervalSinceNow
            guard timeLeft > 0 else { break }
            // Floored below, because SO_RCVTIMEO of exactly zero means "block
            // forever" — a sliver of time left must not round down into an
            // unbounded wait, which would be strictly worse than the overrun this
            // whole change exists to remove.
            let wholeSeconds = Int(timeLeft)
            var timeout = timeval(
                tv_sec: wholeSeconds,
                tv_usec: __darwin_suseconds_t(
                    max(1, (timeLeft - Double(wholeSeconds)) * 1_000_000)))
            unsafe setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))

            let count = unsafe recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break } // timeout or error; fall through to the verdict
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            guard text.hasPrefix("HTTP/1.1 200") else { continue }

            let headers = SSDPMessage.parseHeaders(text)
            guard let usn = headers["usn"], usn.contains(udn) else {
                sawForeignReply = true
                continue
            }

            guard let replyLocation = headers["location"] else {
                return .failed("This server answered a test search with no LOCATION header.")
            }
            guard replyLocation == expectedLocation else {
                return .failed("A test search was answered with LOCATION \(replyLocation), "
                    + "but this server is advertising \(expectedLocation). Players will "
                    + "follow the address in the reply and fail to reach it.")
            }
            return .passed("a live M-SEARCH was answered with the correct LOCATION")
        }

        if sawForeignReply {
            return .failed("A test M-SEARCH was answered by other devices but not by this "
                + "server, so players searching for a media server will not find it.")
        }
        return .failed("A test M-SEARCH went unanswered — no reply reached this app within "
            + "\(Int(discoveryTimeout))s. Inbound multicast is most likely blocked (Local "
            + "Network permission, a firewall such as Little Snitch, or the network itself).")
    }
}

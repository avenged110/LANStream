// MARK: - NetworkInterface.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Local IPv4 address discovery for building client-facing URLs.
//
// Every URL LAN Stream hands to a player — the SSDP LOCATION header, URLBase in
// the device descriptor, and every res element in a Browse result — must point at
// an address the player can actually reach. On a machine with several interfaces
// (Ethernet plus Wi-Fi plus any VPN or virtualization bridge), advertising the
// wrong one produces a device that appears in the player's list and then fails to
// browse: the exact symptom this app was written to eliminate. Addresses are
// therefore always derived from the interface the request or search arrived on,
// with the ranking here used only as a fallback.

import Foundation
import Darwin
import SystemConfiguration

enum NetworkInterface {

    // MARK: - Interface record
    struct Address: Sendable, Equatable {
        let interfaceName: String   // e.g. "en0"
        let ipv4: String            // dotted quad
        let isEthernet: Bool
    }

    // MARK: - Enumeration
    // Returns every active, non-loopback IPv4 address, ordered by how likely it is
    // to be the LAN the media player lives on: wired first, then wireless, then
    // anything else. A Mac mini serving a Blu-ray player is nearly always wired,
    // and preferring Ethernet avoids advertising a Wi-Fi address that may be on a
    // different subnet or a guest network.
    static func activeIPv4Addresses() -> [Address] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard unsafe getifaddrs(&head) == 0, let first = unsafe head else { return [] }
        defer { unsafe freeifaddrs(head) }

        var results: [Address] = []

        for unsafe pointer in unsafe sequence(first: first, next: { unsafe $0.pointee.ifa_next }) {
            let interface = unsafe pointer.pointee

            guard let addressPointer = unsafe interface.ifa_addr,
                  unsafe addressPointer.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(unsafe interface.ifa_flags)
            // Skip interfaces that are administratively down, not running, or
            // loopback. A down interface's stale address is a common source of
            // an unreachable advertised URL.
            guard flags & IFF_UP == IFF_UP,
                  flags & IFF_RUNNING == IFF_RUNNING,
                  flags & IFF_LOOPBACK == 0 else { continue }

            let name = unsafe String(cString: interface.ifa_name)

            // Exclude virtual interfaces created by virtualization, containers, and
            // VPN software. These are up and running but are never the path to a
            // Blu-ray player, and they routinely sort ahead of the real NIC.
            guard !isVirtualInterface(named: name) else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = unsafe getnameinfo(addressPointer,
                                     socklen_t(addressPointer.pointee.sa_len),
                                     &buffer, socklen_t(buffer.count),
                                     nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }

            // String(decoding:as:) rather than String(cString:), which is deprecated
            // for array arguments. getnameinfo null-terminates within the buffer, so
            // the bytes up to that terminator are the address text.
            let ipv4 = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                              as: UTF8.self)
            // 169.254/16 is a self-assigned address, meaning DHCP failed. It is
            // technically routable to a peer in the same state but is never the
            // right thing to advertise.
            guard !ipv4.hasPrefix("169.254.") else { continue }

            results.append(Address(interfaceName: name,
                                   ipv4: ipv4,
                                   isEthernet: name.hasPrefix("en") && !isWiFi(name)))
        }

        return results.sorted { lhs, rhs in
            if lhs.isEthernet != rhs.isEthernet { return lhs.isEthernet }
            return lhs.interfaceName < rhs.interfaceName
        }
    }

    // The best guess at the address to advertise when no request context is
    // available — used for the menu bar's status display and as a fallback.
    static func primaryIPv4Address() -> String? {
        activeIPv4Addresses().first?.ipv4
    }

    // MARK: - Interface classification
    private static func isWiFi(_ name: String) -> Bool {
        wirelessInterfaceNames.contains(name)
    }

    // Resolved once per launch: the set of wireless interface names, read from
    // SystemConfiguration's interface list. Cached because the answer does not
    // change while the app is running and the lookup is not free.
    //
    // BSD names alone cannot be trusted for this. On Apple silicon Wi-Fi is
    // typically en0 and Ethernet en1 — the reverse of the Intel convention — so a
    // name-based heuristic would rank the interfaces backwards on exactly the
    // hardware this app runs on.
    private static let wirelessInterfaceNames: Set<String> = {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return []
        }
        var names: Set<String> = []
        for interface in interfaces {
            guard let type = SCNetworkInterfaceGetInterfaceType(interface),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) else { continue }
            if (type as String) == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                names.insert(bsdName as String)
            }
        }
        return names
    }()

    private static func isVirtualInterface(named name: String) -> Bool {
        // bridge*: virtualization / Internet Sharing bridges
        // utun*, ipsec*, ppp*: VPN tunnels
        // vmenet*, vnic*, vboxnet*: hypervisor host-only networks
        // awdl*, llw*: Apple Wireless Direct Link, peer-to-peer only
        // ap*: the Wi-Fi access-point interface used by Internet Sharing
        let virtualPrefixes = ["bridge", "utun", "ipsec", "ppp", "vmenet",
                               "vnic", "vboxnet", "awdl", "llw", "ap", "gif", "stf"]
        return virtualPrefixes.contains { name.hasPrefix($0) }
    }
}

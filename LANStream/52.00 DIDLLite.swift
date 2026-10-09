// MARK: - DIDLLite.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Builds the DIDL-Lite documents returned inside ContentDirectory#Browse results.
//
// DIDL-Lite is a complete XML document that is itself carried as an ESCAPED
// STRING inside the SOAP <Result> element. Forgetting that second level of
// escaping is the single most common DLNA server bug; it produces a response
// that parses as valid SOAP but yields an empty browse list on the client with
// no error anywhere. SOAPResponse.browse performs the outer escape — this type
// deliberately returns plain, unescaped XML so the two steps stay separable and
// individually inspectable in the log.

import Foundation

enum DIDLLite {

    private static let header = """
    <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
    xmlns:dc="http://purl.org/dc/elements/1.1/" \
    xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
    xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">
    """

    private static let footer = "</DIDL-Lite>"

    // MARK: - Document assembly
    // 'baseURL' is the scheme://host:port the requesting client used, so that the
    // res URLs it receives point back at the exact interface it can reach.
    static func document(for nodes: [MediaNode], baseURL: String) -> String {
        var xml = header
        for node in nodes {
            switch node.kind {
            case .container:
                xml += containerElement(for: node)
            case .item(_, let byteSize, let durationSeconds):
                xml += itemElement(for: node, byteSize: byteSize,
                                   durationSeconds: durationSeconds, baseURL: baseURL)
            }
        }
        xml += footer
        return xml
    }

    // MARK: - Container element
    // childCount is included because several players — the Oppo among them, based
    // on observed behavior of comparable firmware — use it to decide whether a
    // folder is worth descending into at all, and will render a container reporting
    // no children as unselectable.
    private static func containerElement(for node: MediaNode) -> String {
        """
        <container id="\(XML.escape(node.id))" parentID="\(XML.escape(node.parentID))" \
        childCount="\(node.childCount)" restricted="1" searchable="0">\
        <dc:title>\(XML.escape(node.title))</dc:title>\
        <upnp:class>object.container.storageFolder</upnp:class>\
        <upnp:storageUsed>-1</upnp:storageUsed>\
        </container>
        """
    }

    // MARK: - Item element
    // upnp:class is the generic object.item.videoItem rather than a more specific
    // subclass such as .movie. The generic class is understood universally; the
    // narrower ones are not, and a player that does not recognize the class may
    // filter the item out of its own list.
    private static func itemElement(for node: MediaNode,
                                    byteSize: Int64,
                                    durationSeconds: Double?,
                                    baseURL: String) -> String {
        // The extension is cosmetic — the object ID before it is what resolves the
        // request — but some players read it as a format hint before opening the
        // stream, so it has to be the file's real one rather than a fixed ".mkv".
        let fileExtension = node.fileExtension
        let resourceURL =
            "\(baseURL)\(UPnP.Path.mediaPrefix)\(node.id).\(fileExtension)"
        // The fourth protocolInfo field carries the DLNA content-features string
        // rather than the "*" wildcard used in GetProtocolInfo. A wildcard is legal
        // here too, but spelling out DLNA.ORG_OP=01 on the resource itself is what
        // reliably enables byte-range seeking on players that read the flags from
        // the res element instead of issuing a HEAD first.
        let mimeType = UPnP.mimeType(forExtension: fileExtension)
        let protocolInfo = "http-get:*:\(mimeType):\(UPnP.contentFeatures)"

        // Omitted entirely rather than emitted as 0:00:00 when the running time is
        // unknown. The attribute is optional, and a player treats an absent duration
        // as "not stated" but a zero-valued one as an answer — which renders as a
        // zero-length file and, on some firmware, as an unplayable one.
        let durationAttribute = durationSeconds
            .map { " duration=\"\(MediaDuration.format($0))\"" } ?? ""

        return """
        <item id="\(XML.escape(node.id))" parentID="\(XML.escape(node.parentID))" restricted="1">\
        <dc:title>\(XML.escape(node.title))</dc:title>\
        <upnp:class>object.item.videoItem</upnp:class>\
        <res protocolInfo="\(XML.escape(protocolInfo))" size="\(byteSize)"\(durationAttribute)>\
        \(XML.escape(resourceURL))</res>\
        </item>
        """
    }
}
